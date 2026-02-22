-- nodemanager/schema.lua — Proxy type schemas, validation, name management
-- SPDX-License-Identifier: Apache-2.0

local util = require "nodemanager.util"
local trim = util.trim

local M = {}

-- ============================================================
-- Proxy Type Schemas
-- ============================================================
M.SCHEMAS = {
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
			-- Reality settings
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

M.MANAGED_TYPES = {}
for k, _ in pairs(M.SCHEMAS) do M.MANAGED_TYPES[k] = true end

function M.detect_managed_type(line)
	local ptype = line:match("type:%s*(%w+)")
	if ptype then ptype = ptype:lower() end
	if ptype and M.MANAGED_TYPES[ptype] then return ptype end
	-- Detect socks5 via YAML anchor reference << *s5
	if line:match("%*s5") then return "socks5" end
	return nil
end

-- ============================================================
-- YAML Field Extraction (for reading proxies from provider file)
-- ============================================================

-- Extract a YAML field value from an inline {key: val, ...} line
function M.yaml_field(line, key)
	local pat = key:gsub("%-", "%%-")
	return line:match(pat .. ':%s*"([^"]*)"') or line:match(pat .. ":%s*([^,}%s]+)")
end

-- Extract type-specific fields from a proxy YAML line
function M.extract_extra_fields(line, ptype)
	local extra = {}
	local yf = M.yaml_field
	if ptype == "ss" then
		extra.cipher = trim(yf(line, "cipher") or "aes-256-gcm")
	elseif ptype == "vmess" then
		extra.uuid = trim(yf(line, "uuid") or "")
		extra.alterId = tonumber(yf(line, "alterId")) or 0
		extra.cipher = trim(yf(line, "cipher") or "auto")
		extra.network = trim(yf(line, "network") or "tcp")
		local tls_val = yf(line, "tls")
		if tls_val then extra.tls = (trim(tls_val) == "true") end
		extra.servername = trim(yf(line, "servername") or "")
		-- ws-opts
		local ws_match = line:match("ws%-opts:%s*{(.-)}")
		if ws_match then
			extra.ws_path = ws_match:match('path:%s*"([^"]*)"') or ws_match:match("path:%s*([^,}%s]+)")
			local hdr = ws_match:match("headers:%s*{(.-)}")
			if hdr then extra.ws_host = hdr:match('Host:%s*"([^"]*)"') or hdr:match("Host:%s*([^,}%s]+)") end
		end
		-- grpc-opts
		local grpc_match = line:match("grpc%-opts:%s*{(.-)}")
		if grpc_match then
			extra.grpc_servicename = grpc_match:match('grpc%-service%-name:%s*"([^"]*)"') or grpc_match:match("grpc%-service%-name:%s*([^,}%s]+)")
		end
	elseif ptype == "vless" then
		extra.uuid = trim(yf(line, "uuid") or "")
		extra.network = trim(yf(line, "network") or "tcp")
		extra.flow = trim(yf(line, "flow") or "")
		local tls_val = yf(line, "tls")
		if tls_val then extra.tls = (trim(tls_val) == "true") end
		extra.servername = trim(yf(line, "servername") or "")
		extra.client_fingerprint = trim(yf(line, "client%-fingerprint") or "")
		-- reality-opts
		local reality = line:match("reality%-opts:%s*{(.-)}")
		if reality then
			extra.reality_public_key = reality:match('public%-key:%s*"([^"]*)"') or reality:match("public%-key:%s*([^,}%s]+)")
			extra.reality_short_id = reality:match('short%-id:%s*"([^"]*)"') or reality:match("short%-id:%s*([^,}%s]+)")
		end
		-- ws-opts
		local ws_match = line:match("ws%-opts:%s*{(.-)}")
		if ws_match then
			extra.ws_path = ws_match:match('path:%s*"([^"]*)"') or ws_match:match("path:%s*([^,}%s]+)")
			local hdr = ws_match:match("headers:%s*{(.-)}")
			if hdr then extra.ws_host = hdr:match('Host:%s*"([^"]*)"') or hdr:match("Host:%s*([^,}%s]+)") end
		end
		-- grpc-opts
		local grpc_match = line:match("grpc%-opts:%s*{(.-)}")
		if grpc_match then
			extra.grpc_servicename = grpc_match:match('grpc%-service%-name:%s*"([^"]*)"') or grpc_match:match("grpc%-service%-name:%s*([^,}%s]+)")
		end
	elseif ptype == "trojan" then
		extra.sni = trim(yf(line, "sni") or "")
		extra.network = trim(yf(line, "network") or "tcp")
		local scv = yf(line, "skip%-cert%-verify")
		if scv then extra.skip_cert_verify = (trim(scv) == "true") end
		-- ws-opts
		local ws_match = line:match("ws%-opts:%s*{(.-)}")
		if ws_match then
			extra.ws_path = ws_match:match('path:%s*"([^"]*)"') or ws_match:match("path:%s*([^,}%s]+)")
			local hdr = ws_match:match("headers:%s*{(.-)}")
			if hdr then extra.ws_host = hdr:match('Host:%s*"([^"]*)"') or hdr:match("Host:%s*([^,}%s]+)") end
		end
	elseif ptype == "hysteria2" then
		extra.sni = trim(yf(line, "sni") or "")
		extra.obfs = trim(yf(line, "obfs") or "")
		extra.obfs_password = trim(yf(line, "obfs%-password") or "")
		local scv = yf(line, "skip%-cert%-verify")
		if scv then extra.skip_cert_verify = (trim(scv) == "true") end
	end
	-- Remove empty string values
	for k, v in pairs(extra) do
		if v == "" then extra[k] = nil end
	end
	return extra
end

-- Parse a proxy YAML line into a proxy object with all fields
function M.parse_proxy_line(line)
	local ptype = M.detect_managed_type(line)
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
	-- Merge type-specific extra fields
	local extra = M.extract_extra_fields(line, ptype)
	for k, v in pairs(extra) do proxy[k] = v end
	return proxy
end

-- ============================================================
-- Validation
-- ============================================================
function M.validate_proxy(p)
	if not p.name or trim(p.name) == "" then return "missing name" end
	if not p.server or not p.server:match("^[%w%.%-:%[%]]+$") then return "invalid server" end
	local port = tonumber(p.port)
	if not port or port < 1 or port > 65535 then return "invalid port" end
	p.port = port
	p.type = p.type or "socks5"
	if not M.SCHEMAS[p.type] then return "unsupported type: " .. p.type end
	return nil
end

-- Fill empty names + global dedup (avoids collision with vless/vmess etc.)
function M.normalize_names(list, reserved)
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

return M
