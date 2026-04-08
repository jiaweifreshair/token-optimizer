---
name: token-optimizer
description: >
  三层 Token 优化中枢：AutoContext 自动检测上下文污染 + Caveman 输出压缩 65% +
  Context Handoff 压缩后零损失恢复。用户零感知，hooks 自动运行。
  触发：/token-optimizer、"优化token"、"token太多"
---

# Token Optimizer

三层 Token 优化中枢：输出压缩、上下文卫生、压缩交接。

## 触发

- `/token-optimizer` - 显示当前优化状态 + 建议
- `/token-optimizer status` - 运行诊断脚本
- `/token-optimizer compress [file]` - 压缩 CLAUDE.md（默认 ~/.claude/CLAUDE.md）
- 自然语言: "优化token"、"token太多"、"省token"

## 当前状态诊断

执行 `bash ~/.claude/skills/token-optimizer/scripts/status.sh` 并汇报结果。检查项:
- Caveman skill 安装状态
- AutoContext hook 注册状态（UserPromptSubmit）
- 增强版 PreCompact/SessionStart hooks
- Handoff 快照目录和最近快照

## 已激活的自动化组件

以下组件通过 hooks 自动运行，用户无需手动触发:

### 1. AutoContext - 上下文卫生自动检测

**触发**: 每次用户提交 prompt（UserPromptSubmit hook）
**脚本**: `~/.claude/plugins/installed/auto-context/scripts/context_sense.py`
**机制**: 读取 transcript 行数和体积，超阈值时注入 `<auto-context>` 提示

| 条件 | 行为 |
|------|------|
| <40 条消息 | 透明，无干预 |
| >40 条且话题连贯 | 收到提醒，判断健康则无感知 |
| >40 条且话题漂移 | 建议 `/fork` 或 `/btw` |
| >150KB transcript | 强烈建议 `/fork` |

冷却: 每 10 条消息最多触发一次。手动检查用 `/auto-context`。

### 2. 上下文交接 - 压缩前快照 + 压缩后恢复

**PreCompact** (`~/.claude/scripts/hooks/pre-compact.js`):
- 提取最近 15 条去重用户消息（85% 相似度阈值）
- 提取最近代码片段和活跃文件路径
- 写入 `~/.claude/handoff/<session_id>.md`（<=2KB）

**SessionStart** (`~/.claude/scripts/hooks/session-start.js`):
- 检测 source=compact/clear 时自动恢复快照
- 验证 cwd 匹配 + 15 分钟时间窗口
- 通过 stderr 注入恢复上下文
- 自动清理 24 小时以上旧快照

### 3. Strategic Compact 建议

**触发**: 每次 Edit/Write 操作（PreToolUse hook）
**脚本**: `~/.claude/scripts/hooks/suggest-compact.js`
- 50 次工具调用后首次建议
- 之后每 25 次提醒一次

## 手动工具

### CLAUDE.md 压缩

```bash
bash ~/.claude/skills/token-optimizer/scripts/compress-claudemd.sh <path>
```

合并连续空行、移除行尾空白、压缩分隔线。保留代码块、URL、配置。生成 `.original.md` 备份。

### Caveman 输出压缩

已安装为独立 skill，通过 `/caveman` 触发。三个级别:

| 级别 | 削减 | 适用 |
|------|------|------|
| `/caveman lite` | ~40% | 需要文档质量的输出 |
| `/caveman` (full) | ~65% | 日常开发（推荐） |
| `/caveman ultra` | ~75% | 快速迭代、内部工具 |

### Caveman Compress 内存文件压缩

已安装为独立 skill，通过 `/caveman-compress` 触发。压缩 CLAUDE.md 等内存文件，减少每 session 初始加载 ~45%。

## 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `HANDOFF_MAX_USER_MESSAGES` | 15 | 快照最大用户消息数 |
| `HANDOFF_DEDUP_THRESHOLD` | 0.85 | 消息去重阈值 |
| `HANDOFF_MAX_AGE_SEC` | 900 | 快照恢复时间窗口（秒） |
| `COMPACT_THRESHOLD` | 50 | 建议 compact 的工具调用阈值 |

## 上下文卫生最佳实践

基于 AutoContext 的三层决策框架（Sense -> Decide -> Evolve）:

1. **单任务单 session** - 完成一个功能就 `/fork`，代码已 commit，上下文重置
2. **用 `/btw` 处理临时问题** - 不相关的小问题用 `/btw` 隔离，避免污染主上下文
3. **子 Agent 分治** - 独立子任务用 Agent tool 派发，每个子 Agent 有独立上下文窗口
4. **信噪比自检** - 感觉 AI "变笨"时，先用 `/auto-context` 检查上下文健康度
5. **CLAUDE.md 定期压缩** - 项目 CLAUDE.md 超过 500 行时用 `/caveman-compress` 瘦身
