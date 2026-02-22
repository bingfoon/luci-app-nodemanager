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
local json_out       -- forward declaration
local check_device   -- forward declaration

function api()
	local action = http.formvalue("action") or ""
	-- Device policy check (allow check_device action to pass through)
	if action ~= "check_device" then
		local dev_ok = check_device()
		if not dev_ok then
			return json_out({ok = false, err = "unsupported_device"})
		end
	end
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

json_out = function(t)
	http.prepare_content("application/json")
	http.write(require("luci.jsonc").stringify(t))
end

local function json_in()
	local raw = http.content()
	if not raw or raw == "" then return {} end
	return require("luci.jsonc").parse(raw) or {}
end

-- ============================================================
-- Device Policy
-- ============================================================
local DEVICE_POLICY_PATH = "/usr/share/nodemanager/device_policy.json"

check_device = function()
	local raw = fs.readfile(DEVICE_POLICY_PATH)
	if not raw then return true end
	local policy = require("luci.jsonc").parse(raw)
	if not policy or policy.mode == "open" then return true end

	local board = trim(fs.readfile("/tmp/sysinfo/model") or "")
	local matched = false
	for _, model in ipairs(policy.models or {}) do
		if board:find(model, 1, true) then matched = true; break end
	end

	local allowed = (policy.mode == "whitelist" and matched)
	             or (policy.mode == "blacklist" and not matched)
	if allowed then return true end
	return false, board, policy
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
local NM_GROUP_NAME = "\240\159\143\160 住宅节点"
local NM_PROVIDER_FILE = "nm_proxies.yaml"
local NM_PREFIX = "[NM] "

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

-- Atomic write: write to .tmp, backup original to .bak, rename into place.
-- Falls back to fs.copy if os.rename fails (cross-device).
-- On any write/flush error the .tmp is cleaned up and original is untouched.
local function atomic_write(path, content)
	local tmp = path .. ".tmp"
	local fh, err = io.open(tmp, "w")
	if not fh then return nil, "open tmp: " .. (err or "?") end
	local wok, werr = fh:write(content)
	if not wok then
		fh:close()
		os.remove(tmp)
		return nil, "write tmp: " .. (werr or "?")
	end
	fh:flush()
	fh:close()
	-- backup original
	if fs.access(path) then fs.copy(path, path .. ".bak") end
	-- atomic rename
	local ok, rerr = os.rename(tmp, path)
	if not ok then
		-- fallback: copy tmp over target (cross-device)
		local cok = fs.copy(tmp, path)
		os.remove(tmp)
		if not cok then return nil, "rename+copy failed: " .. (rerr or "?") end
	end
	return true
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
	return atomic_write(path, table.concat(filtered, "\n"))
end

-- ============================================================
-- Template Rebuild
-- ============================================================

-- Read template file lines
local function read_template_lines()
	local c = uci_cursor()
	local tpl_path = c:get_first("nodemanager", "main", "template")
		or "/usr/share/nodemanager/config.template.yaml"
	local content = fs.readfile(tpl_path)
	if not content then return nil end
	local lines = {}
	for line in (content .. "\n"):gmatch("(.-)[\n]") do
		table.insert(lines, line)
	end
	if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
	return lines
end

-- Find a top-level YAML section (start line, end line)
-- section_key example: "proxy-providers" matches "proxy-providers:"
local function find_section(lines, section_key)
	local pattern = "^" .. section_key:gsub("%-", "%%-") .. ":"
	local s, e
	for i, line in ipairs(lines) do
		if not s then
			if line:match(pattern) then s = i end
		elseif line:match("^%S") then
			e = i - 1
			break
		end
	end
	if s and not e then e = #lines end
	return s, e
end

-- Copy a top-level section from src_lines into dst_lines, replacing dst's section
local function copy_section(src_lines, dst_lines, section_key)
	local ss, se = find_section(src_lines, section_key)
	local ds, de = find_section(dst_lines, section_key)
	if not ss or not ds then return dst_lines end
	local result = {}
	for i = 1, ds - 1 do table.insert(result, dst_lines[i]) end
	for i = ss, se do table.insert(result, src_lines[i]) end
	for i = de + 1, #dst_lines do table.insert(result, dst_lines[i]) end
	return result
end

