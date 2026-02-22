-- nodemanager/mihomo.lua — Mihomo API bridge (service status, HTTP calls)
-- SPDX-License-Identifier: Apache-2.0

local sys = require "luci.sys"
local fs  = require "nixio.fs"

local M = {}

function M.http_get_json(url)
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

function M.get_service_status()
	local running = sys.call("pgrep -f mihomo >/dev/null 2>&1") == 0
	local version = ""
	local api_port = 9090
	if running then
		local data = M.http_get_json("http://127.0.0.1:" .. api_port .. "/version")
		if data and data.version then version = data.version end
	end
	return {running = running, version = version, api_port = api_port}
end

return M
