-- nodemanager/yaml.lua — YAML line-level parsers and writers
-- SPDX-License-Identifier: Apache-2.0

local util   = require "nodemanager.util"
local schema = require "nodemanager.schema"
local const  = require "nodemanager.const"

local trim               = util.trim
local detect_managed_type = schema.detect_managed_type
local NM_PROVIDER_NAME   = const.NM_PROVIDER_NAME
local NM_GROUP_NAME      = const.NM_GROUP_NAME
local DNS_KEYS           = const.DNS_KEYS

local M = {}

-- ============================================================
-- Section Utilities
-- ============================================================

-- Find a top-level YAML section (start line, end line)
-- section_key example: "proxy-providers" matches "proxy-providers:"
function M.find_section(lines, section_key)
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
function M.copy_section(src_lines, dst_lines, section_key)
	local ss, se = M.find_section(src_lines, section_key)
	local ds, de = M.find_section(dst_lines, section_key)
	if not ss or not ds then return dst_lines end
	local result = {}
	for i = 1, ds - 1 do table.insert(result, dst_lines[i]) end
	for i = ss, se do table.insert(result, src_lines[i]) end
	for i = de + 1, #dst_lines do table.insert(result, dst_lines[i]) end
	return result
end

-- ============================================================
-- YAML Parsers
-- ============================================================

function M.parse_proxies(lines)
	local proxies = {}
	local in_block = false
	for _, line in ipairs(lines) do
		if line:match("^proxies:") then
			in_block = true
		elseif in_block and line:match("^%S") then
			break  -- left proxies block
		elseif in_block and line:match("^%s*-%s*{") then
			local proxy = schema.parse_proxy_line(line)
			if proxy then table.insert(proxies, proxy) end
		end
	end
	return proxies
end

-- Extract ALL proxy names from config (including unsupported types)
function M.parse_all_proxy_names(lines)
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

function M.parse_bindmap(lines)
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

function M.parse_providers(lines)
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

function M.parse_dns_servers(lines)
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
-- YAML Writers
-- ============================================================

function M.save_proxies_to_lines(list, lines)
	local SCHEMAS = schema.SCHEMAS
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
		local s = SCHEMAS[p.type or "socks5"] or SCHEMAS.socks5
		table.insert(new_proxy_lines, s.output(p))
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
function M.inject_bind_groups(lines, list)
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

function M.save_rules_to_lines(list, lines)
	local normalize_bindip = util.normalize_bindip
	-- Build managed proxy name set for targeted deletion
	local managed = {}
	for _, p in ipairs(list) do managed[p.name] = true end

	-- Build SRC-IP-CIDR rules from bindips
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

	-- Fallback: if ai rule-set not found, append at end of rules
	if not rules_inserted and #rules > 0 then
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

-- Extract nm-nodes block lines from template's proxy-providers section
function M.extract_nm_nodes_block(lines)
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
function M.save_provider_entry_to_lines(lines, entry_lines)

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
function M.save_proxy_group_to_lines(lines)
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

function M.save_providers_to_lines(list, lines)
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

function M.save_dns_to_lines(dns_map, lines)
	local result = {}
	local in_dns = false
	local cur_key = nil
	local skip_items = false
	local written_keys = {}

	for _, line in ipairs(lines) do
		if line:match("^dns:") then
			in_dns = true
			table.insert(result, line)
		elseif in_dns and line:match("^%S") then
			-- Leaving dns block: insert any keys not yet written
			for _, k in ipairs(DNS_KEYS) do
				if not written_keys[k] and dns_map[k] and #dns_map[k] > 0 then
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

-- Check if DNS nameserver keys in cur match template exactly
function M.dns_keys_match(cur_lines, tpl_lines)
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
-- Template Rebuild
-- ============================================================
function M.rebuild_config(proxy_list, read_lines_fn, read_template_lines_fn)
	local tpl_lines = read_template_lines_fn()
	if not tpl_lines then return read_lines_fn() end  -- fallback: no template
	local cur_lines = read_lines_fn()
	if #cur_lines == 0 then return tpl_lines end   -- first run: use template as-is

	-- 0. Extract nm-nodes block from template BEFORE copy_section overwrites it
	local nm_entry = M.extract_nm_nodes_block(tpl_lines)

	-- 1. Copy user-owned sections from current config into template
	tpl_lines = M.copy_section(cur_lines, tpl_lines, "proxy-providers")
	tpl_lines = M.copy_section(cur_lines, tpl_lines, "proxies")

	-- 2. DNS: if keys match template structure, preserve user DNS values
	if M.dns_keys_match(cur_lines, tpl_lines) then
		local dns_map = M.parse_dns_servers(cur_lines)
		tpl_lines = M.save_dns_to_lines(dns_map, tpl_lines)
	end
	-- else: DNS stays as template defaults

	-- 3. Inject nm-nodes provider entry from template (source of truth)
	tpl_lines = M.save_provider_entry_to_lines(tpl_lines, nm_entry)

	-- 4. Bind groups + SRC-IP rules
	if proxy_list then
		tpl_lines = M.inject_bind_groups(tpl_lines, proxy_list)
		tpl_lines = M.save_rules_to_lines(proxy_list, tpl_lines)
	end

	return tpl_lines
end

return M
