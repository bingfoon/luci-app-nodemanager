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

local function conf_path()
	local c = uci_cursor()
	return c:get_first("nodemanager", "main", "path") or "/etc/nikki/profiles/config.yaml"
end

local function tpl_path()
	local c = uci_cursor()
	return c:get_first("nodemanager", "main", "template") or "/usr/share/nodemanager/config.template.yaml"
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
	for line in content:gmatch("[^\n]*") do
		table.insert(lines, line)
	end
	return lines
end

local function write_lines(lines)
	local path = conf_path()
	-- Backup before write
	if fs.access(path) then
		fs.copy(path, path .. ".bak")
	end
	return fs.writefile(path, table.concat(lines, "\n"))
end

-- ============================================================
-- Proxy Type Schemas
-- ============================================================
local SCHEMAS = {
	socks5 = {
		anchor = "s5",
		required = {"username", "password"},
		output = function(p)
			return string.format(
				'  - {<<: *s5, name: "%s", server: "%s", port: %s, username: "%s", password: "%s"}',
				p.name, p.server, p.port, p.username or "", p.password or "")
		end
	},
	http = {
		anchor = nil,
		required = {},
		output = function(p)
			local base = string.format('  - {name: "%s", type: http, server: "%s", port: %s',
				p.name, p.server, p.port)
			if p.username and p.username ~= "" then
				base = base .. string.format(', username: "%s", password: "%s"', p.username, p.password or "")
			end
			return base .. "}"
		end
	}
}

-- ============================================================
-- YAML Parsers (read config.yaml → Lua tables)
-- ============================================================
local function parse_proxies(lines)
	local proxies = {}
	local in_block = false
	for _, line in ipairs(lines) do
		if line:match("落地节点信息从下面开始添加") then
			in_block = true
		elseif line:match("落地节点信息必须添加在这一行上面") then
			in_block = false
		elseif in_block and line:match("^%s*-%s*{") then
			local name     = line:match('name:%s*"([^"]*)"') or line:match("name:%s*([^,}]+)")
			local server   = line:match('server:%s*"([^"]*)"') or line:match("server:%s*([^,}]+)")
			local port     = line:match("port:%s*(%d+)")
			local username = line:match('username:%s*"([^"]*)"') or line:match("username:%s*([^,}]+)")
			local password = line:match('password:%s*"([^"]*)"') or line:match("password:%s*([^,}]+)")
			local ptype    = line:match("type:%s*(%w+)")

			-- Detect type from anchor reference
			if not ptype and line:match("*s5") then ptype = "socks5" end
			ptype = ptype or "socks5"

			if name and server and port and SCHEMAS[ptype] then
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
	-- First pass: fill empty names
	for _, p in ipairs(list) do
		if not p.name or trim(p.name) == "" then
			p.name = (p.server or "node") .. ":" .. (p.port or 0)
		end
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

local function parse_bindmap(lines)
	local map = {}
	local in_rules = false
	for _, line in ipairs(lines) do
		if line:match("^rules:") then in_rules = true
		elseif in_rules then
			if line:match("^%S") and not line:match("^%s") then break end
			local ip, name = line:match("SRC%-IP,([%d%.]+),(.+)")
			if ip and name then
				if not map[name] then map[name] = {} end
				table.insert(map[name], ip)
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
				if pname and pname ~= "<<" then
					current = {name = pname, url = ""}
					table.insert(providers, current)
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
local function ensure_anchor_block(lines, marker_start, marker_end)
	local found_start = false
	for _, line in ipairs(lines) do
		if line:match(marker_start) then found_start = true; break end
	end
	if not found_start then
		-- Insert before "- {name: 直连" if exists, else before end of proxies
		local insert_pos = #lines
		for i, line in ipairs(lines) do
			if line:match("直连") then insert_pos = i; break end
		end
		table.insert(lines, insert_pos, "  # " .. marker_start)
		table.insert(lines, insert_pos + 1, "  # " .. marker_end)
	end
	return lines
end

local function save_proxies_to_lines(list, lines)
	lines = ensure_anchor_block(lines, "落地节点信息从下面开始添加", "落地节点信息必须添加在这一行上面")

	local start_idx, end_idx
	for i, line in ipairs(lines) do
		if line:match("落地节点信息从下面开始添加") then start_idx = i end
		if line:match("落地节点信息必须添加在这一行上面") then end_idx = i end
	end
	if not start_idx or not end_idx then return lines end

	-- Build new proxy lines
	local new_lines = {}
	for _, p in ipairs(list) do
		local schema = SCHEMAS[p.type or "socks5"] or SCHEMAS.socks5
		table.insert(new_lines, schema.output(p))
	end

	-- Replace everything between markers
	local result = {}
	for i = 1, start_idx do table.insert(result, lines[i]) end
	for _, nl in ipairs(new_lines) do table.insert(result, nl) end
	for i = end_idx, #lines do table.insert(result, lines[i]) end
	return result