-- rebuild_config(): defined after helper functions (forward ref)
local rebuild_config  -- forward declaration
local dns_keys_match  -- forward declaration

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
	},
	ss = {
		required = {"password"},
		output = function(p, fp)
			local s = string.format(
				'  - {name: "%s", type: ss, server: "%s", port: %s, cipher: "%s", password: "%s", udp: true',
				p.name, p.server, p.port, p.cipher or "aes-256-gcm", p.password or "")
			if fp and fp ~= "" then s = s .. string.format(', client-fingerprint: "%s"', fp) end
			return s .. "}"
		end
	},
	vmess = {
		required = {"uuid"},
		output = function(p, fp)
			local s = string.format(
				'  - {name: "%s", type: vmess, server: "%s", port: %s, uuid: "%s", alterId: %s, cipher: "%s"',
				p.name, p.server, p.port, p.uuid or "", tonumber(p.alterId) or 0, p.cipher or "auto")
			if p.tls then s = s .. ", tls: true" end
			if p.servername and p.servername ~= "" then s = s .. string.format(', servername: "%s"', p.servername) end
			if p.skip_cert_verify then s = s .. ", skip-cert-verify: true" end
			local net = p.network or "tcp"
			s = s .. string.format(', network: "%s"', net)
			if net == "ws" then
				local ws = {}
				if p.ws_path and p.ws_path ~= "" then table.insert(ws, string.format('path: "%s"', p.ws_path)) end
				if p.ws_host and p.ws_host ~= "" then table.insert(ws, string.format('headers: {Host: "%s"}', p.ws_host)) end
				if #ws > 0 then s = s .. ", ws-opts: {" .. table.concat(ws, ", ") .. "}" end
			elseif net == "grpc" then
				if p.grpc_servicename and p.grpc_servicename ~= "" then
					s = s .. string.format(', grpc-opts: {grpc-service-name: "%s"}', p.grpc_servicename)
				end
			end
			if fp and fp ~= "" then s = s .. string.format(', client-fingerprint: "%s"', fp) end
			s = s .. ", udp: true"
			return s .. "}"
		end
	},
	vless = {
		required = {"uuid"},
		output = function(p, fp)
			local s = string.format(
				'  - {name: "%s", type: vless, server: "%s", port: %s, uuid: "%s"',
				p.name, p.server, p.port, p.uuid or "")
			local net = p.network or "tcp"
			s = s .. string.format(', network: "%s"', net)
			if p.tls then s = s .. ", tls: true" end
			if p.flow and p.flow ~= "" then s = s .. string.format(', flow: "%s"', p.flow) end
			if p.servername and p.servername ~= "" then s = s .. string.format(', servername: "%s"', p.servername) end
			if p.skip_cert_verify then s = s .. ", skip-cert-verify: true" end
			if p.reality_public_key and p.reality_public_key ~= "" then
				local ro = string.format('public-key: "%s"', p.reality_public_key)
				if p.reality_short_id and p.reality_short_id ~= "" then
					ro = ro .. string.format(', short-id: "%s"', p.reality_short_id)
				end
				s = s .. ", reality-opts: {" .. ro .. "}"
			end
			if net == "ws" then
				local ws = {}
				if p.ws_path and p.ws_path ~= "" then table.insert(ws, string.format('path: "%s"', p.ws_path)) end
				if p.ws_host and p.ws_host ~= "" then table.insert(ws, string.format('headers: {Host: "%s"}', p.ws_host)) end
				if #ws > 0 then s = s .. ", ws-opts: {" .. table.concat(ws, ", ") .. "}" end
			elseif net == "grpc" then
				if p.grpc_servicename and p.grpc_servicename ~= "" then
					s = s .. string.format(', grpc-opts: {grpc-service-name: "%s"}', p.grpc_servicename)
				end
			end
			if p.client_fingerprint and p.client_fingerprint ~= "" then
				s = s .. string.format(', client-fingerprint: "%s"', p.client_fingerprint)
			elseif fp and fp ~= "" then
				s = s .. string.format(', client-fingerprint: "%s"', fp)
			end
			s = s .. ", udp: true"
			return s .. "}"
		end
	},
	trojan = {
		required = {"password"},
		output = function(p, fp)
			local s = string.format(
				'  - {name: "%s", type: trojan, server: "%s", port: %s, password: "%s"',
				p.name, p.server, p.port, p.password or "")
			if p.sni and p.sni ~= "" then s = s .. string.format(', sni: "%s"', p.sni) end
			if p.skip_cert_verify then s = s .. ", skip-cert-verify: true" end
			local net = p.network or "tcp"
			if net ~= "tcp" then s = s .. string.format(', network: "%s"', net) end
			if net == "ws" then
				local ws = {}
				if p.ws_path and p.ws_path ~= "" then table.insert(ws, string.format('path: "%s"', p.ws_path)) end
				if p.ws_host and p.ws_host ~= "" then table.insert(ws, string.format('headers: {Host: "%s"}', p.ws_host)) end
				if #ws > 0 then s = s .. ", ws-opts: {" .. table.concat(ws, ", ") .. "}" end
			elseif net == "grpc" then
				if p.grpc_servicename and p.grpc_servicename ~= "" then
					s = s .. string.format(', grpc-opts: {grpc-service-name: "%s"}', p.grpc_servicename)
				end
			end
			if fp and fp ~= "" then s = s .. string.format(', client-fingerprint: "%s"', fp) end
			s = s .. ", udp: true"
			return s .. "}"
		end
	},
	hysteria2 = {
		required = {"password"},
		output = function(p, fp)
			local s = string.format(
				'  - {name: "%s", type: hysteria2, server: "%s", port: %s, password: "%s"',
				p.name, p.server, p.port, p.password or "")
			if p.sni and p.sni ~= "" then s = s .. string.format(', sni: "%s"', p.sni) end
			if p.skip_cert_verify then s = s .. ", skip-cert-verify: true" end
			if p.obfs and p.obfs ~= "" then s = s .. string.format(', obfs: "%s"', p.obfs) end
			if p.obfs_password and p.obfs_password ~= "" then s = s .. string.format(', obfs-password: "%s"', p.obfs_password) end
			if fp and fp ~= "" then s = s .. string.format(', client-fingerprint: "%s"', fp) end
			s = s .. ", udp: true"
			return s .. "}"
		end
	}
}

