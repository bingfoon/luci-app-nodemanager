---
description: 开始编码任务前的预检工作流
---

# Pre-Task 预检工作流

在开始任何编码任务前，执行以下步骤：

## 1. 匹配技能

根据任务涉及的文件类型，加载对应的 SKILL.md：

| 涉及文件 | 需要加载的技能 |
|-----------|---------------|
| `*.lua` (后端) | `.agent/skills/luci-development/SKILL.md` |
| `*.js` (前端) | `.agent/skills/luci-development/SKILL.md` |
| `*.po` (翻译) | `.agent/skills/luci-development/SKILL.md` |
| `Makefile` / `build.sh` | `.agent/skills/luci-development/SKILL.md` |

// turbo
## 2. 读取技能文件

对匹配到的每个 SKILL.md 执行 `view_file`，确保理解开发模式。

## 3. 阅读规范

// turbo
- 读取 `CONVENTIONS.md` 了解编码规范
// turbo
- 读取 `ARCHITECTURE.md` 了解系统架构

## 4. 检查 i18n

如果修改涉及用户可见文本：
- 提醒在 implementation plan 中注明需要更新 `po/en/nodemanager.po` 和 `po/zh-cn/nodemanager.po`

## 5. 输出已加载清单

在 implementation plan 开头列出：
```
已加载技能: luci-development
已阅读规范: CONVENTIONS.md, ARCHITECTURE.md
```
