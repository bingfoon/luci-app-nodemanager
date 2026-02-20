---
description: 发布新版本到 GitHub
---

# Release 发布工作流

## 1. 确认更改已提交

```bash
cd /Users/bingfoon/Code/luci-app-nodemanager && git status
```

确保工作区干净。

## 2. 创建版本标签

```bash
# 查看当前最新 tag
git describe --tags --abbrev=0

# 创建新 tag (遵循语义化版本)
git tag -a v2.x.x -m "版本描述"
git push origin v2.x.x
```

## 3. 触发 CI 构建

在 GitHub 仓库 → Actions → `Build luci-app-nodemanager` → `Run workflow`

等待构建完成，下载 artifacts 中的两个 IPK：
- `luci-app-nodemanager_<version>_all.ipk`
- `luci-i18n-nodemanager-zh-cn_<version>_all.ipk`

## 4. 创建 GitHub Release

在 GitHub 仓库 → Releases → `Draft a new release`：
- Tag: 选择刚创建的 `v2.x.x`
- Title: `v2.x.x`
- 描述: 列出本次更新内容
- 附件: 上传两个 IPK 文件

## 5. 本地构建保底

如果 CI 构建失败，可以本地构建：

```bash
bash build.sh
# IPK 在 dist/ 目录
```

注意：本地构建不含 i18n 包（需要 po2lmo 工具）。