local MANAGED_TYPES = {}
for k, _ in pairs(SCHEMAS) do MANAGED_TYPES[k] = true end

local function detect_managed_type(line)
	local ptype = line:match("type:%s*(%w+)")
	if ptype then ptype = ptype:lower() end
	if ptype and MANAGED_TYPES[ptype] then return ptype end
	-- Detect socks5 via YAML anchor reference <<: *s5
	if line:match("%*s5") then return "socks5" end
	return nil
end

-- Extract a YAML field value from an inline {key: val, ...} line
local function yaml_field(line, key)
	local pat = key:gsub("%-", "%%-")
	return line:match(pat .. ':%s*"([^"]*)"') or line:match(pat .. ":%s*([^,}%s]+)")
end

-- Extract type-specific fields from a proxy YAML line
local function extract_extra_fields(line, ptype)
	local extra = {}
	if ptype == "ss" then
		extra.cipher = trim(yaml_field(line, "cipher") or "aes-256-gcm")
	elseif ptype == "vmess" then
		extra.uuid = trim(yaml_field(line, "uuid") or "")
		extra.alterId = tonumber(yaml_field(line, "alterId")) or 0
		extra.cipher = trim(yaml_field(line, "cipher") or "auto")
		extra.network = trim(yaml_field(line, "network") or "tcp")
		local tls_val = yaml_field(line, "tls")
		if tls_val then extra.tls = (trim(tls_val) == "true") end
		extra.servername = trim(yaml_field(line, "servername") or "")
		local ws_match = line:match("ws%-opts:%s*{(.-)}")
		if ws_match then
			extra.ws_path = ws_match:match('path:%s*"([^"]*)"') or ws_match:match("path:%s*([^,}%s]+)")
			local hdr = ws_match:match("headers:%s*{(.-)}")
			if hdr then extra.ws_host = hdr:match('Host:%s*"([^"]*)"') or hdr:match("Host:%s*([^,}%s]+)") end
		end
		local grpc_match = line:match("grpc%-opts:%s*{(.-)}")
		if grpc_match then
			extra.grpc_servicename = grpc_match:match('grpc%-service%-name:%s*"([^"]*)"') or grpc_match:match("grpc%-service%-name:%s*([^,}%s]+)")
		end
	elseif ptype == "vless" then
		extra.uuid = trim(yaml_field(line, "uuid") or "")
		extra.network = trim(yaml_field(line, "network") or "tcp")
		extra.flow = trim(yaml_field(line, "flow") or "")
		local tls_val = yaml_field(line, "tls")
		if tls_val then extra.tls = (trim(tls_val) == "true") end
		extra.servername = trim(yaml_field(line, "servername") or "")
		extra.client_fingerprint = trim(yaml_field(line, "client%-fingerprint") or "")
		local reality = line:match("reality%-opts:%s*{(.-)}")
		if reality then
			extra.reality_public_key = reality:match('public%-key:%s*"([^"]*)"') or reality:match("public%-key:%s*([^,}%s]+)")
			extra.reality_short_id = reality:match('short%-id:%s*"([^"]*)"') or reality:match("short%-id:%s*([^,}%s]+)")
		end
		local ws_match = line:match("ws%-opts:%s*{(.-)}")
		if ws_match then
			extra.ws_path = ws_match:match('path:%s*"([^"]*)"') or ws_match:match("path:%s*([^,}%s]+)")
			local hdr = ws_match:match("headers:%s*{(.-)}")
			if hdr then extra.ws_host = hdr:match('Host:%s*"([^"]*)"') or hdr:match("Host:%s*([^,}%s]+)") end
		end
		local grpc_match = line:match("grpc%-opts:%s*{(.-)}")
		if grpc_match then
			extra.grpc_servicename = grpc_match:match('grpc%-service%-name:%s*"([^"]*)"') or grpc_match:match("grpc%-service%-name:%s*([^,}%s]+)")
		end
	elseif ptype == "trojan" then
		extra.sni = trim(yaml_field(line, "sni") or "")
		extra.network = trim(yaml_field(line, "network") or "tcp")
		local scv = yaml_field(line, "skip%-cert%-verify")
		if scv then extra.skip_cert_verify = (trim(scv) == "true") end
		local ws_match = line:match("ws%-opts:%s*{(.-)}")
		if ws_match then
			extra.ws_path = ws_match:match('path:%s*"([^"]*)"') or ws_match:match("path:%s*([^,}%s]+)")
			local hdr = ws_match:match("headers:%s*{(.-)}")
			if hdr then extra.ws_host = hdr:match('Host:%s*"([^"]*)"') or hdr:match("Host:%s*([^,}%s]+)") end
		end
	elseif ptype == "hysteria2" then
		extra.sni = trim(yaml_field(line, "sni") or "")
		extra.obfs = trim(yaml_field(line, "obfs") or "")
		extra.obfs_password = trim(yaml_field(line, "obfs%-password") or "")
		local scv = yaml_field(line, "skip%-cert%-verify")
		if scv then extra.skip_cert_verify = (trim(scv) == "true") end
	end
	for k, v in pairs(extra) do
		if v == "" then extra[k] = nil end
	end
	return extra
