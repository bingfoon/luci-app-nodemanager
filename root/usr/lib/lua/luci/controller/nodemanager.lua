-- luci-app-nodemanager v2 — Unified API Backend
-- SPDX-License-Identifier: Apache-2.0

module("luci.controller.nodemanager", package.seeall)

local http = require "luci.http"
local sys  = require "luci.sys"
local fs   = require "nixio.fs"

-- Load modules
local const  = require "nodemanager.const"
local util   = require "nodemanager.util"
local fileio = require "nodemanager.fileio"
local schema = require "nodemanager.schema"
local yaml   = require "nodemanager.yaml"
local import = require "nodemanager.import"
local mihomo = require "nodemanager.mihomo"

-- Shorthand aliases
local trim               = util.trim
local SCHEMAS            = schema.SCHEMAS
local NM_PREFIX          = const.NM_PREFIX
local DNS_KEYS           = const.DNS_KEYS

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

function api()
	local action = http.formvalue("action") or ""
	-- Device policy check (allow check_device action to pass through)
	if action ~= "check_device" then
		local dev_ok = fileio.check_device()
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
-- HTTP Helpers
-- ============================================================
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
-- Template Rebuild
-- ============================================================
local function rebuild_config(proxy_list)
	return yaml.rebuild_config(proxy_list, fileio.read_lines, fileio.read_template_lines)
end

-- ============================================================
-- API Handlers
-- ============================================================
HANDLERS["load"] = function()
	local lines = fileio.read_lines()
	-- Read proxies: prefer provider file, fallback to main config (migration)
	local proxies = fileio.read_provider_proxies()
	if #proxies == 0 then
		proxies = yaml.parse_proxies(lines)
	end
	local bindmap = yaml.parse_bindmap(lines)
	for _, p in ipairs(proxies) do
		p.bindips = bindmap[p.name] or {}
	end
	json_out({
		ok = true,
		data = {
			proxies   = proxies,
			providers = yaml.parse_providers(lines),
			dns       = yaml.parse_dns_servers(lines),
			status    = mihomo.get_service_status(),
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
	local ok, board, policy = fileio.check_device()
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

HANDLERS["save_proxies"] = function()
	local input = json_in()
	local list = input.proxies
	if type(list) ~= "table" then
		return json_out({ok = false, err = "Invalid data"})
	end
	-- Auto-fill empty names + dedup against existing config
	local lines = fileio.read_lines()
	local reserved = yaml.parse_all_proxy_names(lines)
	-- Also remove provider proxy names from reserved
	local old_provider = fileio.read_provider_proxies()
	for _, p in ipairs(old_provider) do reserved[p.name] = nil end
	-- Also remove inline managed from reserved (migration)
	local managed = yaml.parse_proxies(lines)
	for _, p in ipairs(managed) do reserved[p.name] = nil end
	schema.normalize_names(list, reserved)
	-- Validate
	for i, p in ipairs(list) do
		local err = schema.validate_proxy(p)
		if err then
			return json_out({ok = false, err = string.format("Row %d: %s", i, err)})
		end
	end
	-- 0. Read client-fingerprint from UCI for per-proxy injection
	local fingerprint = fileio.get_fingerprint(lines)
	-- 1. Write provider file (separate file, with fingerprint)
	fileio.write_provider_file(list, fingerprint)
	-- 2. Clean inline managed proxies from main config (migration)
	lines = yaml.save_proxies_to_lines({}, lines)
	fileio.write_lines(lines)
	-- 3. Rebuild from template
	local rebuilt = rebuild_config(list)
	if fileio.write_lines(rebuilt) then
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
	local lines = fileio.read_lines()
	lines = yaml.save_providers_to_lines(list, lines)
	fileio.write_lines(lines)
	-- Rebuild from template (will copy the updated proxy-providers section)
	local proxy_list = fileio.read_provider_proxies()
	local rebuilt = rebuild_config(proxy_list)
	if fileio.write_lines(rebuilt) then
		json_out({ok = true})
	else
		json_out({ok = false, err = "Write failed"})
	end
end

HANDLERS["debug_dns"] = function()
	local lines = fileio.read_lines()
	local dns_result = yaml.parse_dns_servers(lines)
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
	local lines = fileio.read_lines()
	lines = yaml.save_dns_to_lines(dns_map, lines)
	fileio.write_lines(lines)
	-- Rebuild from template (will check DNS key structure and preserve if valid)
	local proxy_list = fileio.read_provider_proxies()
	local rebuilt = rebuild_config(proxy_list)
	if fileio.write_lines(rebuilt) then
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
	local ok, result, err = import.detect_and_parse(text)
	if not ok then
		return json_out({ok = false, err = err or "Parse failed"})
	end
	-- Limit to 500 entries
	if #result > 500 then
		return json_out({ok = false, err = "Too many entries (max 500)"})
	end
	-- Auto-fill empty names + dedup against ALL existing names in config
	local reserved = yaml.parse_all_proxy_names(fileio.read_lines())
	schema.normalize_names(result, reserved)
	-- Validate each result
	for i, p in ipairs(result) do
		local verr = schema.validate_proxy(p)
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
	local status = mihomo.get_service_status()
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
	local data, err = mihomo.http_get_json(url)
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
	local status = mihomo.get_service_status()
	if not status.running then
		return json_out({ok = false, err = "Service is not running"})
	end
	local data = mihomo.http_get_json("http://127.0.0.1:" .. status.api_port .. "/proxies")
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
	json_out({ok = true, data = {status = mihomo.get_service_status()}})
end
