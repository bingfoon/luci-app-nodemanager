-- luci-app-nodemanager v2 — Unified API Backend
-- SPDX-License-Identifier: Apache-2.0

module("luci.controller.nodemanager", package.seeall)

local http = require "luci.http"
local sys  = require "luci.sys"
local fs   = require "nixio.fs"
local uci  = require "luci.model.uci"

-- ============================================================
-- Routing
-- ============================================================
function index()
	entry({"admin", "services", "nodemanager"}, firstchild(), _("Node Manager"), 70)
	entry({"admin", "services", "nodemanager", "api"}, call("api"), nil).leaf = true
end

-- ============================================================
-- API Dispatch
-- ============================================================
local HANDLERS = {}

function api()
	local action = http.formvalue("action") or ""
	local fn = HANDLERS[action]
	if not fn then
		return json_out({ok = false, err = "unknown action: " .. action})
	end
	local ok_call, result = pcall(fn)
	if not ok_call then
		return json_out({ok = false, err = tostring(result)})
	end
end

-- ============================================================
-- Helpers
-- ============================================================
local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

local function json_out(t)
	http.prepare_content("application/json")
	http.write(require("luci.jsonc").stringify(t))
end

local function json_in()
	local raw = http.content()
	if not raw or raw == "" then return {} end
	return require("luci.jsonc").parse(raw) or {}
end

local function http_get_json(url)
	-- Use wget for HTTP calls to Mihomo API (available on all OpenWrt)
	local tmp = "/tmp/nm_api_" .. tostring(os.time()) .. ".json"
	local code = sys.call(string.format(
		"wget -q -O %q --timeout=6 %q >/dev/null 2>&1", tmp, url))
	if code ~= 0 then
		os.remove(tmp)
		return nil, "request failed"
	end
	local data = fs.readfile(tmp)
	os.remove(tmp)
	if not data then return nil, "empty response" end
	return require("luci.jsonc").parse(data)
end

-- ============================================================
-- UCI / Path Management
-- ============================================================
local function uci_cursor()
	return uci.cursor()
end

local _cached_conf_path = nil

local function conf_path()
	-- Cache: once resolved, don't re-scan (avoids race with write_provider_file)
	if _cached_conf_path then return _cached_conf_path end

	-- 1. Check UCI nodemanager override
	local c = uci_cursor()
	local p = c:get_first("nodemanager", "main", "path")
	if p and p ~= "" and fs.access(p) then _cached_conf_path = p; return p end

	-- 2. Read from running mihomo/nikki process -f flag (ground truth)
	local ps = io.popen("ps w 2>/dev/null | grep -E 'mihomo|nikki' | grep -v grep")
	if ps then
		local psout = ps:read("*a")
		ps:close()
		if psout then
			local fpath = psout:match("%-f%s+(%S+%.ya?ml)")
			if fpath and fs.access(fpath) then _cached_conf_path = fpath; return fpath end
		end
	end

	-- 3. Check nikki UCI for active profile
	local ok_nikki, _ = pcall(function()
		p = c:get("nikki", "mixin", "profile_name")
	end)
	if ok_nikki and p and p ~= "" then
		local candidate = "/etc/nikki/profiles/" .. p .. ".yaml"
		if fs.access(candidate) then _cached_conf_path = candidate; return candidate end
	end
	-- 4. Scan /etc/nikki/profiles/ for most recently modified .yaml
	--    EXCLUDE nm_proxies.yaml to avoid race condition with write_provider_file
	local dir = "/etc/nikki/profiles/"
	if fs.access(dir) then
		local entries = fs.dir(dir)
		if entries then
			local best, best_mtime = nil, 0
			for entry in entries do
				if entry:match("%.ya?ml$") and entry ~= "nm_proxies.yaml" then
					local st = fs.stat(dir .. entry)
					local mt = st and st.mtime or 0
					if mt > best_mtime then
						best_mtime = mt
						best = dir .. entry
					end
				end
			end
			if best then _cached_conf_path = best; return best end
		end
	end

	-- 5. Default fallback
	_cached_conf_path = "/etc/nikki/profiles/config.yaml"
	return _cached_conf_path
end

local NM_PROVIDER_NAME = "nm-nodes"
local NM_GROUP_NAME = "\240\159\143\160住宅节点"
local NM_PROVIDER_FILE = "nm_proxies.yaml"

-- Persistent storage path (source of truth, survives reboot)
local function nm_storage_path()
	local dir = conf_path():match("^(.+)/[^/]+$") or "/etc/nikki/profiles"
	return dir .. "/" .. NM_PROVIDER_FILE
end

-- Detect Mihomo home directory from running process -d flag
local function mihomo_home()
	local ps = io.popen("ps w 2>/dev/null | grep -E 'mihomo|nikki' | grep -v grep")
	if ps then
		local psout = ps:read("*a")
		ps:close()
		if psout then
			local d = psout:match("%-d%s+(%S+)")
			if d and fs.access(d) then return d end
		end
	end
	return "/etc/nikki/run"
end

-- Runtime path for Mihomo (must be under -d directory)
local function nm_runtime_path()
	return mihomo_home() .. "/" .. NM_PROVIDER_FILE
end

