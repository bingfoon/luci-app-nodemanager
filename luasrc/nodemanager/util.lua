local fs   = require "nixio.fs"
local sys  = require "luci.sys"
local i18n = require "luci.i18n"

local M = {}

local function conf_path()
	local uci = require("luci.model.uci").cursor()
	local p = uci:get("nodemanager", "config", "path")
	if p and #p > 0 then return p end
	return "/etc/nikki/profiles/config.yaml" -- 默认值（兼容旧行为）
end

function M.conf_path()  -- 导出给控制器/视图显示
	return conf_path()
end

local function trim(s) return (s or ""):gsub("^%s+",""):gsub("%s+$","") end

local function is_ipv4(s) return s:match("^%d+%.%d+%.%d+%.%d+$") ~= nil end
local function is_hostname(s) return s:match("^[%w%-%.]+$") ~= nil end
local function is_port(p) p = tonumber(p); return p and p >= 1 and p <= 65535 end
local function is_http_url(u) return u and u:match("^https?://[%w%-%._~:/%?#%[%]@!$&'()*+,;=%%]+$") end

-- 可靠按行读取（兼容 \r\n / \n）
local function read_lines(path)
	path = path or conf_path()
	local s = fs.readfile(path) or ""
	local t = {}
	for line in (s.."\n"):gmatch("([^\n]*)\n") do
		line = line:gsub("\r$","")
		table.insert(t, line)
	end
	-- 如果是空文件，t 会有一行空串；保持一致性
	if #s == 0 then t = {} end
	return t
end

local function write_lines(lines, path)
	path = path or conf_path()
	return fs.writefile(path, table.concat(lines, "\n").."\n")
end

-- 通过注释锚点找可重写范围
local function find_range(lines, start_hint, end_hint)
	local sidx, eidx
	for i,l in ipairs(lines) do
		if not sidx and l:find(start_hint, 1, true) then sidx = i end
		if l:find(end_hint, 1, true) then eidx = i end
	end
	if sidx and eidx and eidx > sidx then
		return sidx + 1, eidx - 1
	end
	return nil, nil
end

-- 解析 proxies 片段
local function parse_proxies(lines)
	local proxies = {}
	for _,l in ipairs(lines) do
		if l:match("^%s*-%s*{%s*<<:%s*%*s5") then
			local name = l:match('name:%s*"([^"]-)"') or l:match("name:%s*([^,%s}]+)")
			local serv = l:match('server:%s*"([^"]-)"') or l:match("server:%s*([^,%s}]+)")
			local port = l:match("port:%s*(%d+)")
			local user = l:match('username:%s*"([^"]-)"') or l:match("username:%s*([^,%s}]+)")
			local pass = l:match('password:%s*"([^"]-)"') or l:match("password:%s*([^,%s}]+)")
			if name and serv and port and user and pass then
				table.insert(proxies, {
					name = trim(name),
					server = trim((serv or ""):gsub('^"(.*)"$','%1')),
					port = tonumber(port),
					username = trim((user or ""):gsub('^"(.*)"$','%1')),
					password = trim((pass or ""):gsub('^"(.*)"$','%1')),
				})
			end
		end
	end
	return proxies
end

-- 解析 rules 片段（name <- ip 绑定）
local function parse_bindmap(lines)
	local map = {}
	for _,l in ipairs(lines) do
		local ip, name = l:match("^%s*%-%s*SRC%-IP%-CIDR,([%d%.]+)/32,([^\r\n]+)$")
		if ip and name then
			map[trim(name)] = trim(ip)
		end
	end
	return map
end

-- 解析 providers
local function parse_providers(lines)
	local providers = {}
	local in_block = false
	for i,l in ipairs(lines) do
		if l:match("^%s*proxy%-providers:%s*$") then
			in_block = true
		elseif in_block and l:match("^%S") then
			break
		elseif in_block then
			local name = l:match("^%s*([%w%._%-%u%l][^:]-):%s*$")
			if name then
				local url = nil
				for k=1,6 do
					local ln = lines[i+k]
					if not ln then break end
					url = url or (ln:match('url:%s*"(.-)"') or ln:match("url:%s*([^%s#]+)"))
				end
				if url then table.insert(providers, { name = trim(name), url = trim(url) }) end
			end
		end
	end
	return providers
