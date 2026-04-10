---
name: auto-context
description: >
  手动上下文卫生检查。用于评估当前会话是否存在上下文污染（长对话、话题漂移、历史噪声），
  并给出 continue / /fork / /btw / new session 的建议。
  自动模式由 UserPromptSubmit hook 的 context_sense.py 触发（lovstudio 规则迁移版）。
license: MIT
compatibility: codex
metadata:
  source: lovstudio:auto-context
  repo: https://github.com/lovstudio/skills
---

# AutoContext

## 自动模式（Hook）

当 `UserPromptSubmit` 触发时，`context_sense.py` 会做量化检测：
- 消息条目 >= 40：提醒关注上下文纯净度
- transcript >= 150KB：强提醒建议考虑 `/fork` 或 `/btw`
- 默认冷却 10 条消息，避免重复刷屏

出现 `<auto-context>` 提示时：
1. 上下文仍相关：继续，不必额外说明
2. 夹杂少量噪声：忽略旧噪声继续推进
3. 多数历史已不相关：建议 `/fork` 或 `/btw`
4. 会话临近饱和：建议新开会话

## 手动模式（`/auto-context`）

当用户主动输入 `/auto-context`，输出 3-5 行检查结论：
1. Measure: 估算消息规模、工具调用密度、话题漂移迹象
2. Assess: healthy / noisy / polluted / critical
3. Recommend: continue / `/fork` / `/btw` / new session

要求：
- 建议必须短、可执行
- 上下文健康时不要过度打扰
- 只建议，不自动切换会话
