---
name: LuCI App Development
description: OpenWrt LuCI 插件开发技能 — 涵盖 Lua 后端、LuCI JS 前端、YAML 操作、IPK 打包
---

# LuCI App 开发技能

## 适用场景

当修改涉及以下文件时，必须参考本技能：
- `root/usr/lib/lua/luci/controller/nodemanager.lua` — Lua 后端
- `htdocs/luci-static/resources/view/nodemanager/*.js` — LuCI JS 视图
- `htdocs/luci-static/resources/nodemanager/common.js` — 公共模块
- `root/usr/share/luci/menu.d/*.json` — 菜单配置
- `root/usr/share/rpcd/acl.d/*.json` — ACL 权限
- `root/usr/share/nodemanager/config.template.yaml` — 配置模板
- `po/**/*.po` — 翻译文件

## 一、LuCI JS View 开发

### 基本结构

```javascript
'use strict';
'require view';
'require ui';
'require nodemanager.common as nm';

return view.extend({
    // 1. 数据加载 (异步)
    load: function() {
        return nm.call('load').then(function(resp) {
            return (resp && resp.ok) ? resp.data : {};
        });
    },

    // 2. 渲染 (load 的返回值作为参数)
    render: function(data) {
        var self = this;
        return E('div', {'class': 'cbi-map'}, [
            E('h2', {}, _('Page Title')),
            nm.renderStatusBar(data.status),
            // ... 页面内容
        ]);
    },

    // 3. 禁用默认 footer (必须)
    handleSaveApply: null,
    handleReset: null,
    addFooter: function() { return E('div'); }
});
```

### 公共模块 (common.js)

```javascript
// 基于 baseclass 而非 view
return baseclass.extend({
    apiUrl: L.url('admin/services/nodemanager/api'),
    call: function(action, data) { /* JSON 请求封装 */ },
    renderStatusBar: function(status) { /* 服务状态栏 */ },
    delayBadge: function(delay) { /* 延迟颜色徽章 */ },
    testProxy: function(name) { /* 代理测速 */ }
});
```

### DOM 构建规则

```javascript
// ✅ 正确：使用 E() 函数
E('button', {
    'class': 'cbi-button cbi-button-save',
    'click': function(ev) { /* handler */ }
}, '💾 ' + _('Save'))

// ❌ 错误：使用 innerHTML
div.innerHTML = '<button>Save</button>';
```

### 新增页面清单

1. 创建 `htdocs/luci-static/resources/view/nodemanager/<name>.js`
2. 在 `root/usr/share/luci/menu.d/luci-app-nodemanager.json` 添加菜单项
3. 如果需要新 API，在 `nodemanager.lua` 添加 HANDLER

---

## 二、Lua Controller 后端

### API 分发模式

```lua
-- 路由注册 (index 函数)
function index()
    entry({"admin", "services", "nodemanager"}, firstchild(), _("Node Manager"), 70)
    entry({"admin", "services", "nodemanager", "api"}, call("api"), nil).leaf = true
end

-- Handler 注册
HANDLERS["my_action"] = function()
    local input = json_in()
    -- 业务逻辑
    json_out({ok = true, data = {result = "value"}})
end
```

### 可用依赖 (OpenWrt 标准库)

```lua
local http = require "luci.http"       -- HTTP 请求/响应
local sys  = require "luci.sys"        -- 系统调用 (sys.call, sys.exec)
local fs   = require "nixio.fs"        -- 文件操作 (readfile, writefile, stat)
local uci  = require "luci.model.uci"  -- UCI 配置
local jsonc = require "luci.jsonc"     -- JSON 编解码
local nixio = require "nixio"          -- 底层 I/O (gettimeofday)
```

### 不可用

- 无 `date +%N` (BusyBox 不支持纳秒)
- 无 `luayaml` / `lyaml` 等 YAML 库
- 无 `luasocket` (部分固件可能缺失)
- 无 `curl` (用 `wget -q -O`)

### conf_path() 缓存注意