end

-- 解析 DNS nameserver（去掉 goto/label，兼容 Lua 5.1）
local function parse_dns_servers(lines)
	local servers = {}
	local in_dns, in_ns = false, false
	for _,l in ipairs(lines) do
		if l:match("^dns:%s*$") then
			in_dns = true
		elseif in_dns and l:match("^%S") and not l:match("^dns:%s*$") then
			in_dns = false
			in_ns = false
		elseif in_dns and l:match("^%s*nameserver:%s*$") then
			in_ns = true
		elseif in_ns then
			local ip = l:match("^%s*%-%s*([%d%.]+)%s*$")
			if ip then
				table.insert(servers, ip)
			else
				if l:match("^%s*%S") and not l:match("^%s*%-") then
					in_ns = false
				end
			end
		end
	end
	return servers
end

function M.load_all()
	local lines = read_lines()
	local s1,e1 = find_range(lines, "落地节点信息从下面开始添加", "落地节点信息必须添加在这一行上面")
	local s2,e2 = find_range(lines, "落地节点对应的子网设备添加在下面", "落地节点添加在上面")

	local proxies = {}
	if s1 and e1 then
		local slice = {}
		for i=s1,e1 do table.insert(slice, lines[i]) end
		proxies = parse_proxies(slice)
	end
	local bindmap = {}
	if s2 and e2 then
		local slice = {}
		for i=s2,e2 do table.insert(slice, lines[i]) end
		bindmap = parse_bindmap(slice)
	end
	local providers = parse_providers(lines)
	local dns_servers = parse_dns_servers(lines)
	return { proxies = proxies, bindmap = bindmap, providers = providers, dns_servers = dns_servers }
end

-- 表单解析
function M.parse_proxy_form(form)
	local names    = form["name[]"]     or form.name
	local servers  = form["server[]"]   or form.server
	local ports    = form["port[]"]     or form.port
	local users    = form["username[]"] or form.username
	local passes   = form["password[]"] or form.password
	local bindips  = form["bindip[]"]   or form.bindip

	if type(names)=="string" then
		names   = {names}; servers = {servers}; ports = {ports}
		users   = {users};  passes  = {passes};  bindips= {bindips}
	end

	local list = {}
	for i=1, #(names or {}) do
		local n = trim(names[i] or "")
		local s = trim(servers[i] or "")
		local p = tonumber(ports[i] or "")
		local u = trim(users[i] or "")
		local w = trim(passes[i] or "")
		local b = trim(bindips[i] or "")
		if n=="" or s=="" or u=="" or w=="" then
			return false, nil, i18n.translate("Fields cannot be empty")
		end
		if not (is_hostname(s) or is_ipv4(s)) then
			return false,nil, i18n.translatef("Invalid server at row %d", i)
		end
		if not is_port(p) then
			return false,nil, i18n.translatef("Invalid port at row %d", i)
		end
		if b~="" and not is_ipv4(b) then
			return false,nil, i18n.translatef("Invalid bind IP at row %d", i)
		end
		table.insert(list, { name=n, server=s, port=p, username=u, password=w, bindip=b })
	end
	return true, list
end

function M.parse_provider_form(form)
	local names = form["pname[]"] or form.pname
	local urls  = form["purl[]"]  or form.purl
	if type(names)=="string" then names={names}; urls={urls} end

	local list = {}
	for i=1,#(names or {}) do
		local n = trim(names[i] or "")
		local u = trim(urls[i] or "")
		if n=="" or u=="" then return false,nil,i18n.translate("Fields cannot be empty") end
		if not is_http_url(u) then return false,nil,i18n.translatef("Invalid URL at row %d", i) end
		table.insert(list, {name=n, url=u})
	end
	return true, list
end