end

-- Parse a proxy YAML line into a proxy object with all fields
local function parse_proxy_line(line)
	local ptype = detect_managed_type(line)
	if not ptype then return nil end
	local name     = line:match('name:%s*"([^"]*)"') or line:match("name:%s*([^,}]+)")
	local server   = line:match('server:%s*"([^"]*)"') or line:match("server:%s*([^,}]+)")
	local port     = line:match("port:%s*(%d+)")
	if not name or not server or not port then return nil end

	local proxy = {
		name     = trim(name),
		type     = trim(ptype),
		server   = trim(server),
		port     = tonumber(port),
		username = trim((line:match('username:%s*"([^"]*)"') or line:match("username:%s*([^,}]+)")) or ""),
		password = trim((line:match('password:%s*"([^"]*)"') or line:match("password:%s*([^,}]+)")) or ""),
	}
	local extra = extract_extra_fields(line, ptype)
	for k, v in pairs(extra) do proxy[k] = v end
	return proxy
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
			local proxy = parse_proxy_line(line)
			if proxy then table.insert(proxies, proxy) end
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
	-- Already has CIDR suffix: keep as-is
	if ip:match("^[%d%.]+/%d+$") then return ip end
	-- Infer CIDR from trailing zero octets
	-- x.0.0.0 → /8, x.x.0.0 → /16, x.x.x.0 → /24, else → /32
	local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then return ip .. "/32" end  -- fallback
	if tonumber(b) == 0 and tonumber(c) == 0 and tonumber(d) == 0 then return ip .. "/8"
	elseif tonumber(c) == 0 and tonumber(d) == 0 then return ip .. "/16"
	elseif tonumber(d) == 0 then return ip .. "/24"
	else return ip .. "/32"
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
				-- Strip CIDR suffix for UI display (save path re-adds /32)
				ip = trim(ip):match("^([%d%.]+)") or trim(ip)
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

-- Inject bind proxy-groups: one group per proxy with bindips
-- These groups allow SRC-IP rules to reference provider proxies indirectly
-- (Mihomo validates rules before loading providers, so direct reference fails)
local function inject_bind_groups(lines, list)
	local managed = {}
	for _, p in ipairs(list) do managed[p.name] = true end

	-- Build bind groups for proxies that have bindips
	local bind_groups = {}
	for _, p in ipairs(list) do
		if p.bindips then
			local has_ips = false
			for _, ip in ipairs(p.bindips) do
				if ip and ip ~= "" then has_ips = true; break end
			end
			if has_ips then
				-- Escape regex metacharacters, with YAML double-quote \\ encoding
				local escaped = p.name:gsub("([%.%*%+%?%[%]%(%)%{%}%^%$%|])", "\\\\%1")
				local filter = "^\\\\[NM\\\\] " .. escaped .. "$"
				table.insert(bind_groups, string.format(
					'  - {name: "%s", type: select, use: [%s], filter: "%s"}',
					p.name, NM_PROVIDER_NAME, filter))
			end
		end
	end

	if #bind_groups == 0 and not next(managed) then return lines end

	-- Process proxy-groups section: remove old bind groups, insert new ones
	local result = {}
	local in_pg = false
	local groups_inserted = false
	local escaped_nm_group = NM_GROUP_NAME:gsub("([%%%.%+%-%*%?%[%^%$%(%)%{%}])", "%%%1")

	for _, line in ipairs(lines) do
		if line:match("^proxy%-groups:") then
			in_pg = true
			table.insert(result, line)
		elseif in_pg and line:match("^%S") then
			in_pg = false
			table.insert(result, line)
		elseif in_pg then
			-- Check if this group is a bind group for a managed proxy → remove
			local gname = line:match('name:%s*"([^"]*)"') or line:match("name:%s*([^,}]+)")
			if gname and managed[trim(gname)] then
				-- Skip: old bind group, will be re-generated
			else
				-- Insert new bind groups right before 🏠 住宅节点
				if not groups_inserted and line:match(escaped_nm_group) then
					for _, bg in ipairs(bind_groups) do table.insert(result, bg) end
					groups_inserted = true
				end
				table.insert(result, line)
			end
		else
			table.insert(result, line)
		end
	end

	return result
end

