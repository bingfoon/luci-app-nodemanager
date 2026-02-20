# luci-app-nodemanager 开发规范

## Lua 后端规范

### Handler 注册

```lua
HANDLERS["action_name"] = function()
    local input = json_in()          -- POST 请求解析 JSON body
    -- 或 http.formvalue("param")    -- GET 请求参数
    -- ... 业务逻辑 ...
    json_out({ok = true, data = {...}})
end
```

### 响应格式

```lua
-- 成功 (必须包含 ok=true)
json_out({ok = true, data = {delay = 42}})

-- 失败 (必须包含 ok=false 和 err)
json_out({ok = false, err = "具体错误信息"})
```

### 文件操作

- **写前备份**：修改配置前必须调用 `fs.copy(path, path .. ".bak")`
- **路径白名单**：只允许操作 `SAFE_PREFIXES` 内的路径：
  - `/etc/nikki/`
  - `/tmp/`
  - `/usr/share/nodemanager/`
- **换行处理**：`read_lines()` 读入行数组 → 修改 → `write_lines()` 写回

### YAML 操作

- **禁止**使用第三方 YAML 库（OpenWrt 不可用）
- 使用 Lua `string.match` 行级扫描
- Section 定位模式：起始 `^keyword:` → 结束 `^%S`
- 值提取双 pattern：`'key:%s*"([^"]*)"' or 'key:%s*([^,}]+)'`
- 写回：构建新行 `table` → `table.concat(lines, "\n")`

### HTTP 外部调用

```lua
-- 使用 wget（BusyBox 标准），不用 curl
local tmp = "/tmp/nm_api_" .. tostring(os.time()) .. ".json"
sys.call(string.format("wget -q -O %q --timeout=6 %q", tmp, url))
local data = require("luci.jsonc").parse(fs.readfile(tmp))
os.remove(tmp)
```

### 时间测量

```lua
-- 使用 nixio 微秒级时钟，不用 date 命令（BusyBox 不支持 %N）
local nixio = require "nixio"
local s0, u0 = nixio.gettimeofday()
-- ... 被测操作 ...
local s1, u1 = nixio.gettimeofday()
local delay_ms = (s1 - s0) * 1000 + math.floor((u1 - u0) / 1000)
```

### 错误处理

- 每个 handler 被 `pcall()` 包裹（在 `api()` 函数中）
- 验证失败应提前 `return json_out({ok=false, err=...})`
- 不要直接 `error()`，而是返回错误响应

---

## 前端 JS 规范

### 模块声明

```javascript
'use strict';
'require view';                        // LuCI view 基类
'require ui';                          // LuCI UI 工具
'require nodemanager.common as nm';    // 本项目公共模块
```

### DOM 构建

- **必须**使用 `E()` 函数构建 DOM，**禁止** `innerHTML`
- 示例：`E('button', {'class': 'cbi-button', 'click': fn}, '文本')`

### API 调用

```javascript
// 统一通过 common.js 封装
nm.call('action_name', {key: value})
    .then(function(resp) {
        if (resp && resp.ok) { /* 成功 */ }
        else { /* 失败: resp.err */ }
    })
    .catch(function(e) { /* 网络异常 */ })
    .finally(function() { /* 恢复 UI */ });
```

### 按钮状态管理

每个异步操作必须实现三件套：

```javascript
btn.disabled = true;
btn.textContent = _('处理中...');
asyncOperation()
    .finally(function() {
        btn.disabled = false;
        btn.textContent = '💾 ' + _('Save');
    });
```

### 禁用默认 Footer

每个 view 必须添加：

```javascript
handleSaveApply: null,
handleReset: null,
addFooter: function() { return E('div'); }
```

### CSS 样式

- 使用内联 `style` 属性（LuCI 无 CSS 模块系统）
- 复用 LuCI 内置 class：`cbi-button`, `cbi-button-save`, `cbi-button-remove`, `cbi-button-add`, `cbi-button-action`, `cbi-input-text`, `cbi-section`, `cbi-map`

---

## 国际化 (i18n) 规范

### 翻译文件

- 英文：`po/en/nodemanager.po`（作为 msgid 源）
- 中文：`po/zh-cn/nodemanager.po`（翻译）

### 新增文本

1. JS 中使用 `_('English Text')` 包裹
2. 在 `po/en/nodemanager.po` 添加 `msgid`
3. 在 `po/zh-cn/nodemanager.po` 添加 `msgid` + `msgstr`

### 格式

```po
msgid "English Text"
msgstr "中文翻译"
```

---

## 命名规范

| 范围 | 规则 | 示例 |
|------|------|------|
| DOM ID | `nm-` 前缀 | `nm-proxy-body`, `nm-save-btn` |
| Lua 解析函数 | `parse_*` | `parse_proxies`, `parse_dns_servers` |
| Lua 写入函数 | `save_*_to_lines` | `save_dns_to_lines` |
| Lua 文件写入 | `write_*` | `write_lines`, `write_provider_file` |
| JS data 属性 | `data-field` | `data-field="name"`, `data-field="server"` |
| API action | 下划线分隔 | `test_dns`, `save_proxies`, `get_logs` |
| YAML 常量 | 大写 + 下划线 | `NM_PROVIDER_NAME`, `NM_GROUP_NAME` |

---

## Git 规范

### 分支策略

- `main` 分支为发布分支
- 版本号从 git tag 自动生成

### 提交信息

```
<type>: <简要描述>

type: fix / feat / refactor / docs / ci / chore
```

### `.gitignore`

- `dist/` — 构建产物
- `*.ipk` — 打包文件
- `.DS_Store` / `.vscode/` / `.idea/` — 系统和 IDE 文件
