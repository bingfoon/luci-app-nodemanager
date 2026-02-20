---
description: 本地构建 IPK 安装包
---

# Build 构建工作流

// turbo-all

## 1. 运行本地打包

```bash
cd /Users/bingfoon/Code/luci-app-nodemanager && bash build.sh
```

## 2. 验证输出

检查 `dist/` 目录下是否生成了 IPK 文件：

```bash
ls -lh dist/*.ipk
```

## 3. 部署到路由器（可选）

```bash
# 替换 <router> 为路由器 IP
scp dist/luci-app-nodemanager_*.ipk root@<router>:/tmp/
ssh root@<router> 'opkg install /tmp/luci-app-nodemanager_*.ipk && rm -f /tmp/luci-app-nodemanager_*.ipk'
```

## 4. CI 构建（可选）

在 GitHub 仓库页面手动触发 Actions：
- Workflow: `Build luci-app-nodemanager + zh-cn i18n (SDK 24.10.2)`
- 触发方式: `workflow_dispatch`（手动）
- 产物: 两个 IPK (主包 + zh-cn i18n 包)