local function save_rules_to_lines(list, lines)
	-- Build managed proxy name set for targeted deletion
	local managed = {}
	for _, p in ipairs(list) do managed[p.name] = true end

	-- Build SRC-IP-CIDR rules from bindips
	-- Rules reference bind proxy-groups (unprefixed name), not provider proxies directly
	-- (Mihomo validates rules before loading providers, so direct reference fails)
	-- Note: Mihomo only supports SRC-IP-CIDR, not SRC-IP; single IPs get /32
	local rules = {}
	for _, p in ipairs(list) do
		if p.bindips then
			for _, raw_ip in ipairs(p.bindips) do
				local ip = normalize_bindip(raw_ip)
				if not ip:match("/") then ip = ip .. "/32" end
				table.insert(rules, string.format("  - SRC-IP-CIDR,%s,%s", ip, p.name))
			end
		end
	end

	-- Only delete SRC-IP rules that reference managed proxy names
	-- Insert new rules before RULE-SET,proxylite (or end of rules section)
	local result = {}
	local in_rules = false
	local rules_inserted = false
	for _, line in ipairs(lines) do
		if line:match("^rules:") then
			in_rules = true
			table.insert(result, line)
		elseif in_rules and line:match("^%S") and not line:match("^%s") then
			in_rules = false
			table.insert(result, line)
		elseif in_rules then
			-- Check if this is a SRC-IP rule for a managed proxy → skip it
			local target = line:match("SRC%-IP%-CIDR,[^,]+,(.+)") or line:match("SRC%-IP,([^,]+),(.+)")
			if target then
				target = trim(line:match(",([^,]+)$"))  -- last field = proxy name
				-- Match both prefixed and unprefixed names (migration compat)
				local base = target:match("^%[NM%] (.+)") or target
				if managed[base] then
					-- Skip: managed proxy SRC-IP rule (will be re-generated)
				else
					table.insert(result, line)  -- Keep: user's custom SRC-IP rule
				end
			else
				-- Insert new rules before RULE-SET,ai
				if not rules_inserted and line:match("RULE%-SET,ai") then
					for _, r in ipairs(rules) do table.insert(result, r) end
					rules_inserted = true
				end
				table.insert(result, line)
			end
		else
			table.insert(result, line)
		end
	end

	-- Fallback: if proxylite not found, append at end of rules
	if not rules_inserted and #rules > 0 then
		-- Find last rule line and insert before it, or create section
		local last_rule_idx
		for i, line in ipairs(result) do
			if line:match("^rules:") or line:match("^%s+%-") then last_rule_idx = i end
		end
		if last_rule_idx then
			for ri = #rules, 1, -1 do
				table.insert(result, last_rule_idx + 1, rules[ri])
			end
		else
			table.insert(result, "rules:")
			for _, r in ipairs(rules) do table.insert(result, r) end
		end
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
	local ok, werr = atomic_write(storage, data)
	if not ok then return nil, werr end
	if storage ~= runtime then atomic_write(runtime, data) end
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
	-- Parse proxies using generic parser (supports all types)
	local proxies = {}
	local in_block = false
	for _, line in ipairs(lines) do
		if line:match("^proxies:") then
			in_block = true
		elseif in_block and line:match("^%S") then
			break
		elseif in_block and line:match("^%s*-%s*{") then
			local proxy = parse_proxy_line(line)
			if proxy then table.insert(proxies, proxy) end
		end
	end
	return proxies
end

-- Extract nm-nodes block lines from template's proxy-providers section
local function extract_nm_nodes_block(lines)
	local result = {}
	local in_pp = false
	local in_nm = false
	local nm_pat = "^  " .. NM_PROVIDER_NAME:gsub("%-", "%%-") .. ":"
	for _, line in ipairs(lines) do
		if line:match("^proxy%-providers:") then
			in_pp = true
		elseif in_pp and line:match("^%S") then
			break
		elseif in_pp then
			if line:match(nm_pat) then
				in_nm = true
				table.insert(result, line)
			elseif in_nm then
				if line:match("^  %S") then break end
				table.insert(result, line)
			end
		end
	end
	return result
end

-- Ensure proxy-providers: has exactly one nm-nodes entry
-- entry_lines: pre-extracted nm-nodes block from template
local function save_provider_entry_to_lines(lines, entry_lines)

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
			if line:match("^  " .. NM_PROVIDER_NAME:gsub("%-", "%%-") .. ":") then
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

-- URL-decode a percent-encoded string
local function url_decode(s)
	if not s then return "" end
	return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- Parse URL query string into table
local function parse_query(qs)
	local params = {}
	if not qs or qs == "" then return params end
	for kv in qs:gmatch("[^&]+") do
		local k, v = kv:match("^([^=]+)=?(.*)")
		if k then params[url_decode(k)] = url_decode(v or "") end
	end
	return params
end

