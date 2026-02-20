# luci-app-nodemanager 架构文档

> 住宅代理节点管理器 — OpenWrt LuCI 插件

## 系统架构

```
┌─ 浏览器 ───────────────────────┐       ┌─ OpenWrt 路由器 ──────────────────────────┐
│                                │       │                                          │
│  proxies.js   ─┐               │       │  nodemanager.lua (Lua CGI)               │
│  dns.js       ─┤  LuCI JS     │       │    ├─ HANDLERS{} — 14 个 API endpoint    │
│  providers.js ─┤  客户端渲染   │◄─JSON─┤    ├─ YAML 行级解析器                    │
│  logs.js      ─┤               │       │    ├─ 多格式导入管道                      │
│  about.js     ─┘               │       │    └─ Mihomo API 桥接 (wget)             │
│                                │       │         ↕ 读写                           │
│  common.js                     │       │  config.yaml ── 主配置文件               │
│  (API封装/状态栏/测速徽章)       │       │  nm_proxies.yaml ── Provider 文件        │
│                                │       │         ↕ HTTP                           │
└────────────────────────────────┘       │  Mihomo API (:9090)                      │
                                         └──────────────────────────────────────────┘
```

## 目录结构

```
luci-app-nodemanager/
├── Makefile                          # OpenWrt SDK 构建集成 (luci.mk)
├── build.sh                          # 本地纯 Shell+Python IPK 打包 (无需 SDK)
├── README.md                         # 项目说明
├── .github/workflows/build.yml       # CI: SDK 编译 + i18n 打包 (手动触发)
├── htdocs/luci-static/resources/
│   ├── nodemanager/
│   │   ├── common.js                 # 公共模块: API 调用、状态栏、延迟徽章
│   │   └── qrcode.png                # 关于页二维码
│   └── view/nodemanager/
│       ├── proxies.js                # 节点管理 (CRUD/导入导出/拖拽排序/分页/测速/批量删除)
│       ├── dns.js                    # DNS 服务器管理 (分类管理/测速)
│       ├── providers.js              # 机场订阅管理
│       ├── logs.js                   # 日志查看
│       └── about.js                  # 关于页
├── root/usr/
│   ├── lib/lua/luci/controller/
│   │   └── nodemanager.lua           # 后端核心 (~1420 行，全部逻辑)
│   └── share/
│       ├── nodemanager/
│       │   └── config.template.yaml  # 配置模板 (每次保存时重建骨架)
│       ├── luci/menu.d/
│       │   └── luci-app-nodemanager.json   # 菜单注册 (4 个子页面)
│       └── rpcd/acl.d/
│           └── luci-app-nodemanager.json   # ACL 权限 (文件读写白名单)
├── files/etc/uci-defaults/
│   └── 90-nodemanager                # 首次安装 UCI 初始化 (path/fingerprint)
├── po/
│   ├── en/nodemanager.po             # 英文翻译 (源文本)
│   └── zh-cn/nodemanager.po          # 中文翻译
├── package/luci-i18n-nodemanager-zh-cn/
│   └── Makefile                      # i18n 子包构建 (po → lmo)
└── docs/USER_GUIDE.md                # 用户使用手册
```

## API 契约

所有 API 通过 `GET/POST /admin/services/nodemanager/api?action=<name>` 访问。

| Action | 方法 | 输入 | 输出 | 说明 |
|--------|------|------|------|------|
| `load` | GET | — | `{proxies, providers, dns, status, schemas}` | 加载全部数据 |
| `save_proxies` | POST | `{proxies: [...]}` | `{ok}` | 保存节点 + 模板重建 |
| `save_providers` | POST | `{providers: [...]}` | `{ok}` | 保存机场订阅 + 模板重建 |
| `save_dns` | POST | `{dns: {key: [...]}}` | `{ok}` | 保存 DNS 配置 + 模板重建 |
| `test_dns` | POST | `{server: "..."}` | `{delay, host}` | DNS 测速（nslookup + 随机域名 + nixio 微秒计时） |
| `test_proxy` | GET | `?name=...` | `{delay}` | 代理测速（Mihomo API） |
| `import` | POST | `{text: "..."}` | `[parsed_nodes]` | 多格式智能导入 |
| `service` | POST | `{cmd: "start/stop/restart"}` | `{status}` | 服务控制 |
| `get_logs` | GET | — | `{log}` | 获取 nikki 日志 |
| `debug_dns` | GET | — | `{dns_parsed, raw_lines}` | DNS 调试信息 |

## 响应格式

```lua
-- 成功
{ok = true, data = {delay = 42, host = "223.5.5.5"}}
-- 失败
{ok = false, err = "DNS query failed"}
```

## 配置文件路径发现 (5 级 Fallback)

```
1. UCI: nodemanager.main.path          → /etc/nikki/profiles/config.yaml
2. 进程参数: ps | grep mihomo -f ...   → 运行时配置
3. nikki UCI: nikki.mixin.profile_name → /etc/nikki/profiles/<name>.yaml
4. 目录扫描: /etc/nikki/profiles/*.yaml → 最近修改的文件（排除 nm_proxies.yaml）
5. 硬编码默认: /etc/nikki/profiles/config.yaml
```

> **缓存机制**：同一请求内 `conf_path()` 结果被缓存，避免 `write_provider_file` 写入 `nm_proxies.yaml` 后导致目录扫描误判。