local SAFE_PREFIXES = {"/etc/nikki/", "/tmp/", "/usr/share/nodemanager/"}

local function is_safe_path(p)
	if not p then return false end
	for _, pfx in ipairs(SAFE_PREFIXES) do
		if p:sub(1, #pfx) == pfx then return true end
	end
	return false
end

-- ============================================================
-- File I/O (with .bak backup)
-- ============================================================
local function read_lines()
	local path = conf_path()
	local content = fs.readfile(path)
	if not content then return {} end
	local lines = {}
	-- Use (.-)\n to correctly split by newlines without phantom empty matches
	for line in (content .. "\n"):gmatch("(.-)\n") do
		table.insert(lines, line)
	end
	-- Remove trailing empty line from appended \n
	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

local function write_lines(lines)
	local path = conf_path()
	-- Auto-migrate: strip deprecated global-client-fingerprint on every write
	local filtered = {}
	for _, line in ipairs(lines) do
		local fp = line:match("^%s*global%-client%-fingerprint:%s*(.+)")
		if fp then
			-- Migrate value to UCI before removing
			local c = uci_cursor()
			c:set("nodemanager", "main", "fingerprint", trim(fp))
			c:commit("nodemanager")
		else
			table.insert(filtered, line)
		end
	end
	-- Backup before write
	if fs.access(path) then
		fs.copy(path, path .. ".bak")
	end
	return fs.writefile(path, table.concat(filtered, "\n"))
end

-- ============================================================
-- Proxy Type Schemas
-- ============================================================
local SCHEMAS = {
	socks5 = {
		required = {"username", "password"},
		output = function(p, fp)
			local s = string.format(
				'  - {name: "%s", type: socks5, server: "%s", port: %s, username: "%s", password: "%s"',
				p.name, p.server, p.port, p.username or "", p.password or "")
			if fp and fp ~= "" then s = s .. string.format(', client-fingerprint: "%s"', fp) end
			return s .. "}"
		end
	},
	http = {
		required = {},
		output = function(p, fp)
			local base = string.format('  - {name: "%s", type: http, server: "%s", port: %s',
				p.name, p.server, p.port)
			if p.username and p.username ~= "" then
				base = base .. string.format(', username: "%s", password: "%s"', p.username, p.password or "")
			end
			if fp and fp ~= "" then base = base .. string.format(', client-fingerprint: "%s"', fp) end
			return base .. "}"
		end
	}
}

local MANAGED_TYPES = {}
for k, _ in pairs(SCHEMAS) do MANAGED_TYPES[k] = true end

local function detect_managed_type(line)
	local ptype = line:match("type:%s*(%w+)")
	if ptype and MANAGED_TYPES[ptype] then return ptype end
	-- Detect socks5 via YAML anchor reference <<: *s5
	if line:match("%*s5") then return "socks5" end
	return nil
end

local function parse_proxies(lines)
	local proxies = {}
	local in_block = false
	for _, line in ipairs(lines) do
		if line:match("^proxies:") then
			in_block = true
		elseif in_block and line:match("^%S") then
			break  -- left proxies block
		elseif in_block and line:match("^%s*-%s*{") then
			local ptype = detect_managed_type(line)
			if ptype then
				local name     = line:match('name:%s*"([^"]*)"') or line:match("name:%s*([^,}]+)")
				local server   = line:match('server:%s*"([^"]*)"') or line:match("server:%s*([^,}]+)")
				local port     = line:match("port:%s*(%d+)")
				local username = line:match('username:%s*"([^"]*)"') or line:match("username:%s*([^,}]+)")
				local password = line:match('password:%s*"([^"]*)"') or line:match("password:%s*([^,}]+)")

				if name and server and port then
					table.insert(proxies, {
						name     = trim(name),
						type     = trim(ptype),
						server   = trim(server),
						port     = tonumber(port),
						username = trim(username or ""),
						password = trim(password or ""),
					})
				end
			end
		end
	end
	return proxies
end

-- Extract ALL proxy names from config (including unsupported types)
local function parse_all_proxy_names(lines)
	local names = {}
	local in_block = false
	for _, line in ipairs(lines) do
		if line:match("^proxies:") then in_block = true
		elseif in_block then
			if line:match("^%S") and not line:match("^%s") then break end
			local name = line:match('name:%s*"([^"]*)"') or line:match('name:%s*([^,}]+)')
			if name then names[trim(name)] = true end
		end
	end
	return names
end

-- Fill empty names + global dedup (avoids collision with vless/vmess etc.)
local function normalize_names(list, reserved)
	local used = {}
	for name in pairs(reserved or {}) do used[name] = 1 end
	-- First pass: fill empty names with NM-001 pattern
	local seq = 1
	for _, p in ipairs(list) do
		if not p.name or trim(p.name) == "" then
			p.name = string.format("NM-%03d", seq)
		end
		seq = seq + 1
	end
	-- Second pass: dedup
	for _, p in ipairs(list) do
		local base = p.name
		while used[p.name] do
			used[p.name] = used[p.name] + 1
			p.name = base .. "-" .. used[p.name]
		end
		used[p.name] = 1
	end
end

-- Normalize bind IP: .0 → /24, /32 → strip, CIDR → keep
local function normalize_bindip(ip)
	ip = trim(ip)
	local addr, mask = ip:match("^([%d%.]+)/(%d+)$")
	if addr and mask then
		local m = tonumber(mask)
		if m == 32 then return addr end  -- /32 = single IP, strip
		return addr .. "/" .. mask
	else
		-- No CIDR: check if last octet is 0
		if ip:match("%.0$") then
			return ip .. "/24"  -- .0 = user means subnet
		end
		return ip
	end
end

local function parse_bindmap(lines)
	local map = {}
	local in_rules = false
	for _, line in ipairs(lines) do
		if line:match("^rules:") then in_rules = true
		elseif in_rules then
			if line:match("^%S") and not line:match("^%s") then break end
			-- Match both SRC-IP-CIDR and SRC-IP
			local ip, name = line:match("SRC%-IP%-CIDR,([%d%./]+),(.+)")
			if not ip then
				ip, name = line:match("SRC%-IP,([%d%.]+),(.+)")
			end
			if ip and name then
				name = trim(name)
				if not map[name] then map[name] = {} end
				table.insert(map[name], trim(ip))
			end
		end
	end
	return map
end

local function parse_providers(lines)
	local providers = {}
	local in_section = false
	local current = nil
	for _, line in ipairs(lines) do
		if line:match("^proxy%-providers:") then
			in_section = true
		elseif in_section then
			if line:match("^%S") and not line:match("^%s") then
				in_section = false
			else
				local pname = line:match("^  (%S+):")
				if pname and pname ~= "<<" and pname ~= NM_PROVIDER_NAME then
					current = {name = pname, url = ""}
					table.insert(providers, current)
				elseif pname == NM_PROVIDER_NAME then
					-- Skip nm-nodes (internal provider, not user-managed)
					current = nil
				elseif current then
					local url = line:match('url:%s*"([^"]*)"')
					if url then current.url = url end
				end
			end
		end
	end
	return providers
end

local DNS_KEYS = {
	"proxy-server-nameserver",
	"default-nameserver",
	"direct-nameserver",
	"nameserver",
}

local function parse_dns_servers(lines)
	local result = {}
	for _, k in ipairs(DNS_KEYS) do result[k] = {} end

	local in_dns = false
	local cur_key = nil
	for _, line in ipairs(lines) do
		if line:match("^dns:") then
			in_dns = true
			cur_key = nil
		elseif in_dns and line:match("^%S") then
			break  -- left dns block
		elseif in_dns then
			-- Skip blank lines (config may have empty lines between key and values)
			if line:match("^%s*$") then
				-- do nothing, keep cur_key
			else
				-- Try to match a known key header
				local found_key = false
				for _, k in ipairs(DNS_KEYS) do
					local pat = "^%s+" .. k:gsub("%-", "%%-") .. ":"
					if line:match(pat) then
						cur_key = k
						found_key = true
						break
					end
				end
				if not found_key and cur_key then
					local val = line:match("^%s+%-%s+(.+)")
					if val then
						table.insert(result[cur_key], trim(val))
					elseif not line:match("^%s+%-") then
						-- Not a list item → this key's block ended
						cur_key = nil
					end
				end
			end
		end
	end
	return result
end

-- ============================================================
-- YAML Writers (Lua tables → write back config.yaml)
-- ============================================================
local function save_proxies_to_lines(list, lines)
	-- Find proxies: section boundaries
	local section_start, section_end
	for i, line in ipairs(lines) do
		if line:match("^proxies:") then
			section_start = i
		elseif section_start and not section_end and line:match("^%S") then
			section_end = i - 1
		end
	end
	if not section_start then
		-- No proxies: section, create one at end
		table.insert(lines, "")
		table.insert(lines, "proxies:")
		section_start = #lines
		section_end = #lines
	end
	if not section_end then section_end = #lines end

	-- Build new proxy lines
	local new_proxy_lines = {}
	for _, p in ipairs(list) do
		local schema = SCHEMAS[p.type or "socks5"] or SCHEMAS.socks5
		table.insert(new_proxy_lines, schema.output(p))
	end

	-- Rebuild: keep non-managed lines, strip old managed lines and anchor comments
	local result = {}
	for i = 1, section_start do table.insert(result, lines[i]) end
	for i = section_start + 1, section_end do
		local line = lines[i]
		local is_managed = line:match("^%s*-%s*{") and detect_managed_type(line)
		local is_anchor = line:match("落地节点信息")
		if not is_managed and not is_anchor then
			table.insert(result, line)
		end
	end
	-- Append managed proxies at end of section
	for _, nl in ipairs(new_proxy_lines) do table.insert(result, nl) end
	-- Rest of file
	for i = section_end + 1, #lines do table.insert(result, lines[i]) end
	return result
end

local function save_rules_to_lines(list, lines)
	-- Build SRC-IP / SRC-IP-CIDR rules from bindips
	local rules = {}
	for _, p in ipairs(list) do
		if p.bindips then
			for _, raw_ip in ipairs(p.bindips) do
				local ip = normalize_bindip(raw_ip)
				if ip:match("/") then
					table.insert(rules, string.format("  - SRC-IP-CIDR,%s,%s", ip, p.name))
				else
					table.insert(rules, string.format("  - SRC-IP,%s,%s", ip, p.name))
				end
			end
		end
	end

	-- Find rules section and replace SRC-IP lines
	local result = {}
	local in_rules = false
	local rules_inserted = false
	for _, line in ipairs(lines) do
		if line:match("^rules:") then
			in_rules = true
			table.insert(result, line)
			-- Insert SRC-IP rules right after "rules:"
			for _, r in ipairs(rules) do
				table.insert(result, r)
			end
			rules_inserted = true
		elseif in_rules and line:match("SRC%-IP") then
			-- Skip old SRC-IP and SRC-IP-CIDR lines
		else
			if in_rules and line:match("^%S") and not line:match("^%s") then
				in_rules = false
			end
			table.insert(result, line)
		end
	end

	if not rules_inserted and #rules > 0 then
		-- Append rules section
		table.insert(result, "rules:")
		for _, r in ipairs(rules) do table.insert(result, r) end
	end

	return result
end

-- Write managed proxies to separate provider file (no YAML anchors)
local function write_provider_file(list, fingerprint)
	local content = {}
	if #list == 0 then
		table.insert(content, "proxies: []")
	else
		table.insert(content, "proxies:")
		for _, p in ipairs(list) do
			local schema = SCHEMAS[p.type or "socks5"] or SCHEMAS.socks5
			table.insert(content, schema.output(p, fingerprint))
		end
	end
	local data = table.concat(content, "\n") .. "\n"
	-- Dual write: persistent + runtime
	local storage = nm_storage_path()
	local runtime = nm_runtime_path()
	local sdir = storage:match("^(.+)/[^/]+$") or "/"
	local rdir = runtime:match("^(.+)/[^/]+$") or "/"
	sys.call(string.format("mkdir -p %q >/dev/null 2>&1", sdir))
	sys.call(string.format("mkdir -p %q >/dev/null 2>&1", rdir))
	fs.writefile(storage, data)
	if storage ~= runtime then fs.writefile(runtime, data) end
	return true
end

-- Read proxies from provider file (persistent storage is source of truth)
local function read_provider_proxies()
	-- Read from persistent storage first
	local content = fs.readfile(nm_storage_path())
	-- Fallback: try runtime path
	if not content or content == "" or content:match("^proxies:%s*%[%]") then
		content = fs.readfile(nm_runtime_path())
	end
	if not content then return {} end
	local lines = {}
	for line in content:gmatch("[^\n]*") do table.insert(lines, line) end
	-- Reuse parse_proxies logic on these lines (provider file has proxies: header)
	local proxies = {}
	local in_block = false
	for _, line in ipairs(lines) do
		if line:match("^proxies:") then
			in_block = true
		elseif in_block and line:match("^%S") then
			break
		elseif in_block and line:match("^%s*-%s*{") then
			local ptype = detect_managed_type(line)
			if ptype then
				local name     = line:match('name:%s*"([^"]*)"') or line:match("name:%s*([^,}]+)")
				local server   = line:match('server:%s*"([^"]*)"') or line:match("server:%s*([^,}]+)")
				local port     = line:match("port:%s*(%d+)")
				local username = line:match('username:%s*"([^"]*)"') or line:match("username:%s*([^,}]+)")
				local password = line:match('password:%s*"([^"]*)"') or line:match("password:%s*([^,}]+)")
				if name and server and port then
					table.insert(proxies, {
						name     = trim(name),
						type     = trim(ptype),
						server   = trim(server),
						port     = tonumber(port),
						username = trim(username or ""),
						password = trim(password or ""),
					})
				end
			end
		end
	end
	return proxies
end

-- Parse dialer-proxy from YAML anchor definition (e.g. s5: &s5 ... dialer-proxy: xxx)
local function parse_dialer_proxy(lines)
	local in_anchor = false
	for _, line in ipairs(lines) do
		if line:match("^s5:%s*&s5") or line:match("^s5:%s*$") then
			in_anchor = true
		elseif in_anchor then
			if line:match("^%S") and not line:match("^%s") then break end
			local dp = line:match("dialer%-proxy:%s*(.+)")
			if dp then return trim(dp) end
		end
	end
	return nil
end

-- Ensure proxy-providers: has exactly one nm-nodes entry
local function save_provider_entry_to_lines(lines, dialer_proxy)
	local entry_lines = {}
	table.insert(entry_lines, string.format('  %s:', NM_PROVIDER_NAME))
	table.insert(entry_lines, '    type: file')
	table.insert(entry_lines, string.format('    path: %s', NM_PROVIDER_FILE))
	if dialer_proxy and dialer_proxy ~= "" then
		table.insert(entry_lines, '    override:')
		table.insert(entry_lines, string.format('      dialer-proxy: "%s"', dialer_proxy))
	end
	table.insert(entry_lines, '    health-check:')
	table.insert(entry_lines, '      enable: false')

	-- Find proxy-providers: section
	local section_start, section_end
	for i, line in ipairs(lines) do
		if line:match("^proxy%-providers:") then
			section_start = i
		elseif section_start and not section_end and line:match("^%S") then
			section_end = i - 1
		end
	end

	if not section_start then
		table.insert(lines, "")
		table.insert(lines, "proxy-providers:")
		for _, el in ipairs(entry_lines) do table.insert(lines, el) end
		return lines
	end
	if not section_end then section_end = #lines end

	-- Strip ALL existing nm-nodes blocks from section
	local result = {}
	local skip = false
	for i, line in ipairs(lines) do
		if i > section_start and i <= section_end then
			if line:match("^  " .. NM_PROVIDER_NAME .. ":") then
				skip = true  -- entering nm-nodes block, skip it
			elseif skip and line:match("^  %S") then
				skip = false  -- hit next provider, stop skipping
			end
			if not skip then
				table.insert(result, line)
			end
		else
			table.insert(result, line)
		end
	end

	-- Find new section end after stripping
	local insert_at = #result
	for i, line in ipairs(result) do
		if line:match("^proxy%-providers:") then
			section_start = i
		elseif i > section_start and line:match("^%S") then
			insert_at = i - 1
			break
		end
	end

	-- Insert one fresh nm-nodes entry at end of section
	local final = {}
	for i = 1, insert_at do table.insert(final, result[i]) end
	for _, el in ipairs(entry_lines) do table.insert(final, el) end
	for i = insert_at + 1, #result do table.insert(final, result[i]) end
	return final
end

-- Save proxy group with use: [nm-nodes]
local function save_proxy_group_to_lines(lines)
	local group_lines = {}
	table.insert(group_lines, string.format('  - name: "%s"', NM_GROUP_NAME))
	table.insert(group_lines, '    type: select')
	table.insert(group_lines, '    use:')
	table.insert(group_lines, string.format('      - %s', NM_PROVIDER_NAME))

	-- Find proxy-groups: section
	local section_start, section_end
	for i, line in ipairs(lines) do
		if line:match("^proxy%-groups:") then
			section_start = i
		elseif section_start and not section_end and line:match("^%S") then
			section_end = i - 1
		end
	end

	if not section_start then
		table.insert(lines, "")
		table.insert(lines, "proxy-groups:")
		for _, gl in ipairs(group_lines) do table.insert(lines, gl) end
		return lines
	end
	if not section_end then section_end = #lines end

	-- Find existing group
	local grp_start, grp_end
	local escaped_name = NM_GROUP_NAME:gsub("([%%%.%+%-%*%?%[%^%$%(%)%{%}])", "%%%1")
	for i = section_start + 1, section_end do
		local line = lines[i]
		if line:match(escaped_name) then
			grp_start = i
		elseif grp_start and not grp_end then
			if line:match("^%s+%-%s+name:") or (i == section_end and not line:match("^%s")) then
				grp_end = i - 1
			end
		end
	end
	if grp_start and not grp_end then grp_end = section_end end

	local result = {}
	if grp_start then
		for i = 1, grp_start - 1 do table.insert(result, lines[i]) end
		for _, gl in ipairs(group_lines) do table.insert(result, gl) end
		for i = grp_end + 1, #lines do table.insert(result, lines[i]) end
	else
		for i = 1, section_end do table.insert(result, lines[i]) end
		for _, gl in ipairs(group_lines) do table.insert(result, gl) end
		for i = section_end + 1, #lines do table.insert(result, lines[i]) end
	end
	return result
end

local function save_providers_to_lines(list, lines)
	local result = {}
	local in_section = false
	local skip_sub = false
	for _, line in ipairs(lines) do
		if line:match("^proxy%-providers:") then
			in_section = true
			table.insert(result, line)
			-- Write new providers
			for _, p in ipairs(list) do
				table.insert(result, string.format("  %s:", p.name))
				table.insert(result, "    <<: *airport")
				table.insert(result, string.format('    url: "%s"', p.url))
			end
			skip_sub = true
		elseif in_section and skip_sub then
			if line:match("^%S") and not line:match("^%s") then
				in_section = false
				skip_sub = false
				table.insert(result, line)
			end
			-- else skip old provider lines
		else
			table.insert(result, line)
		end
	end
	return result
end

local function save_dns_to_lines(dns_map, lines)
	-- dns_map = { ["nameserver"] = {...}, ["default-nameserver"] = {...}, ... }
	local result = {}
	local in_dns = false
	local cur_key = nil
	local skip_items = false
	local written_keys = {}  -- track which keys we've already written

	for _, line in ipairs(lines) do
		if line:match("^dns:") then
			in_dns = true
			table.insert(result, line)
		elseif in_dns and line:match("^%S") then
			-- Leaving dns block: insert any keys not yet written
			for _, k in ipairs(DNS_KEYS) do
				if not written_keys[k] and dns_map[k] and #dns_map[k] > 0 then
					-- insert before leaving dns block
					table.insert(result, "  " .. k .. ":")
					for _, v in ipairs(dns_map[k]) do
						table.insert(result, "    - " .. v)
					end
				end
			end
			in_dns = false
			cur_key = nil
			table.insert(result, line)
		elseif in_dns then
			local matched_key = nil
			for _, k in ipairs(DNS_KEYS) do
				if line:match("^%s+" .. k:gsub("%-", "%%-") .. ":") then
					matched_key = k
					break
				end
			end
			if matched_key then
				cur_key = matched_key
				skip_items = true
				written_keys[matched_key] = true
				if dns_map[matched_key] and #dns_map[matched_key] > 0 then
					table.insert(result, line)  -- keep the key line
					for _, v in ipairs(dns_map[matched_key]) do
						table.insert(result, "    - " .. v)
					end
				end
				-- else: empty list, skip the key line entirely (remove it)
			elseif skip_items and line:match("^%s+%-") then
				-- skip old list items
			else
				skip_items = false
				cur_key = nil
				table.insert(result, line)
			end
		else
			table.insert(result, line)
		end
	end
	return result
end

-- ============================================================
-- Import Pipeline (auto-detect format)
-- ============================================================
local function parse_url_or_hostport(s)
	s = trim(s)
	-- URL format: socks5://user:pass@host:port  or  http://user:pass@host:port
	local scheme, rest = s:match("^(socks5h?|https?)://(.+)$")
	if not scheme then
		scheme, rest = s:match("^(socks5h?)://(.+)$")
	end
	if not scheme then
		scheme, rest = s:match("^(https?)://(.+)$")
	end

	local user, pass, host, port, fragment
	if scheme then
		-- Normalize scheme
		if scheme == "socks5h" then scheme = "socks5" end
		if scheme == "https" then scheme = "http" end

		-- Extract fragment as name
		rest, fragment = rest:match("^(.-)#(.*)$")
		if not rest then rest = s:match("://(.+)$"); fragment = nil end

		-- user:pass@host:port
		user, pass, host, port = rest:match("^([^:]+):([^@]+)@([^:]+):(%d+)")
		if not host then
			host, port = rest:match("^([^:]+):(%d+)")
		end
	else
		-- Plain format: user:pass@host:port  or  host:port
		user, pass, host, port = s:match("^([^:]+):([^@]+)@([^:]+):(%d+)")
		if not host then
			host, port = s:match("^([^:]+):(%d+)$")
		end
		scheme = "socks5"  -- default
	end

	if not host or not port then return nil end

	return {
		type     = scheme or "socks5",
		server   = trim(host),
		port     = tonumber(port),
		username = trim(user or ""),
		password = trim(pass or ""),
		name     = trim(fragment or "")
	}
end

local function parse_json_import(text)
	local data = require("luci.jsonc").parse(text)
	if not data then return false, nil, "Invalid JSON" end
	-- Handle both array and {proxies: [...]} format
	local arr = data
	if type(data) == "table" and data.proxies then arr = data.proxies end
	if type(arr) ~= "table" then return false, nil, "Expected array" end

	local result = {}
	for _, item in ipairs(arr) do
		if type(item) == "table" and item.server then
			table.insert(result, {
				name     = item.name or (item.server .. ":" .. (item.port or 0)),
				type     = item.type or "socks5",
				server   = item.server,
				port     = tonumber(item.port) or 0,
				username = item.username or "",
				password = item.password or "",
			})
		end
	end
	return true, result
end

local function parse_yaml_import(text)
	local result = {}
	for line in text:gmatch("[^\n]+") do
		if line:match("^%s*%-") then
			local name     = line:match('name:%s*"([^"]*)"') or line:match("name:%s*([^,}]+)")
			local server   = line:match('server:%s*"([^"]*)"') or line:match("server:%s*([^,}]+)")
			local port     = line:match("port:%s*(%d+)")
			local ptype    = line:match("type:%s*(%w+)")
			local username = line:match('username:%s*"([^"]*)"') or line:match("username:%s*([^,}]+)")
			local password = line:match('password:%s*"([^"]*)"') or line:match("password:%s*([^,}]+)")

			if name and server and port then
				if ptype and ptype:match("socks") then ptype = "socks5" end
				table.insert(result, {
					name     = trim(name),
					type     = trim(ptype or "socks5"),
					server   = trim(server),
					port     = tonumber(port),
					username = trim(username or ""),
					password = trim(password or ""),
				})
			end
		end
	end
	if #result == 0 then return false, nil, "No proxies found in YAML" end
	return true, result
end

local function parse_lines_import(text)
	local result = {}
	local idx = 0
	for line in text:gmatch("[^\n]+") do
		line = trim(line)
		if line ~= "" and not line:match("^#") then
			-- Extract trailing comment as name
			local content, comment = line:match("^(.-)%s*#%s*(.+)$")
			content = content or line
			content = trim(content)

			local node = parse_url_or_hostport(content)
			if node then
				idx = idx + 1
				if node.name == "" then
					node.name = comment or (node.server .. ":" .. node.port)
				end
				table.insert(result, node)
			end
		end
	end
	if #result == 0 then return false, nil, "No valid proxies found" end
	return true, result
end

local function detect_and_parse(text)
	text = trim(text)
	if #text > 65536 then
		return false, nil, "Input too large (max 64KB)"
	end
	if text == "" then
		return false, nil, "Empty input"
	end

	-- 1. JSON?
	if text:match("^%s*[{%[]") then
		return parse_json_import(text)
	end

	-- 2. YAML proxies block?
	if text:match("%-%s*{?name:") or text:match("%-%s*name:") then
		return parse_yaml_import(text)
	end

	-- 3. Lines (TXT / URL)
	return parse_lines_import(text)
end

-- ============================================================
-- Validation
-- ============================================================
local function validate_proxy(p)
	if not p.name or trim(p.name) == "" then return "missing name" end
	if not p.server or not p.server:match("^[%w%.%-]+$") then return "invalid server" end
	local port = tonumber(p.port)
	if not port or port < 1 or port > 65535 then return "invalid port" end
	p.port = port
	p.type = p.type or "socks5"
	if not SCHEMAS[p.type] then return "unsupported type: " .. p.type end
	return nil
end

-- ============================================================
-- Service Status
-- ============================================================
local function get_service_status()
	local running = sys.call("pgrep -f mihomo >/dev/null 2>&1") == 0
	local version = ""
	local api_port = 9090
	if running then
		local data = http_get_json("http://127.0.0.1:" .. api_port .. "/version")
		if data and data.version then version = data.version end
	end
	return {running = running, version = version, api_port = api_port}
end

-- ============================================================
-- Ensure config file exists
-- ============================================================


-- ============================================================
-- API Handlers
-- ============================================================
HANDLERS["load"] = function()
	local lines = read_lines()
	-- Read proxies: prefer provider file, fallback to main config (migration)
	local proxies = read_provider_proxies()
	if #proxies == 0 then
		proxies = parse_proxies(lines)
	end
	local bindmap = parse_bindmap(lines)
	for _, p in ipairs(proxies) do
		p.bindips = bindmap[p.name] or {}
	end
	json_out({
		ok = true,
		data = {
			proxies   = proxies,
			providers = parse_providers(lines),
			dns       = parse_dns_servers(lines),
			status    = get_service_status(),
			schemas   = (function()
				local s = {}
				for k, v in pairs(SCHEMAS) do
					s[k] = {required = v.required}
				end
				return s
			end)()
		}
	})
end

-- Get client-fingerprint: migrate from global config → UCI, fallback to UCI default
local function get_fingerprint(lines)
	local c = uci_cursor()
	-- 1. Check main config for deprecated global-client-fingerprint
	local global_fp = nil
	for _, line in ipairs(lines) do
		local fp = line:match("^%s*global%-client%-fingerprint:%s*(.+)")
		if fp then global_fp = trim(fp); break end
	end
	-- 2. If found, migrate to UCI and mark for deletion
	if global_fp and global_fp ~= "" then
		c:set("nodemanager", "main", "fingerprint", global_fp)
		c:commit("nodemanager")
	end
	-- 3. Read from UCI (includes migrated or default value)
	local fp = c:get_first("nodemanager", "main", "fingerprint") or ""
	return fp, (global_fp ~= nil)
end

-- Remove global-client-fingerprint line from config
local function strip_global_fingerprint(lines)
	local result = {}
	for _, line in ipairs(lines) do
		if not line:match("^%s*global%-client%-fingerprint:") then
			table.insert(result, line)
		end
	end
	return result
end

HANDLERS["save_proxies"] = function()
	local input = json_in()
	local list = input.proxies
	if type(list) ~= "table" then
		return json_out({ok = false, err = "Invalid data"})
	end
	-- Auto-fill empty names + dedup against existing config
	local lines = read_lines()
	local reserved = parse_all_proxy_names(lines)
	-- Also remove provider proxy names from reserved
	local old_provider = read_provider_proxies()
	for _, p in ipairs(old_provider) do reserved[p.name] = nil end
	-- Also remove inline managed from reserved (migration)
	local managed = parse_proxies(lines)
	for _, p in ipairs(managed) do reserved[p.name] = nil end
	normalize_names(list, reserved)
	-- Validate
	for i, p in ipairs(list) do
		local err = validate_proxy(p)
		if err then
			return json_out({ok = false, err = string.format("Row %d: %s", i, err)})
		end
	end
	-- 0. Read client-fingerprint from UCI for per-proxy injection
	local fingerprint = get_fingerprint(lines)
	-- 1. Write provider file (separate file, with fingerprint)
	write_provider_file(list, fingerprint)
	-- 2. Clean inline managed proxies from main config
	lines = save_proxies_to_lines({}, lines)
	-- 3. Parse dialer-proxy from anchor definition
	local dialer = parse_dialer_proxy(lines)
	-- 4. Ensure proxy-providers entry
	lines = save_provider_entry_to_lines(lines, dialer)
	-- 5. Update proxy group
	lines = save_proxy_group_to_lines(lines)
	-- 6. SRC-IP rules
	lines = save_rules_to_lines(list, lines)
	if write_lines(lines) then
		json_out({ok = true})
	else
		json_out({ok = false, err = "Write failed"})
	end
end

HANDLERS["save_providers"] = function()
	local input = json_in()
	local list = input.providers
	if type(list) ~= "table" then
		return json_out({ok = false, err = "Invalid data"})
	end
	for i, p in ipairs(list) do
		if not p.name or trim(p.name) == "" then
			return json_out({ok = false, err = string.format("Row %d: missing name", i)})
		end
		if not p.url or not p.url:match("^https?://") then
			return json_out({ok = false, err = string.format("Row %d: invalid URL", i)})
		end
	end
	local lines = read_lines()
	lines = save_providers_to_lines(list, lines)
	if write_lines(lines) then
		json_out({ok = true})
	else
		json_out({ok = false, err = "Write failed"})
	end
end

HANDLERS["debug_dns"] = function()
	local lines = read_lines()
	local dns_result = parse_dns_servers(lines)
	local raw_dns = {}
	local in_dns = false
	for i, line in ipairs(lines) do
		if line:match("^dns:") then in_dns = true end
		if in_dns then
			table.insert(raw_dns, string.format("L%d: %s", i, line))
			if in_dns and line:match("^%S") and not line:match("^dns:") then break end
		end
	end
	json_out({ok = true, dns_parsed = dns_result, raw_lines = raw_dns, total_lines = #lines})
end

HANDLERS["test_dns"] = function()
	local input = json_in()
	local server = input.server
	if not server or server == "" then
		return json_out({ok = false, err = "No server specified"})
	end
	-- Extract host/IP from any format:
	--   223.5.5.5 → 223.5.5.5
	--   tls://223.5.5.5 → 223.5.5.5
	--   https://dns.alidns.com/dns-query?ecs=... → dns.alidns.com
	--   https://8.8.8.8/dns-query → 8.8.8.8
	local host = server:match("^%w+://([^/:?]+)") or server:match("^([%d%.]+)") or server:match("^([^/:?]+)")
	if not host then
		return json_out({ok = false, err = "Cannot parse server address"})
	end
	-- Random subdomain to prevent DNS cache hits
	local rand = string.format("nm%d.google.com", os.time() % 100000)
	local nixio = require "nixio"
	local s0, u0 = nixio.gettimeofday()
	local cmd = string.format("nslookup %s %s >/dev/null 2>&1", rand, host)
	local code = sys.call(cmd)
	local s1, u1 = nixio.gettimeofday()
	local delay = (s1 - s0) * 1000 + math.floor((u1 - u0) / 1000)
	if code == 0 then
		json_out({ok = true, data = {delay = delay, host = host}})
	else
		json_out({ok = false, err = "DNS query failed", host = host})
	end
end

HANDLERS["save_dns"] = function()
	local input = json_in()
	local dns_map = input.dns
	if type(dns_map) ~= "table" then
		return json_out({ok = false, err = "Invalid data"})
	end
	-- Validate: dns_map should be { "nameserver": [...], "default-nameserver": [...], ... }
	for _, k in ipairs(DNS_KEYS) do
		if dns_map[k] and type(dns_map[k]) ~= "table" then
			return json_out({ok = false, err = k .. ": must be array"})
		end
		dns_map[k] = dns_map[k] or {}
	end
	local lines = read_lines()
	lines = save_dns_to_lines(dns_map, lines)
	if write_lines(lines) then
		json_out({ok = true})
	else
		json_out({ok = false, err = "Write failed"})
	end
end




HANDLERS["import"] = function()
	local input = json_in()
	local text = input.text
	if not text or type(text) ~= "string" then
		return json_out({ok = false, err = "Missing text field"})
	end
	local ok, result, err = detect_and_parse(text)
	if not ok then
		return json_out({ok = false, err = err or "Parse failed"})
	end
	-- Limit to 500 entries
	if #result > 500 then
		return json_out({ok = false, err = "Too many entries (max 500)"})
	end
	-- Auto-fill empty names + dedup against ALL existing names in config
	local reserved = parse_all_proxy_names(read_lines())
	normalize_names(result, reserved)
	-- Validate each result
	for i, p in ipairs(result) do
		local verr = validate_proxy(p)
		if verr then
			result[i]._warning = verr
		end
	end
	json_out({ok = true, data = result})
end

HANDLERS["test_proxy"] = function()
	local name = http.formvalue("name")
	if not name or name == "" then
		return json_out({ok = false, err = "Missing proxy name"})
	end
	local status = get_service_status()
	if not status.running then
		return json_out({ok = false, err = "nikki is not running"})
	end
	-- URL encode the proxy name for the Mihomo API
	local encoded = name:gsub("([^%w%-%.%_%~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
	local url = string.format(
		"http://127.0.0.1:%d/proxies/%s/delay?url=%s&timeout=5000",
		status.api_port, encoded,
		"https://www.gstatic.com/generate_204")
	local data, err = http_get_json(url)
	if data and data.delay then
		json_out({ok = true, data = {delay = data.delay}})
	else
		json_out({ok = false, err = (data and data.message) or err or "timeout"})
	end
end

HANDLERS["get_logs"] = function()
	local log = sys.exec("logread 2>/dev/null | grep -i nodemanager | tail -n 200") or ""
	json_out({ok = true, data = {log = log}})
end

HANDLERS["service"] = function()
	local input = json_in()
	local cmd = input.cmd
	if cmd ~= "start" and cmd ~= "stop" and cmd ~= "restart" then
		return json_out({ok = false, err = "Invalid command"})
	end
	sys.call("/etc/init.d/nikki " .. cmd .. " >/dev/null 2>&1")
	-- Brief delay to allow process to start/stop
	sys.call("sleep 1")
	json_out({ok = true, data = {status = get_service_status()}})
end
