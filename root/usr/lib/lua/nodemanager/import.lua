-- nodemanager/import.lua — Multi-format import pipeline
-- SPDX-License-Identifier: Apache-2.0

local util = require "nodemanager.util"
local trim = util.trim
local base64_decode = util.base64_decode

local M = {}

-- ============================================================
-- URI Helpers
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
		if k then
			params[url_decode(k)] = url_decode(v or "")
		end
	end
	return params
end

-- ============================================================
-- Protocol URI Parsers
-- ============================================================

function M.parse_url_or_hostport(s)
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

-- ============================================================
-- Subscription Protocol URI Parsers
-- ============================================================

-- Parse ss:// URI (SIP002 + legacy)
-- SIP002: ss://base64(method:password)@hostname:port#tag
-- Legacy: ss://base64(method:password@hostname:port)#tag
function M.parse_ss_uri(s)
	local body = s:match("^ss://(.+)$")
	if not body then return nil end
	-- Extract fragment as name
	local fragment
	body, fragment = body:match("^(.-)#(.*)$")
	if not body then body = s:match("^ss://(.+)$"); fragment = nil end
	fragment = fragment and url_decode(trim(fragment)) or ""

	-- SIP002 format: base64(method:password)@hostname:port
	local userinfo_b64, host, port = body:match("^([A-Za-z0-9%+/%-%_=]+)@([^:/?]+):(%d+)")
	if userinfo_b64 then
		local ok, decoded = pcall(base64_decode, userinfo_b64)
		if ok and decoded then
			local method, password = decoded:match("^([^:]+):(.+)$")
			if method then
				return {
					type = "ss", name = fragment,
					server = trim(host), port = tonumber(port),
					cipher = trim(method), password = trim(password),
				}
			end
		end
	end

	-- Legacy format: ss://base64(method:password@hostname:port)
	local clean = body:gsub("@.*", ""):gsub("[?].*", "")
	local ok, decoded = pcall(base64_decode, clean)
	if ok and decoded then
		local method, password, h, p = decoded:match("^([^:]+):(.+)@([^:]+):(%d+)$")
		if method then
			return {
				type = "ss", name = fragment,
				server = trim(h), port = tonumber(p),
				cipher = trim(method), password = trim(password),
			}
		end
	end
	return nil
end

-- Parse vmess:// URI (v2rayN format: vmess://base64(JSON))
function M.parse_vmess_uri(s)
	local body = s:match("^vmess://(.+)$")
	if not body then return nil end
	-- Strip fragment if any
	body = body:match("^(.-)#") or body
	local ok, decoded = pcall(base64_decode, trim(body))
	if not ok or not decoded then return nil end
	local data = require("luci.jsonc").parse(decoded)
	if not data or not data.add then return nil end

	local net = data.net or "tcp"
	local proxy = {
		type = "vmess",
		name = data.ps or data.add,
		server = trim(data.add),
		port = tonumber(data.port) or 443,
		uuid = data.id or "",
		alterId = tonumber(data.aid) or 0,
		cipher = "auto",
		network = net,
		tls = (data.tls == "tls" or data.tls == "true"),
		servername = data.sni or data.host or "",
	}
	if data.sni and data.sni ~= "" then proxy.servername = data.sni end
	if net == "ws" then
		proxy.ws_path = data.path or "/"
		proxy.ws_host = data.host or ""
	elseif net == "grpc" then
		proxy.grpc_servicename = data.path or ""
	end
	return proxy
end

-- Parse vless:// URI
-- vless://uuid@server:port?type=tcp&security=tls&sni=xxx&fp=chrome&flow=xtls-rprx-vision#name
function M.parse_vless_uri(s)
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
		type = "vless",
		name = fragment,
		server = trim(host),
		port = tonumber(port),
		uuid = trim(uuid),
		network = net,
		tls = (security == "tls" or security == "reality"),
		flow = params.flow or "",
		servername = params.sni or "",
		client_fingerprint = params.fp or "",
	}
	if security == "reality" then
		proxy.reality_public_key = params.pbk or ""
		proxy.reality_short_id = params.sid or ""
	end
	if net == "ws" then
		proxy.ws_path = params.path or "/"
		proxy.ws_host = params.host or ""
	elseif net == "grpc" then
		proxy.grpc_servicename = params.serviceName or params["service-name"] or ""
	end
	return proxy
end

