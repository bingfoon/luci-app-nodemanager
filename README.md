# luci-app-nodemanager

> OpenWrt LuCI 插件 — 管理 Mihomo/Clash 代理节点、机场订阅和 DNS 配置

## ✨ 功能

| 功能 | 说明 |
|------|------|
| **节点管理** | socks5 / http 代理增删改查、拖拽排序 |
| **绑定 IP** | 为每个节点分配客户端 IP |
| **机场订阅** | 管理 proxy-provider 订阅地址 |
| **DNS 管理** | 自定义上游 DNS 服务器 |
| **导入代理** | 支持 JSON / YAML / TXT / URL 四种格式，**自动识别** |
| **导出代理** | 一键导出为 JSON 文件 |
| **代理测速** | 调用 Mihomo API 测试节点延迟 |
| **服务控制** | 显示 nikki 运行状态，一键启动/重启 |
| **日志查看** | 实时查看系统日志 |
| **自动备份** | 每次保存前自动创建 `.bak` 文件 |

## 📦 安装

### 从 Release 安装

```bash
# 下载 IPK 后传到路由器
scp luci-app-nodemanager_*.ipk luci-i18n-nodemanager-zh-cn_*.ipk root@<router>:/tmp/

# 安装
ssh root@<router>
opkg install /tmp/luci-app-nodemanager_*.ipk /tmp/luci-i18n-nodemanager-zh-cn_*.ipk
```

### 本地 Docker 构建

```bash
git clone https://github.com/bingfoon/luci-app-nodemanager.git
cd luci-app-nodemanager
./build.sh
# IPK 输出到 dist/ 目录
```

> 需要 Docker Desktop。首次构建约 3 分钟（SDK 下载会被缓存），后续约 30 秒。

## 📂 项目结构

```
luci-app-nodemanager/
├── htdocs/luci-static/resources/
│   ├── nodemanager/
│   │   └── common.js                 # 共享模块（API封装/状态条/测速）
│   └── view/nodemanager/
│       ├── proxies.js                 # 节点管理（CRUD/拖拽/导入导出/测速）
│       ├── providers.js               # 机场管理
│       ├── dns.js                     # DNS 管理
│       ├── settings.js                # 设置 + 服务控制
│       └── logs.js                    # 日志查看
├── root/
│   ├── usr/lib/lua/luci/controller/
│   │   └── nodemanager.lua            # 统一 API 后端
│   ├── usr/share/luci/menu.d/
│   │   └── luci-app-nodemanager.json  # 声明式菜单
│   ├── usr/share/rpcd/acl.d/
│   │   └── luci-app-nodemanager.json  # 权限定义
│   ├── usr/share/nodemanager/
│   │   └── config.template.yaml       # 配置模板
│   └── etc/uci-defaults/
│       └── 90-nodemanager             # 首次安装初始化
├── po/                                # i18n 翻译
├── build.sh                           # Docker 本地构建
└── Makefile                           # OpenWrt 构建
```

## 🏗️ 架构

```
┌─ 浏览器 ──────────────────┐       ┌─ 路由器 ─────────────────────┐
│  view/nodemanager/*.js     │       │  controller/nodemanager.lua   │
│  (LuCI JS 客户端渲染)      │◄─JSON─┤  (Lua CGI 后端, 8 APIs)       │
│                            │       │       ↕ 读写                   │
│  common.js                 │       │  config.yaml                  │
│  (状态条/测速/API封装)      │       │       ↕ 代理调用               │
└────────────────────────────┘       │  Mihomo API (:9090)           │
                                     └───────────────────────────────┘
```

## 📥 导入格式

支持四种格式，**粘贴即可，无需选择格式**：

```bash
# URL 格式
socks5://user:pass@1.2.3.4:1080#节点名

# TXT 格式（一行一个）
1.2.3.4:1080 # 节点名
user:pass@1.2.3.4:1080

# JSON 格式
[{"name":"HK","type":"socks5","server":"1.2.3.4","port":1080,"username":"u","password":"p"}]

# YAML 格式（Clash 片段）
- {name: HK, type: socks5, server: 1.2.3.4, port: 1080, username: u, password: p}
```

## 🛡️ 依赖

- OpenWrt 24.10+
- luci-base
- Mihomo (nikki) 已安装并配置

## 📄 License

MIT
