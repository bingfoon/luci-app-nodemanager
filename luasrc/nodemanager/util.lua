local fs   = require "nixio.fs"
local sys  = require "luci.sys"
local i18n = require "luci.i18n"

local M = {}

-- Safety shim for table.insert (optional robustness)
do
  local _insert = table.insert
  function table.insert(t, a, b)
    if b == nil then return _insert(t, a) end
    if type(a) ~= "number" then return _insert(t, b) end
    return _insert(t, a, b)
  end
end

local DEFAULT_CFG = "/etc/nikki/profiles/config.yaml"
local DEFAULT_TPL = "/usr/share/nodemanager/config.template.yaml"

local function trim(s) return (s or ""):gsub("^%s+",""):gsub("%s+$","") end
local function is_ipv4(s) return s and s:match("^%d+%.%d+%.%d+%.%d+$") ~= nil end
local function is_hostname(s) return s and s:match("^[%w%-%.]+$") ~= nil end
local function is_port(p) p = tonumber(p); return p and p >= 1 and p <= 65535 end
local function is_http_url(u) return u and u:match("^https?://[%w%-%._~:/%?#%[%]@!$&'()*+,;=%%]+$") end

local function conf_path()
  local uci = require("luci.model.uci").cursor()
  local p = uci:get("nodemanager", "config", "path")
  return (p and #p>0) and p or DEFAULT_CFG
end

local function tpl_path()
  local uci = require("luci.model.uci").cursor()
  local t = uci:get("nodemanager", "config", "template")
  return (t and #t>0) and t or DEFAULT_TPL
end

local function fallback_template()
  return [===[
airport: &airport
  type: http
  interval: 86400
  health-check:
    enable: true
    url: https://captive.apple.com/
    interval: 300
  proxy: 直连

proxy-providers:
  你的机场名字:
    <<: *airport
    url: "你的机场订阅地址"

s5: &s5 {type: socks5, udp: true, dialer-proxy: "🚀 默认代理"}
proxies:
  # 落地节点信息从下面开始添加
  # 落地节点信息必须添加在这一行上面
  - {name: 直连, type: direct}

# 全局配置 
port: 7890
socks-port: 7891
redir-port: 7892
mixed-port: 7893
tproxy-port: 7894
allow-lan: true
bind-address: "*"
ipv6: false
unified-delay: true
tcp-concurrent: true
#interface-name: en0
log-level: warning
find-process-mode: off
global-client-fingerprint: chrome
keep-alive-idle: 600
keep-alive-interval: 15
#disable-keep-alive: false
profile:
  store-selected: true
  store-fake-ip: true

external-controller: 0.0.0.0:9090
secret: ""
external-ui: "/etc/nikki/run/ui"
external-ui-name: zashboard
external-ui-url: "https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"

sniffer:
  enable: true
  sniff:
    HTTP:
      ports: [80, 8080-8880]
      override-destination: true
    TLS:
      ports: [443, 8443]
    QUIC:
      ports: [443, 8443]
  force-domain:
    - "+.discord.com"
  skip-domain:
    - "+.baidu.com"
 
tun:
  enable: true
  stack: mixed
  dns-hijack: ["any:53", "tcp://any:53"]
  auto-route: true
  auto-redirect: true
  auto-detect-interface: true

dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  respect-rules: true
  enhanced-mode: fake-ip
  fake-ip-range: 28.0.0.1/8
  fake-ip-filter-mode: blacklist
  fake-ip-filter:
    - "rule-set:private_domain,ntp_domain,cn_domain"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
    - "+.xn--ngstr-lra8j.com"
    - "+.market.xiaomi.com"
    - "stun.services.mozilla1.com"
  default-nameserver:
    - tls://223.5.5.5
    - tls://119.29.29.29
  proxy-server-nameserver:
    - https://223.5.5.5/dns-query
    - https://119.29.29.29/dns-query
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
 
proxy-groups:
  - {name: 🚀 默认代理, type: select, proxies: [🔯 香港故转, 🔯 日本故转, 🔯 狮城故转, 🔯 美国故转, ♻️ 香港自动, ♻️ 日本自动, ♻️ 狮城自动, ♻️ 美国自动, ♻️ 自动选择, 🇭🇰 香港节点, 🇯🇵 日本节点, 🇸🇬 狮城节点, 🇺🇲 美国节点, 🌐 全部节点, 直连]}
  - {name: 📹 YouTube, type: select, proxies: [🔯 香港故转, 🔯 日本故转, 🔯 狮城故转, 🔯 美国故转, ♻️ 香港自动, ♻️ 日本自动, ♻️ 狮城自动, ♻️ 美国自动, ♻️ 自动选择, 🇭🇰 香港节点, 🇯🇵 日本节点, 🇸🇬 狮城节点, 🇺🇲 美国节点, 🌐 全部节点, 直连]}
  - {name: 🍀 Google, type: select, proxies: [🔯 香港故转, 🔯 日本故转, 🔯 狮城故转, 🔯 美国故转, ♻️ 香港自动, ♻️ 日本自动, ♻️ 狮城自动, ♻️ 美国自动, ♻️ 自动选择, 🇭🇰 香港节点, 🇯🇵 日本节点, 🇸🇬 狮城节点, 🇺🇲 美国节点, 🌐 全部节点, 直连]}
  - {name: 🤖 ChatGPT, type: select, proxies: [🔯 美国故转, 🔯 日本故转, 🔯 狮城故转, ♻️ 美国自动, ♻️ 日本自动, ♻️ 狮城自动, ♻️ 自动选择, 🇺🇲 美国节点, 🇯🇵 日本节点, 🇸🇬 狮城节点, 🌐 全部节点, 直连]}
  - {name: 👨🏿‍💻 GitHub, type: select, proxies: [🔯 香港故转, 🔯 日本故转, 🔯 狮城故转, 🔯 美国故转, ♻️ 香港自动, ♻️ 日本自动, ♻️ 狮城自动, ♻️ 美国自动, ♻️ 自动选择, 🇭🇰 香港节点, 🇯🇵 日本节点, 🇸🇬 狮城节点, 🇺🇲 美国节点, 🌐 全部节点, 直连]}
  - {name: 🐬 OneDrive, type: select, proxies: [🔯 香港故转, 🔯 日本故转, 🔯 狮城故转, 🔯 美国故转, ♻️ 香港自动, ♻️ 日本自动, ♻️ 狮城自动, ♻️ 美国自动, ♻️ 自动选择, 🇭🇰 香港节点, 🇯🇵 日本节点, 🇸🇬 狮城节点, 🇺🇲 美国节点, 🌐 全部节点, 直连]}
  - {name: 🪟 Microsoft, type: select, proxies: [🔯 香港故转, 🔯 日本故转, 🔯 狮城故转, 🔯 美国故转, ♻️ 香港自动, ♻️ 日本自动, ♻️ 狮城自动, ♻️ 美国自动, ♻️ 自动选择, 🇭🇰 香港节点, 🇯🇵 日本节点, 🇸🇬 狮城节点, 🇺🇲 美国节点, 🌐 全部节点, 直连]}
  - {name: 🎵 TikTok, type: select, proxies: [🔯 美国故转, 🔯 日本故转, 🔯 狮城故转, ♻️ 美国自动, ♻️ 日本自动, ♻️ 狮城自动, ♻️ 自动选择, 🇺🇲 美国节点, 🇯🇵 日本节点, 🇸🇬 狮城节点, 🌐 全部节点, 直连]}
  - {name: 📲 Telegram, type: select, proxies: [🔯 香港故转, 🔯 日本故转, 🔯 狮城故转, 🔯 美国故转, ♻️ 香港自动, ♻️ 日本自动, ♻️ 狮城自动, ♻️ 美国自动, ♻️ 自动选择, 🇭🇰 香港节点, 🇯🇵 日本节点, 🇸🇬 狮城节点, 🇺🇲 美国节点, 🌐 全部节点, 直连]}
  - {name: 🎥 NETFLIX, type: select, proxies: [🔯 狮城故转, 🔯 香港故转, 🔯 日本故转, 🔯 美国故转, ♻️ 狮城自动, ♻️ 香港自动, ♻️ 日本自动, ♻️ 美国自动, ♻️ 自动选择, 🇸🇬 狮城节点, 🇭🇰 香港节点, 🇯🇵 日本节点, 🇺🇲 美国节点, 🌐 全部节点, 直连]}
  - {name: ✈️ Speedtest, type: select, proxies: [🔯 香港故转, 🔯 日本故转, 🔯 狮城故转, 🔯 美国故转, ♻️ 香港自动, ♻️ 日本自动, ♻️ 狮城自动, ♻️ 美国自动, ♻️ 自动选择, 🇭🇰 香港节点, 🇯🇵 日本节点, 🇸🇬 狮城节点, 🇺🇲 美国节点, 🌐 全部节点, 直连]}
  - {name: 💶 PayPal, type: select, proxies: [🔯 香港故转, 🔯 日本故转, 🔯 狮城故转, 🔯 美国故转, ♻️ 香港自动, ♻️ 日本自动, ♻️ 狮城自动, ♻️ 美国自动, ♻️ 自动选择, 🇭🇰 香港节点, 🇯🇵 日本节点, 🇸🇬 狮城节点, 🇺🇲 美国节点, 🌐 全部节点, 直连]}
  - {name: 🍎 Apple, type: select, proxies: [直连, 🚀 默认代理]}
  - {name: 🐟 漏网之鱼, type: select, proxies: [🔯 香港故转, 🔯 日本故转, 🔯 狮城故转, 🔯 美国故转, ♻️ 香港自动, ♻️ 日本自动, ♻️ 狮城自动, ♻️ 美国自动, ♻️ 自动选择, 🇭🇰 香港节点, 🇯🇵 日本节点, 🇸🇬 狮城节点, 🇺🇲 美国节点, 🌐 全部节点, 直连]}
  - {name: 🇭🇰 香港节点, type: select, include-all: true, filter: "(?i)港|hk|hongkong|hong kong"}
  - {name: 🇯🇵 日本节点, type: select, include-all: true, filter: "(?i)日|jp|japan"}
  - {name: 🇸🇬 狮城节点, type: select, include-all: true, filter: "(?i)新加坡|坡|狮城|SG|Singapore"}
  - {name: 🇺🇲 美国节点, type: select, include-all: true, filter: "(?i)美|us|unitedstates|united states"}
  - {name: 🔯 香港故转, type: fallback, include-all: true, tolerance: 20, interval: 300, filter: "(?=.*(港|HK|(?i)Hong))^((?!(台|日|韩|新|深|美)).)*$"}
  - {name: 🔯 日本故转, type: fallback, include-all: true, tolerance: 20, interval: 300, filter: "(?=.*(日|JP|(?i)Japan))^((?!(港|台|韩|新|美)).)*$" }
  - {name: 🔯 狮城故转, type: fallback, include-all: true, tolerance: 20, interval: 300, filter: "(?=.*(新加坡|坡|狮城|SG|Singapore))^((?!(台|日|韩|深|美)).)*$"}
  - {name: 🔯 美国故转, type: fallback, include-all: true, tolerance: 20, interval: 300, filter: "(?=.*(美|US|(?i)States|America))^((?!(港|台|韩|新|日)).)*$" }
  - {name: ♻️ 香港自动, type: url-test, include-all: true, tolerance: 20, interval: 300, filter: "(?=.*(港|HK|(?i)Hong))^((?!(台|日|韩|新|深|美)).)*$"}
  - {name: ♻️ 日本自动, type: url-test, include-all: true, tolerance: 20, interval: 300, filter: "(?=.*(日|JP|(?i)Japan))^((?!(港|台|韩|新|美)).)*$" }
  - {name: ♻️ 狮城自动, type: url-test, include-all: true, tolerance: 20, interval: 300, filter: "(?=.*(新加坡|坡|狮城|SG|Singapore))^((?!(港|台|韩|日|美)).)*$" }
  - {name: ♻️ 美国自动, type: url-test, include-all: true, tolerance: 20, interval: 300, filter: "(?=.*(美|US|(?i)States|America))^((?!(港|台|日|韩|新)).)*$"}
  - {name: ♻️ 自动选择, type: url-test, include-all: true, tolerance: 20, interval: 300, filter: "^((?!(直连)).)*$"}
  - {name: 🌐 全部节点, type: select, include-all: true}

rules:
  - RULE-SET,private_ip,直连
  - RULE-SET,private_domain,直连
  - RULE-SET,apple_update_domain,🍎 Apple
  # 落地节点对应的子网设备添加在下面
  # 落地节点对应的子网设备添加在上面
  - RULE-SET,proxylite,🚀 默认代理
  - RULE-SET,ai,🤖 ChatGPT
  - RULE-SET,github_domain,👨🏿‍💻 GitHub
  - RULE-SET,youtube_domain,📹 YouTube
  - RULE-SET,google_domain,🍀 Google
  - RULE-SET,onedrive_domain,🐬 OneDrive
  - RULE-SET,microsoft_domain,🪟 Microsoft
  - RULE-SET,apple_domain,🍎 Apple
  - RULE-SET,tiktok_domain,🎵 TikTok
  - RULE-SET,speedtest_domain,✈️ Speedtest
  - RULE-SET,telegram_domain,📲 Telegram
  - RULE-SET,netflix_domain,🎥 NETFLIX
  - RULE-SET,paypal_domain,💶 PayPal
  - RULE-SET,gfw_domain,🚀 默认代理
  - RULE-SET,apple_ip,直连,no-resolve
  - RULE-SET,google_ip,🍀 Google,no-resolve
  - RULE-SET,netflix_ip,🎥 NETFLIX,no-resolve
  - RULE-SET,telegram_ip,📲 Telegram,no-resolve
  - RULE-SET,geolocation-!cn,🚀 默认代理
  - RULE-SET,cn_domain,直连
  - RULE-SET,cn_ip,直连
  - MATCH,🐟 漏网之鱼

rule-anchor:
  ip: &ip {type: http, interval: 86400, behavior: ipcidr, format: mrs}
  domain: &domain {type: http, interval: 86400, behavior: domain, format: mrs}
  class: &class {type: http, interval: 86400, behavior: classical, format: text}
rule-providers: 
  private_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/private.mrs"}
  ntp_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/category-ntp.mrs"}
  proxylite: { <<: *class, url: "https://raw.githubusercontent.com/qichiyuhub/rule/refs/heads/main/proxy.list"}
  ai: {  <<: *domain, url: "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/category-ai-!cn.mrs" }
  youtube_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/youtube.mrs"}
  google_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/google.mrs"}
  github_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/github.mrs"}
  telegram_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/telegram.mrs"}
  netflix_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/netflix.mrs"}
  paypal_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/paypal.mrs"}
  onedrive_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/onedrive.mrs"}
  microsoft_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/microsoft.mrs"}
  apple_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/apple-cn.mrs"}
  apple_update_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/apple-update.mrs"}
  speedtest_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/ookla-speedtest.mrs"}
  tiktok_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/tiktok.mrs"}
  gfw_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/gfw.mrs"}
  geolocation-!cn: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/geolocation-!cn.mrs"}
  cn_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs"}

  private_ip: {<<: *ip, url: "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geoip/private.mrs"}
  cn_ip: { <<: *ip, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/cn.mrs"}
  google_ip: { <<: *ip, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/google.mrs"}
  telegram_ip: { <<: *ip, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/telegram.mrs"}
  netflix_ip: { <<: *ip, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/netflix.mrs"}
  apple_ip: {<<: *ip, url: "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo-lite/geoip/apple.mrs"}
]===]
end

local function ensure_config_exists()
  local path = conf_path()
  if fs.access(path) then return path end
  local dir = path:match("^(.+)/[^/]+$") or "/"
  sys.call(string.format("mkdir -p %q >/dev/null 2>&1", dir))
  local t = tpl_path()
  local content = fs.readfile(t) or fallback_template()
  fs.writefile(path, content)
  return path
end

local function read_lines(path)
  path = path or ensure_config_exists()
  local s = fs.readfile(path) or ""
  local t = {}
  for line in (s.."\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$","")
    table.insert(t, line)
  end
  if #s == 0 then t = {} end
  return t
end

local function write_lines(lines, path)
  path = path or ensure_config_exists()
  return fs.writefile(path, table.concat(lines, "\n").."\n")
end

local function ensure_anchor_block(lines, header, start_hint, end_hint)
  local header_pat = "^%s*" .. header .. ":%s*$"
  local header_idx
  for i,l in ipairs(lines) do
    if l:match(header_pat) then header_idx = i; break end
  end

  if not header_idx then
    if #lines > 0 and lines[#lines] ~= "" then table.insert(lines, "") end
    table.insert(lines, header .. ":")
    table.insert(lines, "  # " .. start_hint)
    table.insert(lines, "  # " .. end_hint)
    return lines
  end

  local block_end = #lines
  for i = header_idx + 1, #lines do
    if lines[i]:match("^%S") then block_end = i - 1; break end
  end

  local has_start, has_end = false, false
  for i = header_idx + 1, block_end do
    if lines[i]:find(start_hint, 1, true) then has_start = true end
    if lines[i]:find(end_hint,   1, true) then has_end   = true end
  end
  if has_start and has_end then return lines end

  local out = {}
  for i=1,#lines do
    table.insert(out, lines[i])
    if i == header_idx then
      if not has_start then table.insert(out, "  # " .. start_hint) end
      if not has_end   then table.insert(out, "  # " .. end_hint)   end
    end
  end
  return out
end

local function find_range(lines, start_hint, end_hint)
  local sidx, eidx
  for i,l in ipairs(lines) do
    if not sidx and l:find(start_hint, 1, true) then sidx = i end
    if l:find(end_hint, 1, true) then eidx = i end
  end
  if sidx and eidx and eidx > sidx then
    return sidx + 1, eidx - 1
  end
  return nil, nil
end

local function parse_proxies(lines)
  local proxies = {}
  for _,l in ipairs(lines) do
    if l:match("^%s*-%s*{%s*<<:%s*%*s5") or l:match("^%s*-%s*{%s*name:%s*") then
      local name = l:match('name:%s*"([^"]-)"') or l:match("name:%s*([^,%s}]+)")
      local serv = l:match('server:%s*"([^"]-)"') or l:match("server:%s*([^,%s}]+)")
      local port = l:match("port:%s*(%d+)")
      local user = l:match('username:%s*"([^"]-)"') or l:match("username:%s*([^,%s}]+)")
      local pass = l:match('password:%s*"([^"]-)"') or l:match("password:%s*([^,%s}]+)")
      if name and serv and port and user and pass then
        table.insert(proxies, {
          name = trim(name),
          server = trim((serv or ""):gsub('^"(.*)"$','%1')),
          port = tonumber(port),
          username = trim((user or ""):gsub('^"(.*)"$','%1')),
          password = trim((pass or ""):gsub('^"(.*)"$','%1')),
        })
      end
    end
  end
  return proxies
end

-- STRICT bindmap parser: only keep valid IPv4 (a.b.c.d) and skip anything else (e.g., "0")
local function parse_bindmap(lines)
  local map = {}
  for _,l in ipairs(lines) do
    local ip, name = l:match("^%s*%-%s*SRC%-IP%-CIDR,([^,/]+)/32,([^\r\n]+)$")
    if ip and name then
      ip = trim(ip)
      name = trim(name)
      if is_ipv4(ip) then
        map[name] = map[name] or {}
        table.insert(map[name], ip)
      end
    end
  end
  return map
end

local function parse_providers(lines)
  local providers = {}
  local in_block = false
  for i,l in ipairs(lines) do
    if l:match("^%s*proxy%-providers:%s*$") then
      in_block = true
    elseif in_block and l:match("^%S") then
      break
    elseif in_block then
      local name = l:match("^%s*([%w%._%-%u%l][^:]-):%s*$")
      if name then
        local url = nil
        for k=1,6 do
          local ln = lines[i+k]; if not ln then break end
          url = url or (ln:match('url:%s*"(.-)"') or ln:match("url:%s*([^%s#]+)"))
        end
        if url then table.insert(providers, { name = trim(name), url = trim(url) }) end
      end
    end
  end
  return providers
end

local function parse_dns_servers(lines)
  local servers = {}
  local in_dns, in_ns = false, false
  for _,l in ipairs(lines) do
    if l:match("^dns:%s*$") then
      in_dns = true
    elseif in_dns and l:match("^%S") and not l:match("^dns:%s*$") then
      in_dns = false
      in_ns = false
    elseif in_dns and l:match("^%s*nameserver:%s*$") then
      in_ns = true
    elseif in_ns then
      local ip = l:match("^%s*%-%s*([%d%.]+)%s*$")
      if ip and is_ipv4(ip) then
        table.insert(servers, ip)
      end
    end
  end
  return servers
end

function M.load_all()
  local lines = read_lines()
  local s1,e1 = find_range(lines, "落地节点信息从下面开始添加", "落地节点信息必须添加在这一行上面")
  local s2,e2 = find_range(lines, "落地节点对应的子网设备添加在下面", "落地节点对应的子网设备添加在上面")

  local proxies = {}
  if s1 and e1 and s1 <= e1 then
    local slice = {}
    for i=s1,e1 do table.insert(slice, lines[i]) end
    proxies = parse_proxies(slice)
  else
    proxies = parse_proxies(lines)
  end

  local bindmap = {}
  do
    local slice
    if s2 and e2 and s2 <= e2 then
      slice = {}
      for i=s2,e2 do table.insert(slice, lines[i]) end
    end
    bindmap = parse_bindmap(slice or lines)
  end

  local providers = parse_providers(lines)
  local dns_servers = parse_dns_servers(lines)
  return { proxies = proxies, bindmap = bindmap, providers = providers, dns_servers = dns_servers }
end

-- forms
function M.parse_proxy_form(form)
  local names     = form["name[]"]      or form.name
  local servers   = form["server[]"]    or form.server
  local ports     = form["port[]"]      or form.port
  local users     = form["username[]"]  or form.username
  local passes    = form["password[]"]  or form.password
  local bindipsv  = form["bindips[]"]   or form.bindips or form["bindip[]"] or form.bindip

  if type(names)=="string" then
    names={names}; servers={servers}; ports={ports}; users={users}; passes={passes}; bindipsv={bindipsv}
  end

  local list = {}
  local name_seen = {}
  local ip_seen = {}

  local total = #(names or {})
  for i=1,total do
    local n = trim((names and names[i]) or "")
    local s = trim((servers and servers[i]) or "")
    local ptxt = trim((ports and ports[i]) or "")
    local u = trim((users and users[i]) or "")
    local w = trim((passes and passes[i]) or "")
    local field = trim((bindipsv and bindipsv[i]) or "")

    local all_blank = (n=="" and s=="" and ptxt=="" and u=="" and w=="" and field=="")
    if not all_blank then
      if n=="" or s=="" or u=="" or w=="" or ptxt=="" then
        return false,nil,i18n.translatef("Row %d has empty required fields", i)
      end
      local p = tonumber(ptxt)
      if not is_port(p) then
        return false,nil, i18n.translatef("Invalid port at row %d", i)
      end
      if not (is_hostname(s) or is_ipv4(s)) then
        return false,nil, i18n.translatef("Invalid server at row %d", i)
      end
      if name_seen[n] then
        return false,nil, i18n.translatef("Duplicate node name at row %d: %s", i, n)
      end
      name_seen[n]=i

      local ips = {}
      if field ~= "" then
        for token in field:gmatch("[^,%s\r\n]+") do
          local ip = trim(token)
          if not is_ipv4(ip) then
            return false,nil, i18n.translatef("Invalid bind IP at row %d: %s", i, ip)
          end
          if ip_seen[ip] and ip_seen[ip] ~= i then
            return false,nil, i18n.translatef("IP %s is assigned to multiple nodes (rows %d and %d)", ip, ip_seen[ip], i)
          end
          ip_seen[ip]=i
          table.insert(ips, ip)
        end
      end

      table.insert(list, { name=n, server=s, port=p, username=u, password=w, bindips=ips })
    end
  end

  return true, list
end

function M.parse_provider_form(form)
  local names = form["name[]"] or form.name
  local urls  = form["url[]"]  or form.url
  if type(names)=="string" then names={names}; urls={urls} end

  local list, seen = {}, {}
  for i=1,#(names or {}) do
    local n = trim(names[i] or "")
    local u = trim((urls and urls[i]) or "")
    local all_blank = (n=="" and u=="")
    if not all_blank then
      if n=="" or u=="" then
        return false, nil, i18n.translatef("Row %d has empty required fields", i)
      end
      if not is_http_url(u) then
        return false, nil, i18n.translatef("Invalid URL at row %d", i)
      end
      if seen[n] then
        return false, nil, i18n.translatef("Duplicate name at row %d: %s", i, n)
      end
      seen[n]=true
      table.insert(list, { name=n, url=u })
    end
  end
  return true, list
end

function M.parse_dns_form(form)
  local dns = form["dns[]"] or form.dns
  if type(dns)=="string" then dns={dns} end
  local list = {}
  for i=1,#(dns or {}) do
    local ip = trim(dns[i] or "")
    if ip ~= "" then
      if not is_ipv4(ip) then
        return false, nil, i18n.translatef("Invalid DNS IP at row %d: %s", i, ip)
      end
      table.insert(list, ip)
    end
  end
  if #list==0 then return false, nil, i18n.translate("Fields cannot be empty") end
  return true, list
end

function M.save_proxies_and_rules(list)
  local lines = read_lines()

  lines = ensure_anchor_block(lines, "proxies",
    "落地节点信息从下面开始添加",
    "落地节点信息必须添加在这一行上面")
  lines = ensure_anchor_block(lines, "rules",
    "落地节点对应的子网设备添加在下面",
    "落地节点对应的子网设备添加在上面")

  local ps,pe = find_range(lines, "落地节点信息从下面开始添加", "落地节点信息必须添加在这一行上面")
  if not (ps and pe) then return false, "Cannot locate proxies range in config.yaml" end
  local rs,re = find_range(lines, "落地节点对应的子网设备添加在下面", "落地节点对应的子网设备添加在上面")
  if not (rs and re) then return false, "Cannot locate rules range in config.yaml" end

  local newp = {}
  for _,x in ipairs(list) do
    table.insert(newp, string.format(
      '  - { <<: *s5, name: "%s", server: "%s", port: %d, username: "%s", password: "%s"}',
      x.name, x.server, x.port, x.username, x.password))
  end

  local newr = {}
  for _,x in ipairs(list) do
    if x.bindips and #x.bindips>0 then
      for _,ip in ipairs(x.bindips) do
        table.insert(newr, string.format('  - SRC-IP-CIDR,%s/32,%s', ip, x.name))
      end
    end
  end

  local out = {}
  for i=1,#lines do
    if i==ps then
      for _,l in ipairs(newp) do table.insert(out, l) end
    end
    if i>=ps and i<=pe then
    else
      table.insert(out, lines[i])
    end
  end
  lines = out
  out = {}

  for i=1,#lines do
    if i==rs then
      for _,l in ipairs(newr) do table.insert(out, l) end
    end
    if i>=rs and i<=re then
    else
      table.insert(out, lines[i])
    end
  end

  return write_lines(out) ~= nil, nil
end

function M.save_providers(list)
  local lines = read_lines()
  local start_idx
  for i,l in ipairs(lines) do
    if l:match("^%s*proxy%-providers:%s*$") then start_idx = i; break end
  end
  if not start_idx then
    if #lines > 0 and lines[#lines] ~= "" then table.insert(lines, "") end
    table.insert(lines, "proxy-providers:")
    start_idx = #lines
  end
  local end_idx = #lines
  for i=start_idx+1,#lines do
    if lines[i]:match("^%S") then end_idx = i-1; break end
  end

  local out = {}
  for i=1,start_idx do table.insert(out, lines[i]) end
  for _,p in ipairs(list) do
    table.insert(out, string.format("  %s:", p.name))
    table.insert(out, "    <<: *airport")
    table.insert(out, string.format('    url: "%s"', p.url))
  end
  for i=end_idx+1,#lines do table.insert(out, lines[i]) end
  return write_lines(out) ~= nil, nil
end

function M.save_dns_servers(servers)
  local lines = read_lines()
  local dns_start
  for i,l in ipairs(lines) do
    if l:match("^dns:%s*$") then dns_start = i; break end
  end
  if not dns_start then
    if #lines > 0 and lines[#lines] ~= "" then table.insert(lines, "") end
    table.insert(lines, "dns:")
    table.insert(lines, "  nameserver:")
    for _,ip in ipairs(servers) do table.insert(lines, string.format("    - %s", ip)) end
    return write_lines(lines) ~= nil, nil
  end

  local ns_start, ns_end
  for i=dns_start+1,#lines do
    if lines[i]:match("^%S") then break end
    if lines[i]:match("^%s*nameserver:%s*$") then
      ns_start = i; ns_end = i
      for j=i+1,#lines do
        if lines[j]:match("^%s*%-") then
          ns_end = j
        else
          if lines[j]:match("^%s*%S") and not lines[j]:match("^%s*%-") then break end
        end
        if lines[j]:match("^%S") then break end
      end
      break
    end
  end
  if not ns_start then
    local out = {}
    for i=1,#lines do
      table.insert(out, lines[i])
      if i == dns_start then
        table.insert(out, "  nameserver:")
        for _,ip in ipairs(servers) do table.insert(out, string.format("    - %s", ip)) end
      end
    end
    return write_lines(out) ~= nil, nil
  end

  local out = {}
  for i=1,ns_start do table.insert(out, lines[i]) end
  for _,ip in ipairs(servers) do
    table.insert(out, string.format("    - %s", ip))
  end
  for i=(ns_end or ns_start)+1,#lines do table.insert(out, lines[i]) end
  return write_lines(out) ~= nil, nil
end

function M.conf_path() return conf_path() end
return M
