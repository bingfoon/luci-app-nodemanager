---
description: 调试和排查问题的方法
---

# Debug 调试工作流

## 1. 检查 YAML 解析结果

通过 `debug_dns` API 检查后端是否正确解析了配置文件：

```bash
# 在路由器上
curl -s 'http://127.0.0.1/cgi-bin/luci/admin/services/nodemanager/api?action=debug_dns' | python3 -m json.tool
```

返回值包含 `dns_parsed`（解析结果）和 `raw_lines`（原始 YAML 行）。

## 2. 查看服务日志

```bash
# 通过 API
curl -s 'http://127.0.0.1/cgi-bin/luci/admin/services/nodemanager/api?action=get_logs' | python3 -m json.tool

# 直接 SSH
logread | grep -i nodemanager | tail -50
```

## 3. 检查配置文件状态

```bash
# 查看配置路径
uci get nodemanager.main.path

# 检查文件存在性
ls -la /etc/nikki/profiles/config.yaml
ls -la /etc/nikki/profiles/nm_proxies.yaml

# 查看备份
ls -la /etc/nikki/profiles/*.bak
```

## 4. 检查服务状态

```bash
# Mihomo/nikki 是否运行
pgrep -f mihomo

# Mihomo API 是否可访问
wget -q -O - http://127.0.0.1:9090/version
```

## 5. 清除 LuCI 缓存

页面异常时首先尝试：

```bash
rm -rf /tmp/luci-modulecache /tmp/luci-indexcache*
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

## 6. 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| 页面空白 / 404 | LuCI 缓存未刷新 | 清缓存 + 重启 uhttpd |
| 保存后不生效 | 未重启 nikki | 状态栏点击重启 |
| DNS 测速 0ms | BusyBox `date` 无纳秒 + DNS 缓存 | 已修复：nslookup 随机域名 + nixio 微秒计时 |
| 导入解析失败 | 格式不匹配 | 检查是否超过 64KB / 500 条 |
| API 返回 403 | ACL 权限不足 | 检查 `rpcd/acl.d/` 配置 + 重启 rpcd |
| Provider 节点不显示 | proxy-providers 配置缺失 | 检查主配置是否有 nm-nodes 条目 |
| 保存后 config.yaml 没变 | conf_path 竞态 | 已修复：缓存路径 + 排除 nm_proxies.yaml |
| nm-nodes 重复插入 | provider 边界检测不准 | 已修复：精确缩进匹配 |

## 7. 开发调试 (在 Mac 上)

由于无法在 Mac 上运行 LuCI，开发调试方式：

1. **语法检查**：`luac -p nodemanager.lua`（需安装 lua）
2. **本地打包测试**：`bash build.sh` 验证文件收集正确
3. **部署联调**：scp IPK 到路由器安装后在浏览器测试
4. **日志调试**：在 Lua 中用 `sys.call("logger -t nodemanager 'debug msg'")` 写入 syslog
