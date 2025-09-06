-- luasrc/controller/nodemanager.lua
local nixio = require "nixio"
local http  = require "luci.http"
local tpl   = require "luci.template"
local util  = require "luci.nodemanager.util"
local i18n  = require "luci.i18n"

local APP   = "nodemanager"

function index()
	if not nixio.fs.access("/etc/nikki/profiles/config.yaml") then
		entry({"admin","services",APP}, call("not_found"), _("Node Manager"), 10).leaf = true
		return
	end
	entry({"admin","services",APP}, firstchild(), _("Node Manager"), 10).dependent = false
	entry({"admin","services",APP,"proxies"},    call("action_proxies"),   _("Proxies"),    11).leaf = true
	entry({"admin","services",APP,"providers"},  call("action_providers"), _("Providers"),  12).leaf = true
	entry({"admin","services",APP,"dns"},        call("action_dns"),       _("DNS"),        13).leaf = true
	entry({"admin","services",APP,"logs"},       call("action_logs"),      _("Logs"),       14).leaf = true
end

function not_found()
	tpl.render("nodemanager/proxies", {
		errmsg = i18n.translate("Config file not found: ") .. "/etc/nikki/profiles/config.yaml",
		proxies = {},
		bindmap = {},
	})
end

local function ret(code, msg, data)
	http.prepare_content("application/json")
	http.write_json({ code = code, msg = msg, data = data })
end

function action_proxies()
	if http.getenv("REQUEST_METHOD") == "POST" then
		local form = http.formvalue()
		local ok, proxies, err = util.parse_proxy_form(form)
		if not ok then return ret(1, err) end
		local ok2, err2 = util.save_proxies_and_rules(proxies)
		if not ok2 then return ret(1, err2) end
		return ret(0, "ok")
	end

	local data = util.load_all()
	tpl.render("nodemanager/proxies", {
		errmsg   = nil,
		proxies  = data.proxies or {},
		bindmap  = data.bindmap or {},
	})
end

function action_providers()
	if http.getenv("REQUEST_METHOD") == "POST" then
		local form = http.formvalue()
		local ok, providers, err = util.parse_provider_form(form)
		if not ok then return ret(1, err) end
		local ok2, err2 = util.save_providers(providers)
		if not ok2 then return ret(1, err2) end
		return ret(0, "ok")
	end
	local data = util.load_all()
	tpl.render("nodemanager/providers", {
		providers = data.providers or {}
	})
end

function action_dns()
	if http.getenv("REQUEST_METHOD") == "POST" then
		local form = http.formvalue()
		local ok, servers, err = util.parse_dns_form(form)
		if not ok then return ret(1, err) end
		local ok2, err2 = util.save_dns_servers(servers)
		if not ok2 then return ret(1, err2) end
		return ret(0, "ok")
	end
	local data = util.load_all()
	tpl.render("nodemanager/dns", {
		servers = data.dns_servers or {}
	})
end

function action_logs()
	local path = "/etc/nikki/nodemanager.log"
	local content
	if nixio.fs.access(path) then
		content = luci.sys.exec("tail -n 500 "..path.." 2>/dev/null")
	else
		content = luci.sys.exec('logread -e nikki -e clash -e node 2>/dev/null | tail -n 500')
	end
	tpl.render("nodemanager/logs", { log = content })
end
