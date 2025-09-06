module("luci.controller.nodemanager", package.seeall)

local nixio = require "nixio"
local http  = require "luci.http"
local tpl   = require "luci.template"

function index()
  -- Services 分组
  local s = entry({"admin","services","nodemanager"}, firstchild(), _("Node Manager"), 59)
  s.dependent = false

  -- 子页面
  entry({"admin","services","nodemanager","settings"}, call("action_settings"), _("Settings"), 0).leaf = true
  entry({"admin","services","nodemanager","proxies"},   call("action_proxies"),   _("Proxies"),   1).leaf = true
  entry({"admin","services","nodemanager","providers"}, call("action_providers"), _("Providers"), 2).leaf = true
  entry({"admin","services","nodemanager","dns"},       call("action_dns"),       _("DNS"),       3).leaf = true
  --entry({"admin","services","nodemanager","logs"},      call("action_logs"),      _("Logs"),      4).leaf = true
end

local function ret(code, msg, data)
  http.prepare_content("application/json")
  http.write_json({ code = code, msg = msg, data = data })
end

function action_proxies()
  local util = require "luci.nodemanager.util"
  if http.getenv("REQUEST_METHOD") == "POST" then
    local form = http.formvalue()
    local ok, proxies, err = util.parse_proxy_form(form)
    if not ok then return ret(1, err) end
    local ok2, err2 = util.save_proxies_and_rules(proxies)
    if not ok2 then return ret(1, err2) end
    return ret(0, "ok")
  end
  local data = util.load_all()
  tpl.render("nodemanager/proxies", { proxies=data.proxies or {}, bindmap=data.bindmap or {} })
end

function action_providers()
  local util = require "luci.nodemanager.util"
  if http.getenv("REQUEST_METHOD") == "POST" then
    local form = http.formvalue()
    local ok, providers, err = util.parse_provider_form(form)
    if not ok then return ret(1, err) end
    local ok2, err2 = util.save_providers(providers)
    if not ok2 then return ret(1, err2) end
    return ret(0, "ok")
  end
  local data = util.load_all()
  tpl.render("nodemanager/providers", { providers = data.providers or {} })
end

function action_dns()
  local util = require "luci.nodemanager.util"
  if http.getenv("REQUEST_METHOD") == "POST" then
    local form = http.formvalue()
    local ok, servers, err = util.parse_dns_form(form)
    if not ok then return ret(1, err) end
    local ok2, err2 = util.save_dns_servers(servers)
    if not ok2 then return ret(1, err2) end
    return ret(0, "ok")
  end
  local data = util.load_all()
  tpl.render("nodemanager/dns", { servers = data.dns_servers or {} })
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

function action_settings()
  local i18n = require "luci.i18n"
  local util = require "luci.nodemanager.util"
  local uci  = require "luci.model.uci".cursor()
  local nixio = require "nixio"

  if http.getenv("REQUEST_METHOD") == "POST" then
    local path = (http.formvalue("path") or ""):gsub("%s+$","")
    local create = http.formvalue("create") == "1"

    if path == "" then
      http.prepare_content("application/json")
      http.write_json({code=1, msg=i18n.translate("Path cannot be empty")})
      return
    end

    -- 如需创建：先建父目录再 touch 文件
    local dir = path:match("^(.+)/[^/]+$") or "/"
    luci.sys.call(string.format("mkdir -p %q >/dev/null 2>&1", dir))
    if create and not nixio.fs.access(path) then
      nixio.fs.writefile(path, "")
    end

    -- 确保存在节，再写 path
    uci:load("nodemanager")
    if not uci:get("nodemanager","config") then
      uci:add("nodemanager","nodemanager","config")
    end
    uci:set("nodemanager","config","path", path)
    uci:commit("nodemanager")

    http.prepare_content("application/json")
    http.write_json({code=0, msg="ok"})
    return
  end

  local cur = util.conf_path()
  tpl.render("nodemanager/settings", { cur_path = cur })
end
