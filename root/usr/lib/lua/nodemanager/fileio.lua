-- nodemanager/fileio.lua — File I/O, path management, provider file ops
-- SPDX-License-Identifier: Apache-2.0

local fs     = require "nixio.fs"
local sys    = require "luci.sys"
local uci    = require "luci.model.uci"
local util   = require "nodemanager.util"
local schema = require "nodemanager.schema"
local const  = require "nodemanager.const"

local trim               = util.trim
local detect_managed_type = schema.detect_managed_type
local SCHEMAS            = schema.SCHEMAS
local NM_PROVIDER_FILE   = const.NM_PROVIDER_FILE
local SAFE_PREFIXES      = const.SAFE_PREFIXES

local M = {}

-- ============================================================
-- UCI cursor helper
-- ============================================================
local function uci_cursor()
	return uci.cursor()
end

-- ============================================================
-- Path Management (5-level discovery)
-- ============================================================
local _cached_conf_path = nil

function M.conf_path()
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

-- Persistent storage path (source of truth, survives reboot)
function M.nm_storage_path()
	local dir = M.conf_path():match("^(.+)/[^/]+$") or "/etc/nikki/profiles"
	return dir .. "/" .. NM_PROVIDER_FILE
end

-- Detect Mihomo home directory from running process -d flag
function M.mihomo_home()
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
function M.nm_runtime_path()
	return M.mihomo_home() .. "/" .. NM_PROVIDER_FILE
end

function M.is_safe_path(p)
	if not p then return false end
	for _, pfx in ipairs(SAFE_PREFIXES) do
		if p:sub(1, #pfx) == pfx then return true end
	end
	return false
end

-- ============================================================
-- File I/O (with .bak backup)
-- ============================================================

-- Atomic write: write to .tmp, backup original to .bak, rename into place.
-- Falls back to fs.copy if os.rename fails (cross-device).
-- On any write/flush error the .tmp is cleaned up and original is untouched.
function M.atomic_write(path, content)
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

function M.read_lines()
	local path = M.conf_path()
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

function M.write_lines(lines)
	local path = M.conf_path()
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
	return M.atomic_write(path, table.concat(filtered, "\n"))
end

-- ============================================================
-- Template Lines
-- ============================================================
function M.read_template_lines()
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

-- ============================================================
-- Provider File I/O
-- ============================================================

-- Write managed proxies to separate provider file (no YAML anchors)
function M.write_provider_file(list, fingerprint)
	local content = {}
	if #list == 0 then
		table.insert(content, "proxies: []")
	else
		table.insert(content, "proxies:")
		for _, p in ipairs(list) do
			local s = SCHEMAS[p.type or "socks5"] or SCHEMAS.socks5
			table.insert(content, s.output(p, fingerprint))
		end
	end
	local data = table.concat(content, "\n") .. "\n"
	-- Dual write: persistent + runtime
	local storage = M.nm_storage_path()
	local runtime = M.nm_runtime_path()
	local sdir = storage:match("^(.+)/[^/]+$") or "/"
	local rdir = runtime:match("^(.+)/[^/]+$") or "/"
	sys.call(string.format("mkdir -p %q >/dev/null 2>&1", sdir))
	sys.call(string.format("mkdir -p %q >/dev/null 2>&1", rdir))
	local ok, werr = M.atomic_write(storage, data)
	if not ok then return nil, werr end
	if storage ~= runtime then M.atomic_write(runtime, data) end
	return true
end

-- Read proxies from provider file (persistent storage is source of truth)
function M.read_provider_proxies()
	-- Read from persistent storage first
	local content = fs.readfile(M.nm_storage_path())
	-- Fallback: try runtime path
	if not content or content == "" or content:match("^proxies:%s*%[%]") then
		content = fs.readfile(M.nm_runtime_path())
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
			local proxy = schema.parse_proxy_line(line)
			if proxy then table.insert(proxies, proxy) end
		end
	end
	return proxies
end

-- ============================================================
-- Device Policy
-- ============================================================
function M.check_device()
	local raw = fs.readfile(const.DEVICE_POLICY_PATH)
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

-- ============================================================
-- Fingerprint Helper
-- ============================================================

-- Get client-fingerprint: migrate from global config → UCI, fallback to UCI default
function M.get_fingerprint(lines)
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

return M