function M.parse_dns_form(form)
	local sv = form["dns[]"] or form.dns
	if type(sv)=="string" then sv = {sv} end
	local out = {}
	for i=1,#(sv or {}) do
		local ip = trim(sv[i] or "")
		if ip=="" then return false,nil,i18n.translate("DNS cannot be empty") end
		if not is_ipv4(ip) then return false,nil,i18n.translatef("Invalid DNS at row %d", i) end
		table.insert(out, ip)
	end
	return true, out
end

-- 保存：重写 proxies 与 rules 片段
function M.save_proxies_and_rules(list)
	local lines = read_lines()
	local ps,pe = find_range(lines, "落地节点信息从下面开始添加", "落地节点信息必须添加在这一行上面")
	if not (ps and pe) then return false, "Cannot locate proxies range in config.yaml" end
	local rs,re = find_range(lines, "落地节点对应的子网设备添加在下面", "落地节点添加在上面")
	if not (rs and re) then return false, "Cannot locate rules range in config.yaml" end

	local newp = {}
	for _,x in ipairs(list) do
		table.insert(newp, string.format('  - { <<: *s5, name: "%s", server: "%s", port: %d, username: "%s", password: "%s"}',
			x.name, x.server, x.port, x.username, x.password))
	end

	local newr = {}
	for _,x in ipairs(list) do
		if x.bindip and x.bindip~="" then
			table.insert(newr, string.format('  - SRC-IP-CIDR,%s/32,%s', x.bindip, x.name))
		end
	end

	-- 替换 proxies 片段
	local out = {}
	for i=1,#lines do
		if i==ps then
			for _,l in ipairs(newp) do table.insert(out, l) end
		end
		if i>ps and i<=pe then
			-- skip old
		else
			table.insert(out, lines[i])
		end
	end
	lines = out
	out = {}

	-- 替换 rules 片段
	for i=1,#lines do
		if i==rs then
			for _,l in ipairs(newr) do table.insert(out, l) end
		end
		if i>rs and i<=re then
			-- skip old
		else
			table.insert(out, lines[i])
		end
	end
	return write_lines(out) ~= nil, nil
end

function M.save_providers(list)
	local lines = read_lines()
	local start_idx
	for i,l in ipairs(lines) do
		if l:match("^%s*proxy%-providers:%s*$") then start_idx = i break end
	end
	if not start_idx then return false, "Cannot locate proxy-providers in config.yaml" end

	local end_idx = #lines
	for i=start_idx+1,#lines do
		if lines[i]:match("^%S") then end_idx = i-1; break end
	end

	local out = {}
	for i=1,start_idx do table.insert(out, lines[i]) end
	for _,p in ipairs(list) do
		table.insert(out, string.format("  %s:", p.name))
		table.insert(out, "    <<: *airport")
		table.insert(out, string.format('    url: "%s"', p.url))
	end
	for i=end_idx+1,#lines do table.insert(out, lines[i]) end
	return write_lines(out) ~= nil, nil
end

function M.save_dns_servers(servers)
	local lines = read_lines()
	local dns_start
	for i,l in ipairs(lines) do
		if l:match("^dns:%s*$") then dns_start = i break end
	end
	if not dns_start then return false, "Cannot locate dns: block" end

	local ns_start, ns_end
	for i=dns_start+1,#lines do
		if lines[i]:match("^%S") then break end
		if lines[i]:match("^%s*nameserver:%s*$") then
			ns_start = i; ns_end = i
			for j=i+1,#lines do
				if lines[j]:match("^%s*%-") then
					ns_end = j
				else
					if lines[j]:match("^%s*%S") and not lines[j]:match("^%s*%-") then
						break
					end
				end
				if lines[j]:match("^%S") then break end
			end
			break
		end
	end
	if not ns_start then return false, "Cannot locate nameserver: list" end

	local out = {}
	for i=1,ns_start do table.insert(out, lines[i]) end
	for _,ip in ipairs(servers) do
		table.insert(out, string.format("    - %s", ip))
	end
	for i=(ns_end or ns_start)+1,#lines do table.insert(out, lines[i]) end
	return write_lines(out) ~= nil, nil
end

return M