## Proxy Provider 隔离架构

节点存储在独立的 `nm_proxies.yaml` 文件中，通过 `proxy-providers` 引用主配置。

### 双写策略

| 路径 | 用途 |
|------|------|
| `profiles/nm_proxies.yaml` | 持久存储（源头），读取优先从这里 |
| `run/nm_proxies.yaml` | 运行时副本，Mihomo 从这里加载 |

Mihomo 的 `-d` 目录为 `/etc/nikki/run/`，provider 文件路径必须在此目录下（安全限制）。`mihomo_home()` 从进程 `-d` 参数自动检测。

保存时**同时写两个位置**，读取时**优先从 `profiles/`**，回退到 `run/`。

### Provider 条目注入（模板为准）

`rebuild_config` 在 `copy_section` 之前，先用 `extract_nm_nodes_block` 从模板提取 nm-nodes 块。
`save_provider_entry_to_lines` 采用**先删后插**策略：
1. 遍历 `proxy-providers:` 段，删除**所有**已有的 `nm-nodes` 块
2. 在段末尾插入从模板提取的原始 nm-nodes 条目

```yaml
# 主配置自动生成（来自 config.template.yaml）
proxy-providers:
  nm-nodes:
    type: file
    path: nm_proxies.yaml              # 相对于 Mihomo -d 目录
    override:
      additional-prefix: "[NM] "       # 隔离标记，exclude-filter 匹配
      udp: true
      dialer-proxy: "🚀 默认代理"      # 来自模板定义
    health-check:
      enable: false

proxy-groups:
  - {name: 🏠 住宅节点, type: select, use: [nm-nodes]}
```

**隔离性**：
- `override.additional-prefix: "[NM] "` 为所有托管节点名添加前缀
- 其他代理组通过 `exclude-filter: "[NM]"` 排除，即使 `include-all: true` 也不会包含

> `nm-nodes` 是系统内部 provider，机场管理页面自动过滤不显示。

## 模板重建机制

每次 `save_proxies` / `save_providers` / `save_dns` 时，config.yaml 从模板重建：

```
① 读取模板 config.template.yaml (骨架)
② 读取当前 config.yaml (用户数据)
③ 段级复制: proxy-providers, proxies 从当前配置 → 模板
④ DNS 校验: 如果 nameserver key 结构与模板一致 → 保留用户 DNS 地址
⑤ 注入: nm-nodes provider 条目 + SRC-IP 绑定规则
⑥ 写回 config.yaml
```

| 来源 | 段 |
|------|----|
| **模板** | general / sniffer / tun / dns 结构 / proxy-groups / rules / rule-providers |
| **当前配置** | proxy-providers (机场) / proxies (手动节点) / DNS 地址列表 (结构须匹配模板) |

> 模板路径由 UCI `nodemanager.main.template` 配置，默认 `/usr/share/nodemanager/config.template.yaml`。
> 如果模板文件不存在，fallback 到原有行为（直接修改 config.yaml）。

## Bind IP 规则管理

节点的 Bind IP 保存为 `config.yaml` → `rules:` 段的 `SRC-IP-CIDR` 规则：

```yaml
rules:
  - SRC-IP-CIDR,192.168.5.101/32,🇺🇲 S5 US01   # 自动生成
  - RULE-SET,proxylite,🚀 默认代理               # 锚点行
```

**保存策略（幂等）**：
1. 扫描 `rules:` 段，只删除**托管节点名**对应的 SRC-IP 规则（用户手动添加的非托管规则不受影响）
2. 在 `RULE-SET,ai` 行前面插入新规则（找不到则回退到段末尾）

## YAML 解析策略

纯 Lua `string.match` 行扫描，无第三方 YAML 库：

1. **Section 定位**：`^keyword:` → 扫描至 `^%S`（下一个顶级 key）
2. **列表项检测**：`^%s*-%s*{` 匹配行内 YAML 对象
3. **值提取**：双 pattern `'key:%s*"([^"]*)"' or 'key:%s*([^,}]+)'`
4. **写回策略**：构建新行数组 → 替换 section 内容 → `table.concat(lines, "\n")`

## 安全模型

- **路径白名单**：`SAFE_PREFIXES = {"/etc/nikki/", "/tmp/", "/usr/share/nodemanager/"}`
- **ACL 权限**：通过 `rpcd/acl.d/` 控制文件读写范围
- **写前备份**：修改配置前自动创建 `.bak` 文件
- **pcall 保护**：所有 handler 被 pcall 包裹，异常不会导致 500 崩溃

## 导入管道

支持 4 种格式自动检测，优先级：

```
1. JSON     — 以 { 或 [ 开头
2. YAML     — 匹配 `- {name:` 或 `- name:`
3. Lines    — 逐行解析 URL/host:port
```

单次导入上限 64KB / 500 条。

## Client-Fingerprint 自动迁移

Mihomo 废弃了 `global-client-fingerprint` 全局配置，要求在每个 proxy 上单独设置 `client-fingerprint`。

插件在保存节点时自动处理：

```
1. 读主配置的 global-client-fingerprint 值
2. 迁移到 UCI: nodemanager.main.fingerprint（持久存储）
3. 删除主配置中的 global-client-fingerprint 行
4. 每个 proxy 注入 client-fingerprint: "<值>"
```

- UCI 默认值：`chrome`（首次安装时设置）
- 空字符串 = 不注入
