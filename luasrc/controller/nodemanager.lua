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
		local okc, ok2, err2 = pcall(util.save_proxies_and_rules, list or {})
		if not okc then return json({code=1, msg="runtime: "..tostring(ok2)}) end
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
		local okc, ok2, err2 = pcall(util.save_providers, list or {})
		if not okc then return json({code=1, msg="runtime: "..tostring(ok2)}) end
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
		local okc, ok2, err2 = pcall(util.save_dns_servers, list or {})
		if not okc then return json({code=1, msg="runtime: "..tostring(ok2)}) end
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
	local util = require "luci.nodemanager.util"

	if http.getenv("REQUEST_METHOD") == "POST" then
		local path = (http.formvalue("path") or ""):gsub("%s+$","")
		local tpl  = (http.formvalue("template") or ""):gsub("%s+$","")
		if path == "" then return json({code=1, msg="Config path cannot be empty"}) end
		local okc, err = pcall(util.set_settings, path, tpl)
		if not okc then return json({code=1, msg="runtime: "..tostring(err)}) end
		if http.formvalue("create") == "1" then
			local ok2, p = util.ensure_file(path, (tpl ~= "" and tpl or nil))
			if not ok2 then return json({code=1, msg="Failed to create "..tostring(p)}) end
		end
		return json({code=0})
	end

	local s = util.get_settings()
	luci.template.render("nodemanager/settings", {
		path  = s.path,
		tpl   = s.template,
		token = get_token()
	})
end