-- Parse trojan:// URI
-- trojan://password@server:port?sni=xxx&type=tcp#name
function M.parse_trojan_uri(s)
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
		type = "trojan",
		name = fragment,
		server = trim(host),
		port = tonumber(port),
		password = url_decode(trim(password)),
		sni = params.sni or "",
		network = net,
	}
	if net == "ws" then
		proxy.ws_path = params.path or "/"
		proxy.ws_host = params.host or ""
	elseif net == "grpc" then
		proxy.grpc_servicename = params.serviceName or params["service-name"] or ""
	end
	return proxy
end

-- Parse hysteria2:// or hy2:// URI
-- hysteria2://password@server:port?sni=xxx&obfs=salamander&obfs-password=xxx#name
function M.parse_hysteria2_uri(s)
	local body = s:match("^hysteria2://(.+)$") or s:match("^hy2://(.+)$")
	if not body then return nil end
	local fragment
	body, fragment = body:match("^(.-)#(.*)$")
	if not body then
		body = s:match("^hysteria2://(.+)$") or s:match("^hy2://(.+)$")
		fragment = nil
	end
	fragment = fragment and url_decode(trim(fragment)) or ""

	local password, host, port, qs = body:match("^([^@]+)@([^:/?]+):(%d+)[?]?(.*)$")
	if not password then return nil end

	local params = parse_query(qs)
	return {
		type = "hysteria2",
		name = fragment,
		server = trim(host),
		port = tonumber(port),
		password = url_decode(trim(password)),
		sni = params.sni or "",
		obfs = params.obfs or "",
		obfs_password = params["obfs-password"] or "",
	}
end

-- Dispatch proxy URI to the appropriate parser
function M.parse_proxy_uri(s)
	s = trim(s)
	local scheme = s:match("^(%w[%w%-]*)://")
	if not scheme then return M.parse_url_or_hostport(s) end
	scheme = scheme:lower()
	if scheme == "ss" then return M.parse_ss_uri(s)
	elseif scheme == "vmess" then return M.parse_vmess_uri(s)
	elseif scheme == "vless" then return M.parse_vless_uri(s)
	elseif scheme == "trojan" then return M.parse_trojan_uri(s)
	elseif scheme == "hysteria2" or scheme == "hy2" then return M.parse_hysteria2_uri(s)
	elseif scheme == "socks5" or scheme == "socks5h" or scheme == "http" or scheme == "https" then
		return M.parse_url_or_hostport(s)
	end
	return nil
end

-- ============================================================
-- Format Parsers
-- ============================================================

function M.parse_json_import(text)
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

function M.parse_yaml_import(text)
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

function M.parse_lines_import(text)
	local result = {}
	local idx = 0
	for line in text:gmatch("[^\n]+") do
		line = trim(line)
		if line ~= "" and not line:match("^#") then
			-- For proxy URIs, the # is part of the fragment (name), don't split
			local content, comment
			if line:match("^%w[%w%-]*://") then
				content = line
				comment = nil
			else
				-- Extract trailing comment as name
				content, comment = line:match("^(.-)%s*#%s*(.+)$")
				content = content or line
			end
			content = trim(content)

			local node = M.parse_proxy_uri(content)
			if node then
				idx = idx + 1
				if (not node.name or node.name == "") and comment then
					node.name = comment
				end
				if not node.name or node.name == "" then
					node.name = node.server .. ":" .. node.port
				end
				table.insert(result, node)
			end
		end
	end
	if #result == 0 then return false, nil, "No valid proxies found" end
	return true, result
end

function M.detect_and_parse(text, depth)
	depth = depth or 0
	text = trim(text)
	if #text > 65536 then
		return false, nil, "Input too large (max 64KB)"
	end
	if text == "" then
		return false, nil, "Empty input"
	end

	-- 0. Base64 decode attempt (max recursion depth 2)
	if depth < 2 then
		local decoded = util.try_base64_decode(text)
		if decoded then
			return M.detect_and_parse(decoded, depth + 1)
		end
	end

	-- 1. JSON?
	if text:match("^%s*[{%[]") then
		return M.parse_json_import(text)
	end

	-- 2. YAML proxies block?
	if text:match("%-%s*{?name:") or text:match("%-%s*name:") then
		return M.parse_yaml_import(text)
	end

	-- 3. Lines (TXT / URL)
	return M.parse_lines_import(text)
end

return M