`conf_path()` 结果在同一请求内被缓存。目录扫描步骤已排除 `nm_proxies.yaml`，避免被 `write_provider_file` 先写入的文件干扰。

### Provider 文件双写

`nm_proxies.yaml` 采用双写策略：
- **持久存储**：`profiles/`（`nm_storage_path()`，读取优先）
- **运行时副本**：`run/`（`nm_runtime_path()`，Mihomo `-d` 目录下，满足安全限制）
- `mihomo_home()` 从进程 `-d` 参数自动检测 home 目录

### 模板重建机制

每次 `save_proxies`/`save_providers`/`save_dns` 时，`rebuild_config()` 从模板重建 config.yaml：

```lua
-- 模板(骨架) + 当前配置(用户数据) → 新 config
rebuild_config = function(proxy_list)
    local tpl = read_template_lines()       -- 读模板
    local cur = read_lines()                -- 读当前配置
    tpl = copy_section(cur, tpl, "proxy-providers")  -- 保留用户机场
    tpl = copy_section(cur, tpl, "proxies")           -- 保留手动节点
    -- DNS: 结构匹配模板则保留用户地址，否则用模板默认
    -- nm-nodes provider + SRC-IP rules 注入
    return tpl
end
```

**段级归属**: `proxy-providers` 和 `proxies` 从当前配置保留，其余始终从模板。

---

## 三、YAML 行级操作

### 读取 Section

```lua
local in_section = false
for _, line in ipairs(lines) do
    if line:match("^dns:") then
        in_section = true
    elseif in_section and line:match("^%S") then
        break  -- 离开当前 section
    elseif in_section then
        -- 处理 section 内的行
        local val = line:match("^%s+-%s+(.+)")
        if val then
            table.insert(result, trim(val))
        end
    end
end
```

### 值提取（带引号兼容）

```lua
-- 先尝试带引号，再尝试不带引号
local name = line:match('name:%s*"([^"]*)"')
          or line:match("name:%s*([^,}]+)")
```

### ⚠️ Lua 模式转义注意

Lua 中 `-` 是非贪婪量词，用于模式匹配时**必须转义**：

```lua
-- ❗ 错误："nm-nodes" 中的 - 被解释为量词，匹配失败
line:match("nm-nodes:")  -- ✘

-- ✅ 正确：转义后匹配
line:match("nm%-nodes:")  -- ✔
-- 或动态转义
line:match(name:gsub("%-", "%%-") .. ":")  -- ✔
```

### 写回 Section

```lua
local result = {}
-- 1. 复制 section 之前的行
for i = 1, section_start do table.insert(result, lines[i]) end
-- 2. 插入新内容
for _, new_line in ipairs(new_lines) do table.insert(result, new_line) end
-- 3. 复制 section 之后的行
for i = section_end + 1, #lines do table.insert(result, lines[i]) end
return result
```

---

## 四、IPK 打包

### 本地打包 (build.sh)

```bash
bash build.sh
# 输出: dist/luci-app-nodemanager_<version>_all.ipk
```

IPK 结构（外层 tar.gz，GNU_FORMAT）：
```
./debian-binary          → "2.0\n"
./control.tar.gz         → control, postinst, prerm
./data.tar.gz            → 实际文件树
```

### postinst 必须操作

```bash
/etc/init.d/rpcd restart      # 重新加载 ACL
/etc/init.d/uhttpd restart    # 重新加载路由
rm -rf /tmp/luci-modulecache /tmp/luci-indexcache*  # 清 LuCI 缓存
```

---

## 五、新增 Proxy Schema

当需要支持新代理类型（如 `vmess`）时：

```lua
SCHEMAS["vmess"] = {
    required = {"uuid"},
    output = function(p)
        return string.format(
            '  - {name: "%s", type: vmess, server: "%s", port: %s, uuid: "%s"}',
            p.name, p.server, p.port, p.uuid or "")
    end
}
```

同时在前端 `proxies.js` 的 `createRow` 中添加对应字段。