end

local function save_rules_to_lines(list, lines)
	-- Build SRC-IP rules from bindips
	local rules = {}
	for _, p in ipairs(list) do
		if p.bindips then
			for _, ip in ipairs(p.bindips) do
				table.insert(rules, string.format("  - SRC-IP,%s,%s", ip, p.name))
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
		elseif in_rules and line:match("SRC%-IP,") then
			-- Skip old SRC-IP lines
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
local function ensure_file()
	local path = conf_path()
	if fs.access(path) then return true end
	local dir = path:match("^(.+)/[^/]+$") or "/"
	sys.call(string.format("mkdir -p %q >/dev/null 2>&1", dir))
	local tpl = tpl_path()
	local content = fs.readfile(tpl)
	if not content or #trim(content) == 0 then
		return false, "Template not found: " .. tostring(tpl)
	end
	fs.writefile(path, content)
	return fs.access(path)
end

-- ============================================================
-- API Handlers
-- ============================================================
HANDLERS["load"] = function()
	ensure_file()
	local lines = read_lines()
	local proxies = parse_proxies(lines)
	local bindmap = parse_bindmap(lines)
	-- Merge bindmap into proxies
	for _, p in ipairs(proxies) do
		p.bindips = bindmap[p.name] or {}
	end
	json_out({
		ok = true,
		data = {
			proxies   = proxies,
			providers = parse_providers(lines),
			dns       = parse_dns_servers(lines),
			settings  = {
				path     = conf_path(),
				template = tpl_path(),
			},
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

HANDLERS["save_proxies"] = function()
	local input = json_in()
	local list = input.proxies
	if type(list) ~= "table" then
		return json_out({ok = false, err = "Invalid data"})
	end
	-- Auto-fill empty names + dedup against existing config
	local lines = read_lines()
	local reserved = parse_all_proxy_names(lines)
	-- Remove names of our managed types from reserved (we're replacing them)
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
	-- Save
	lines = save_proxies_to_lines(list, lines)
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
	-- Extract host:port from various formats: 223.5.5.5, tls://223.5.5.5, https://dns.alidns.com/dns-query
	local host = server:match("^%w+://([^/:]+)") or server:match("^([%d%.]+)$") or server:match("^([^/:]+)")
	if not host then
		return json_out({ok = false, err = "Cannot parse server address"})
	end
	-- Use nslookup with timeout to test DNS
	local start = sys.call("date +%s%N > /tmp/nm_dns_t0 2>/dev/null || date +%s > /tmp/nm_dns_t0")
	local cmd = string.format(
		"nslookup -timeout=3 google.com %s >/dev/null 2>&1", host)
	local code = sys.call(cmd)
	-- Measure time (fallback: just report success/fail)
	local delay = nil
	local t0_raw = fs.readfile("/tmp/nm_dns_t0")
	if t0_raw then
		local t0 = tonumber(trim(t0_raw))
		sys.call("date +%s%N > /tmp/nm_dns_t1 2>/dev/null || date +%s > /tmp/nm_dns_t1")
		local t1_raw = fs.readfile("/tmp/nm_dns_t1")
		if t1_raw then
			local t1 = tonumber(trim(t1_raw))
			if t0 and t1 then
				if t0 > 1e15 then -- nanoseconds
					delay = math.floor((t1 - t0) / 1e6) -- ms
				else -- seconds
					delay = (t1 - t0) * 1000 -- ms
				end
			end
		end
	end
	os.remove("/tmp/nm_dns_t0")
	os.remove("/tmp/nm_dns_t1")
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

HANDLERS["save_settings"] = function()
	local input = json_in()
	local path = input.path
	local template = input.template
	if path then
		if not is_safe_path(path) then
			return json_out({ok = false, err = "Path not allowed"})
		end
		local c = uci_cursor()
		c:set("nodemanager", c:get_first("nodemanager", "main") or "main", "path", path)
		c:commit("nodemanager")
	end
	if template and template ~= "" then
		local c = uci_cursor()
		c:set("nodemanager", c:get_first("nodemanager", "main") or "main", "template", template)
		c:commit("nodemanager")
	end
	if input.create_if_missing then
		local ok, err = ensure_file()
		if not ok then
			return json_out({ok = false, err = err or "Failed to create config"})
		end
	end
	json_out({ok = true})
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
