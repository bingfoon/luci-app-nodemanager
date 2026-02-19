# luci-app-nodemanager

> OpenWrt LuCI 插件 — 住宅代理节点管理器

一站式管理 socks5/http 代理节点，自动生成 Mihomo 配置，支持设备 IP 绑定和智能 DNS 管理。

## ✨ 功能

| 功能 | 说明 |
|------|------|
| **节点管理** | socks5 / http 代理增删改查、拖拽排序 |
| **设备绑定** | 为每个节点绑定客户端 IP 或子网（自动识别 `/24`） |
| **代理组** | 自动创建 `🏠住宅节点` 代理组，与其他组完全隔离 |
| **前置节点** | 自动从 YAML anchor 继承 `dialer-proxy` 配置 |
| **机场订阅** | 管理 proxy-provider 订阅地址 |
| **DNS 管理** | 按分类管理上游 DNS 服务器 |
| **智能导入** | JSON / YAML / TXT / URL 四种格式自动识别 |
| **导出备份** | 一键导出节点为 JSON 文件 |
| **代理测速** | 调用 Mihomo API 测试节点延迟 |
| **服务控制** | 显示 nikki 运行状态，一键启动/重启 |

## 📦 安装

```bash
# 传到路由器
scp luci-app-nodemanager_*.ipk root@<router>:/tmp/

# SSH 安装（推荐）
ssh root@<router> 'opkg install /tmp/luci-app-nodemanager_*.ipk && rm -rf /tmp/luci-*'
```

> ⚠️ 请通过 SSH 安装，LuCI 网页安装器对大文件可能报错。

## 🏗️ 架构

```
┌─ 浏览器 ──────────────────┐       ┌─ 路由器 ─────────────────────────┐
│  proxies.js / dns.js ...   │       │  nodemanager.lua (Lua CGI 后端)   │
│  (LuCI JS 客户端渲染)      │◄─JSON─┤       ↕ 读写                      │
│                            │       │  config.yaml (主配置)             │
│  common.js                 │       │  nm_proxies.yaml (Provider 文件)  │
│  (状态条/测速/API封装)      │       │       ↕ 代理调用                   │
└────────────────────────────┘       │  Mihomo API (:9090)              │
                                     └──────────────────────────────────┘
```

### Proxy Provider 隔离架构

节点存储在独立的 `nm_proxies.yaml` 文件中，通过 `proxy-providers` 引用：

- **隔离性**：`include-all: true` 的代理组不会包含托管节点
- **前置节点**：通过 `override.dialer-proxy` 自动继承
- **性能**：200+ 节点无性能问题，无正则扫描开销

```yaml
# 主配置自动生成
proxy-providers:
  nm-nodes:
    type: file
    path: profiles/nm_proxies.yaml
    override:
      dialer-proxy: "前置节点名"
    health-check:
      enable: false

proxy-groups:
  - name: "🏠住宅节点"
    type: select
    use:
      - nm-nodes
```

## 📥 导入格式

粘贴即可，**无需选择格式**，自动识别：

```bash
# URL 格式
socks5://user:pass@1.2.3.4:1080#节点名

# TXT 格式
1.2.3.4:1080 # 节点名
user:pass@1.2.3.4:1080

# JSON 格式
[{"name":"HK","type":"socks5","server":"1.2.3.4","port":1080,"username":"u","password":"p"}]

# YAML 格式（Clash 片段）
- {name: HK, type: socks5, server: 1.2.3.4, port: 1080, username: u, password: p}
```

## 🔧 本地构建

```bash
git clone https://github.com/MobiGuru/luci-app-nodemanager.git
cd luci-app-nodemanager
bash build.sh
# IPK → dist/
```

## 🛡️ 依赖

- OpenWrt 24.10+
- luci-base
- Mihomo (nikki) 已安装并配置

## 📄 License

MIT
