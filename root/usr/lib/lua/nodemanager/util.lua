-- nodemanager/util.lua — Pure utility functions (no LuCI deps)
-- SPDX-License-Identifier: Apache-2.0

local M = {}

function M.trim(s)
	return (s or ""):match("^%s*(.-)%s*$")
end

-- Normalize bind IP: .0 → /24, /32 → strip, CIDR → keep
function M.normalize_bindip(ip)
	ip = M.trim(ip)
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

-- Pure Lua Base64 decoder (Lua 5.1, no external libs)
-- Supports standard base64 and URL-safe variant (-_ instead of +/)
function M.base64_decode(input)
	-- URL-safe → standard
	input = input:gsub("-", "+"):gsub("_", "/")
	-- Auto-pad
	local pad = #input % 4
	if pad == 2 then input = input .. "=="
	elseif pad == 3 then input = input .. "="
	end
	-- Build lookup table
	local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local lut = {}
	for i = 1, #b64 do lut[b64:sub(i, i)] = i - 1 end
	lut["="] = 0
	-- Decode
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
-- Returns decoded string on success, nil on failure
function M.try_base64_decode(text)
	-- Strip whitespace
	local clean = text:gsub("%s+", "")
	-- Must be at least 20 chars
	if #clean < 20 then return nil end
	-- Must be all valid base64 characters (standard + URL-safe)
	if clean:match("[^A-Za-z0-9%+/%-%_=]") then return nil end
	-- Try decode
	local ok, decoded = pcall(M.base64_decode, clean)
	if not ok or not decoded or #decoded == 0 then return nil end
	-- Check for readable text (reject binary: no bytes 0x00-0x08, 0x0E-0x1F except \t\n\r)
	if decoded:match("[\0\1\2\3\4\5\6\7\8\14\15\16\17\18\19\20\21\22\23\24\25\26\27\28\29\30\31]") then
		return nil
	end
	return decoded
end

return M