-- Pure Lua Base64 decoder (Lua 5.1, no external libs)
-- Supports standard base64 and URL-safe variant (-_ instead of +/)
local function base64_decode(input)
	input = input:gsub("-", "+"):gsub("_", "/")
	local pad = #input % 4
	if pad == 2 then input = input .. "=="
	elseif pad == 3 then input = input .. "="
	end
	local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local lut = {}
	for i = 1, #b64 do lut[b64:sub(i, i)] = i - 1 end
	lut["="] = 0
	local out = {}
	for i = 1, #input, 4 do
		local a, b, c, d = lut[input:sub(i, i)] or 0,
		                    lut[input:sub(i+1, i+1)] or 0,
		                    lut[input:sub(i+2, i+2)] or 0,
		                    lut[input:sub(i+3, i+3)] or 0
		local n = a * 262144 + b * 4096 + c * 64 + d
		local b1 = math.floor(n / 65536) % 256
		local b2 = math.floor(n / 256) % 256
		local b3 = n % 256
		out[#out + 1] = string.char(b1)
		if input:sub(i + 2, i + 2) ~= "=" then out[#out + 1] = string.char(b2) end
		if input:sub(i + 3, i + 3) ~= "=" then out[#out + 1] = string.char(b3) end
	end
	return table.concat(out)
end

-- Try to detect and decode base64-encoded text
local function try_base64_decode(text)
	local clean = text:gsub("%s+", "")
	if #clean < 20 then return nil end
	if clean:match("[^A-Za-z0-9%+/%-%_=]") then return nil end
	local ok, decoded = pcall(base64_decode, clean)
	if not ok or not decoded or #decoded == 0 then return nil end
	if decoded:match("[\0\1\2\3\4\5\6\7\8\14\15\16\17\18\19\20\21\22\23\24\25\26\27\28\29\30\31]") then
		return nil
	end
	return decoded
end

local function parse_url_or_hostport(s)
	s = trim(s)
	local scheme, rest = s:match("^(socks5h?|https?)://(.+)$")
	if not scheme then scheme, rest = s:match("^(socks5h?)://(.+)$") end
	if not scheme then scheme, rest = s:match("^(https?)://(.+)$") end

	local user, pass, host, port, fragment
	if scheme then
		if scheme == "socks5h" then scheme = "socks5" end
		if scheme == "https" then scheme = "http" end
		rest, fragment = rest:match("^(.-)#(.*)$")
		if not rest then rest = s:match("://(.+)$"); fragment = nil end
		user, pass, host, port = rest:match("^([^:]+):([^@]+)@([^:]+):(%d+)")
		if not host then host, port = rest:match("^([^:]+):(%d+)") end
	else
		user, pass, host, port = s:match("^([^:]+):([^@]+)@([^:]+):(%d+)")
		if not host then host, port = s:match("^([^:]+):(%d+)$") end
		scheme = "socks5"
	end
	if not host or not port then return nil end
	return {
		type = scheme or "socks5", server = trim(host), port = tonumber(port),
		username = trim(user or ""), password = trim(pass or ""), name = trim(fragment or "")
	}
end

-- ============================================================
-- Subscription Protocol URI Parsers
-- ============================================================

-- Parse ss:// URI (SIP002 + legacy)
local function parse_ss_uri(s)
	local body = s:match("^ss://(.+)$")
	if not body then return nil end
	local fragment
	body, fragment = body:match("^(.-)#(.*)$")
	if not body then body = s:match("^ss://(.+)$"); fragment = nil end
	fragment = fragment and url_decode(trim(fragment)) or ""
	-- SIP002: base64(method:password)@hostname:port
	local userinfo_b64, host, port = body:match("^([A-Za-z0-9%+/%-%_=]+)@([^:/?]+):(%d+)")
	if userinfo_b64 then
		local ok, decoded = pcall(base64_decode, userinfo_b64)
		if ok and decoded then
			local method, password = decoded:match("^([^:]+):(.+)$")
			if method then
				return { type = "ss", name = fragment, server = trim(host), port = tonumber(port),
					cipher = trim(method), password = trim(password) }
			end
		end
	end
	-- Legacy: base64(method:password@hostname:port)
	local clean = body:gsub("@.*", ""):gsub("[?].*", "")
	local ok, decoded = pcall(base64_decode, clean)
	if ok and decoded then
		local method, password, h, p = decoded:match("^([^:]+):(.+)@([^:]+):(%d+)$")
		if method then
			return { type = "ss", name = fragment, server = trim(h), port = tonumber(p),
				cipher = trim(method), password = trim(password) }
		end
	end
	return nil
end

-- Parse vmess:// URI (v2rayN: vmess://base64(JSON))
local function parse_vmess_uri(s)
	local body = s:match("^vmess://(.+)$")
	if not body then return nil end
	body = body:match("^(.-)#") or body
	local ok, decoded = pcall(base64_decode, trim(body))
	if not ok or not decoded then return nil end
	local data = require("luci.jsonc").parse(decoded)
	if not data or not data.add then return nil end
	local net = data.net or "tcp"
	local proxy = {
		type = "vmess", name = data.ps or data.add, server = trim(data.add),
		port = tonumber(data.port) or 443, uuid = data.id or "",
		alterId = tonumber(data.aid) or 0, cipher = "auto", network = net,
		tls = (data.tls == "tls" or data.tls == "true"),
		servername = data.sni or data.host or "",
	}
	if data.sni and data.sni ~= "" then proxy.servername = data.sni end
	if net == "ws" then proxy.ws_path = data.path or "/"; proxy.ws_host = data.host or ""
	elseif net == "grpc" then proxy.grpc_servicename = data.path or "" end
	return proxy
end

-- Parse vless:// URI
local function parse_vless_uri(s)
	local body = s:match("^vless://(.+)$")
	if not body then return nil end
	local fragment
	body, fragment = body:match("^(.-)#(.*)$")
	if not body then body = s:match("^vless://(.+)$"); fragment = nil end
	fragment = fragment and url_decode(trim(fragment)) or ""
	local uuid, host, port, qs = body:match("^([^@]+)@([^:/?]+):(%d+)[?]?(.*)$")
	if not uuid then return nil end
	local params = parse_query(qs)
	local security = params.security or ""
	local net = params.type or "tcp"
	local proxy = {
		type = "vless", name = fragment, server = trim(host), port = tonumber(port),
		uuid = trim(uuid), network = net,
		tls = (security == "tls" or security == "reality"),
		flow = params.flow or "", servername = params.sni or "",
		client_fingerprint = params.fp or "",
	}
	if security == "reality" then
		proxy.reality_public_key = params.pbk or ""
		proxy.reality_short_id = params.sid or ""
	end
	if net == "ws" then proxy.ws_path = params.path or "/"; proxy.ws_host = params.host or ""
	elseif net == "grpc" then proxy.grpc_servicename = params.serviceName or params["service-name"] or "" end
	return proxy
end

-- Parse trojan:// URI
local function parse_trojan_uri(s)
	local body = s:match("^trojan://(.+)$")
	if not body then return nil end
	local fragment
	body, fragment = body:match("^(.-)#(.*)$")
	if not body then body = s:match("^trojan://(.+)$"); fragment = nil end
	fragment = fragment and url_decode(trim(fragment)) or ""
	local password, host, port, qs = body:match("^([^@]+)@([^:/?]+):(%d+)[?]?(.*)$")
	if not password then return nil end
	local params = parse_query(qs)
	local net = params.type or "tcp"
	local proxy = {
		type = "trojan", name = fragment, server = trim(host), port = tonumber(port),
		password = url_decode(trim(password)), sni = params.sni or "", network = net,
	}
	if net == "ws" then proxy.ws_path = params.path or "/"; proxy.ws_host = params.host or ""
	elseif net == "grpc" then proxy.grpc_servicename = params.serviceName or params["service-name"] or "" end
	return proxy
end

-- Parse hysteria2:// or hy2:// URI
local function parse_hysteria2_uri(s)
	local body = s:match("^hysteria2://(.+)$") or s:match("^hy2://(.+)$")
	if not body then return nil end
	local fragment
	body, fragment = body:match("^(.-)#(.*)$")
	if not body then body = s:match("^hysteria2://(.+)$") or s:match("^hy2://(.+)$"); fragment = nil end
	fragment = fragment and url_decode(trim(fragment)) or ""
	local password, host, port, qs = body:match("^([^@]+)@([^:/?]+):(%d+)[?]?(.*)$")
	if not password then return nil end
	local params = parse_query(qs)
	return {
		type = "hysteria2", name = fragment, server = trim(host), port = tonumber(port),
		password = url_decode(trim(password)), sni = params.sni or "",
		obfs = params.obfs or "", obfs_password = params["obfs-password"] or "",
	}
end

-- Dispatch proxy URI to the appropriate parser
local function parse_proxy_uri(s)
	s = trim(s)
	local scheme = s:match("^(%w[%w%-]*)://")
	if not scheme then return parse_url_or_hostport(s) end
	scheme = scheme:lower()
	if scheme == "ss" then return parse_ss_uri(s)
	elseif scheme == "vmess" then return parse_vmess_uri(s)
	elseif scheme == "vless" then return parse_vless_uri(s)
	elseif scheme == "trojan" then return parse_trojan_uri(s)
	elseif scheme == "hysteria2" or scheme == "hy2" then return parse_hysteria2_uri(s)
	elseif scheme == "socks5" or scheme == "socks5h" or scheme == "http" or scheme == "https" then
		return parse_url_or_hostport(s)
	end
	return nil
end

-- ============================================================
-- Format Parsers
-- ============================================================

local function parse_json_import(text)
	local data = require("luci.jsonc").parse(text)
	if not data then return false, nil, "Invalid JSON" end
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
					name = trim(name), type = trim(ptype or "socks5"),
					server = trim(server), port = tonumber(port),
					username = trim(username or ""), password = trim(password or ""),
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
			local content, comment
			if line:match("^%w[%w%-]*://") then
				content = line; comment = nil
			else
				content, comment = line:match("^(.-)%s*#%s*(.+)$")
				content = content or line
			end
			content = trim(content)
			local node = parse_proxy_uri(content)
			if node then
				idx = idx + 1
				if (not node.name or node.name == "") and comment then node.name = comment end
				if not node.name or node.name == "" then node.name = node.server .. ":" .. node.port end
				table.insert(result, node)
			end
		end
	end
	if #result == 0 then return false, nil, "No valid proxies found" end
	return true, result
end

local function detect_and_parse(text, depth)
	depth = depth or 0
	text = trim(text)
	if #text > 65536 then return false, nil, "Input too large (max 64KB)" end
	if text == "" then return false, nil, "Empty input" end

	-- 0. Base64 decode attempt (max recursion depth 2)
	if depth < 2 then
		local decoded = try_base64_decode(text)
		if decoded then return detect_and_parse(decoded, depth + 1) end
	end

	-- 1. JSON?
	if text:match("^%s*[{%[]") then return parse_json_import(text) end
	-- 2. YAML proxies block?
	if text:match("%-%s*{?name:") or text:match("%-%s*name:") then return parse_yaml_import(text) end
	-- 3. Lines (TXT / URL / subscription URIs)
	return parse_lines_import(text)
end

-- ============================================================
-- Validation
-- ============================================================
local function validate_proxy(p)
	if not p.name or trim(p.name) == "" then return "missing name" end
	if not p.server or not p.server:match("^[%w%.%-:%[%]]+$") then return "invalid server" end
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

-- Check if DNS nameserver keys in cur match template exactly
dns_keys_match = function(cur_lines, tpl_lines)
	local function extract_dns_keys(lines)
		local keys = {}
		local in_dns = false
		for _, line in ipairs(lines) do
			if line:match("^dns:") then in_dns = true
			elseif in_dns and line:match("^%S") then break
			elseif in_dns then
				for _, k in ipairs(DNS_KEYS) do
					if line:match("^%s+" .. k:gsub("%-", "%%-") .. ":") then
						keys[k] = true
					end
				end
			end
		end
		return keys
	end
	local cur_keys = extract_dns_keys(cur_lines)
	local tpl_keys = extract_dns_keys(tpl_lines)
	for k in pairs(tpl_keys) do
		if not cur_keys[k] then return false end
	end
	for k in pairs(cur_keys) do
		if not tpl_keys[k] then return false end
	end
	return true
end

-- ============================================================
-- Template Rebuild (implementation, after all helpers)
-- ============================================================
rebuild_config = function(proxy_list)
	local tpl_lines = read_template_lines()
	if not tpl_lines then return read_lines() end  -- fallback: no template
	local cur_lines = read_lines()
	if #cur_lines == 0 then return tpl_lines end   -- first run: use template as-is

	-- 0. Extract nm-nodes block from template BEFORE copy_section overwrites it
	local nm_entry = extract_nm_nodes_block(tpl_lines)

	-- 1. Copy user-owned sections from current config into template
	tpl_lines = copy_section(cur_lines, tpl_lines, "proxy-providers")
	tpl_lines = copy_section(cur_lines, tpl_lines, "proxies")

	-- 2. DNS: if keys match template structure, preserve user DNS values
	if dns_keys_match(cur_lines, tpl_lines) then
		local dns_map = parse_dns_servers(cur_lines)
		tpl_lines = save_dns_to_lines(dns_map, tpl_lines)
	end
	-- else: DNS stays as template defaults

	-- 3. Inject nm-nodes provider entry from template (source of truth)
	tpl_lines = save_provider_entry_to_lines(tpl_lines, nm_entry)

	-- 4. Bind groups + SRC-IP rules
	if proxy_list then
		tpl_lines = inject_bind_groups(tpl_lines, proxy_list)
		tpl_lines = save_rules_to_lines(proxy_list, tpl_lines)
	end

	return tpl_lines
end

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

HANDLERS["check_device"] = function()
	local ok, board, policy = check_device()
	json_out({
		ok = true,
		data = {
			allowed = ok,
			board   = board or trim(fs.readfile("/tmp/sysinfo/model") or ""),
			models  = policy and policy.models or {},
			message = policy and policy.message or ""
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
	-- 2. Clean inline managed proxies from main config (migration)
	lines = save_proxies_to_lines({}, lines)
	write_lines(lines)
	-- 3. Rebuild from template
	local rebuilt = rebuild_config(list)
	if write_lines(rebuilt) then
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
	-- Write airports to current config first, then rebuild
	local lines = read_lines()
	lines = save_providers_to_lines(list, lines)
	write_lines(lines)
	-- Rebuild from template (will copy the updated proxy-providers section)
	local proxy_list = read_provider_proxies()
	local rebuilt = rebuild_config(proxy_list)
	if write_lines(rebuilt) then
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
	-- Whitelist validation: only allow alphanumeric, dot, hyphen, colon; max 253 chars
	if #host > 253 or host:match("[^%w%.%-:]") then
		return json_out({ok = false, err = "Invalid DNS server address"})
	end
	-- Random subdomain to prevent DNS cache hits
	local rand = string.format("nm%d.google.com", os.time() % 100000)
	local nixio = require "nixio"
	local s0, u0 = nixio.gettimeofday()
	local cmd = string.format("nslookup '%s' '%s' >/dev/null 2>&1", rand:gsub("'",""), host:gsub("'",""))
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
	-- Write DNS to current config first, then rebuild
	local lines = read_lines()
	lines = save_dns_to_lines(dns_map, lines)
	write_lines(lines)
	-- Rebuild from template (will check DNS key structure and preserve if valid)
	local proxy_list = read_provider_proxies()
	local rebuilt = rebuild_config(proxy_list)
	if write_lines(rebuilt) then
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
	-- Prepend NM_PREFIX for mihomo API (override.additional-prefix)
	local api_name = NM_PREFIX .. name
	local encoded = api_name:gsub("([^%w%-%.%_%~])", function(c)
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

HANDLERS["get_traffic"] = function()
	local status = get_service_status()
	if not status.running then
		return json_out({ok = false, err = "Service is not running"})
	end
	local data = http_get_json("http://127.0.0.1:" .. status.api_port .. "/proxies")
	if not data or not data.proxies then
		return json_out({ok = false, err = "Failed to get traffic data"})
	end
	local traffic = {}
	for name, info in pairs(data.proxies) do
		-- NM-managed nodes are prefixed with [NM]
		local base = name:match("^%[NM%] (.+)")
		if base then
			traffic[base] = {
				upload = info.up or 0,
				download = info.down or 0
			}
		end
	end
	json_out({ok = true, data = {traffic = traffic}})
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
