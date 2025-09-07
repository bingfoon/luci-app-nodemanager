module("luci.controller.nodemanager", package.seeall)

function index()
	local fs = require "nixio.fs"
	if not fs.access("/usr/lib/lua/luci/nodemanager/util.lua") then return end
	entry({"admin","services","nodemanager"}, firstchild(), _("Node Manager"), 70).dependent = false
	entry({"admin","services","nodemanager","proxies"},   call("action_proxies"),   _("Proxies"),   10).leaf = true
	entry({"admin","services","nodemanager","providers"}, call("action_providers"), _("Providers"), 20).leaf = true
	entry({"admin","services","nodemanager","dns"},       call("action_dns"),       _("DNS"),       30).leaf = true
	entry({"admin","services","nodemanager","settings"},  call("action_settings"),  _("Settings"),  40).leaf = true
end

local function json(resp)
	local http = require "luci.http"
	http.prepare_content("application/json")
	http.write_json(resp)
end

local function get_token()
	local dsp = require "luci.dispatcher"
	return (dsp.context and dsp.context.requesttoken)
	    or (dsp.ctx and dsp.ctx.requesttoken)
	    or (dsp._ctx and dsp._ctx.requesttoken)
	    or nil
end

function action_proxies()
	local http = require "luci.http"
	local util = require "luci.nodemanager.util"

	if http.getenv("REQUEST_METHOD") == "POST" then
		local ok, list, err = util.parse_proxy_form(http.formvalue())
		if not ok then return json({code=1, msg=err}) end
		local ok2, err2 = util.save_proxies_and_rules(list or {})
		if not ok2 then return json({code=1, msg=err2 or "save failed"}) end
		return json({code=0})
	end

	local data = util.load_all() or {}
	local proxies = data.proxies or {}
	local bindsrc = data.bindmap or {}

	local bindmap = {}
	for _,p in ipairs(proxies) do
		local v = bindsrc[p.name]
		if type(v) == "table" then
			bindmap[p.name] = v
		elseif type(v) == "string" then
			bindmap[p.name] = { v }
		else
			bindmap[p.name] = {}
		end
	end

	luci.template.render("nodemanager/proxies", {
		proxies = proxies,
		bindmap = bindmap,
		token   = get_token()
	})
end

function action_providers()
	local http = require "luci.http"
	local util = require "luci.nodemanager.util"

	if http.getenv("REQUEST_METHOD") == "POST" then
		local ok, list, err = util.parse_provider_form(http.formvalue())
		if not ok then return json({code=1, msg=err}) end
		local ok2, err2 = util.save_providers(list or {})
		if not ok2 then return json({code=1, msg=err2 or "save failed"}) end
		return json({code=0})
	end

	local data = util.load_all() or {}
	luci.template.render("nodemanager/providers", {
		providers = data.providers or {},
		token     = get_token()
	})
end

function action_dns()
	local http = require "luci.http"
	local util = require "luci.nodemanager.util"

	if http.getenv("REQUEST_METHOD") == "POST" then
		local ok, list, err = util.parse_dns_form(http.formvalue())
		if not ok then return json({code=1, msg=err}) end
		local ok2, err2 = util.save_dns_servers(list or {})
		if not ok2 then return json({code=1, msg=err2 or "save failed"}) end
		return json({code=0})
	end

	local data = util.load_all() or {}
	luci.template.render("nodemanager/dns", {
		servers = data.dns_servers or {},
		token   = get_token()
	})
end

function action_settings()
	local http = require "luci.http"
	local uci  = require("luci.model.uci").cursor()
	local util = require "luci.nodemanager.util"

	if http.getenv("REQUEST_METHOD") == "POST" then
		local path = http.formvalue("path") or ""
		local tpl  = http.formvalue("template") or ""
		path = (path:gsub("%s+$",""))
		tpl  = (tpl:gsub("%s+$",""))

		if path == "" then return json({code=1, msg="Config path cannot be empty"}) end
		uci:section("nodemanager", "config", "config", { path = path, template = tpl })
		uci:commit("nodemanager")

		if http.formvalue("create") == "1" then
			local ok, p = util.ensure_file(path, tpl ~= "" and tpl or nil)
			if not ok then return json({code=1, msg="Failed to create "..tostring(p)}) end
		end
		return json({code=0})
	end

	local path = uci:get("nodemanager","config","path") or ""
	local tpl  = uci:get("nodemanager","config","template") or ""
	luci.template.render("nodemanager/settings", {
		path  = path,
		tpl   = tpl,
		token = get_token()
	})
end
