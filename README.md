# Token Optimizer

Claude Code 三层 Token 优化系统。自动压缩输出、自动检测上下文污染、自动交接压缩快照 - 用户零感知。

## 问题

长 session 中 AI "越聊越笨"不是模型问题，是上下文污染：之前任务的调试日志、已解决的错误、不相关的代码片段占据窗口，稀释了对当前任务的注意力。

## 方案

三层自动化，各自独立，协同工作：

```
Layer 1  Caveman 输出压缩        /caveman           -65% 输出 tokens
Layer 2  AutoContext 上下文卫生   UserPromptSubmit    自动检测话题漂移
Layer 3  Context Handoff 交接     PreCompact hook     压缩后零损失恢复
```

## 架构

```
用户输入 prompt
    |
    v
[UserPromptSubmit hook] ─── AutoContext: context_sense.py
    |                        读 transcript 行数/体积
    |                        超阈值 -> 注入 <auto-context> 提示
    |                        Claude 自判断: 继续 / /fork / /btw
    v
Claude 执行任务
    |
    v
[PreToolUse hook] ─── suggest-compact.js
    |                  50次工具调用后建议 /compact
    v
[Edit/Write 完成]
    |
    v
[自动压缩触发]
    |
    v
[PreCompact hook] ─── enhanced-pre-compact.js
    |                   提取: 15条用户消息 + 代码片段 + 文件路径
    |                   写入: ~/.claude/handoff/<session>.md (<=2KB)
    v
[SessionStart hook] ─── enhanced-session-start.js
                         source=compact -> 恢复快照
                         验证: cwd匹配 + 15分钟窗口
                         注入: 快照作为 additional context
```

## 文件结构

```
~/.claude/skills/token-optimizer/
├── SKILL.md                           # Skill 定义（/token-optimizer 入口）
├── README.md                          # 本文件
└── scripts/
    ├── install.sh                     # 一键安装脚本
    ├── status.sh                      # 状态诊断
    ├── compress-claudemd.sh           # CLAUDE.md 无损压缩
    ├── enhanced-pre-compact.js        # PreCompact hook（上下文快照）
    └── enhanced-session-start.js      # SessionStart hook（自动恢复）

~/.claude/plugins/installed/auto-context/
├── .claude-plugin/plugin.json         # Plugin 清单
├── hooks/hooks.json                   # UserPromptSubmit hook 定义
├── scripts/context_sense.py           # 上下文卫生检测脚本
└── skills/auto-context/SKILL.md       # /auto-context 手动触发

~/.claude/skills/caveman/              # Caveman 输出压缩 skill
~/.claude/skills/caveman-compress/     # CLAUDE.md 压缩 skill
~/.claude/skills/auto-context/         # AutoContext 手动触发 skill
~/.claude/handoff/                     # 上下文快照存储
```

## Hooks 注册

在 `~/.claude/settings.json` 中注册了以下 hooks：

| Hook 事件 | 脚本 | 功能 |
|-----------|------|------|
| `UserPromptSubmit` | `context_sense.py` | 上下文卫生自动检测 |
| `PreCompact` | `enhanced-pre-compact.js` | 压缩前保存上下文快照 |
| `SessionStart` | `enhanced-session-start.js` | 压缩后恢复快照 |
| `PreToolUse` (Edit/Write) | `suggest-compact.js` | 工具调用计数，建议 /compact |

## 使用

所有自动化组件无需手动操作，重启 session 后即生效。

手动命令：

```bash
# 查看优化状态
/token-optimizer status

# 手动检查上下文健康度
/auto-context

# 启用输出压缩（当前 session）
/caveman              # 默认 full 模式，-65%
/caveman lite         # 保留完整句式，-40%
/caveman ultra        # 最大压缩，-75%

# 压缩 CLAUDE.md 文件
/caveman-compress     # 压缩内存文件，-45% 每 session 加载

# 压缩指定文件（去空行、去行尾空白）
/token-optimizer compress ~/.claude/CLAUDE.md
```

## 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `HANDOFF_MAX_USER_MESSAGES` | `15` | 快照中保留的最大用户消息数 |
| `HANDOFF_DEDUP_THRESHOLD` | `0.85` | 消息去重相似度阈值 |
| `HANDOFF_MAX_AGE_SEC` | `900` | 快照恢复最大时间窗口（秒） |
| `COMPACT_THRESHOLD` | `50` | 建议 /compact 的工具调用阈值 |

## 设计理念

借鉴 [AutoContext](https://mp.weixin.qq.com/s/QeKkh0-vBEB3t9reYWKjPQ) (lovstudio) 的 Plugin + Skill 双层架构：

- **Plugin (Hook)** 负责自动触发 - 用户不需要记得什么时候该检查上下文
- **Skill** 负责手动触发 - 用户主动检查时获得完整报告
- **脚本做"笨"的量化检测** - 行数/体积/冷却
- **Claude 做"聪明"的定性判断** - 信噪比/话题相关度

三层决策框架 (Sense -> Decide -> Evolve)：
1. **Sense** - 量化检测上下文负载（行数、体积、工具调用次数）
2. **Decide** - Claude 自主判断：继续 / 压缩 / fork / 全新 session
3. **Evolve** - 项目配置（CLAUDE.md）随使用自动沉淀经验

## 致谢

- [lovstudio/skills](https://github.com/lovstudio/skills) - AutoContext 原始实现
- [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) - Caveman 输出压缩
- [who96/claude-code-context-handoff](https://github.com/who96/claude-code-context-handoff) - 上下文交接机制
- [mksglu/context-mode](https://github.com/mksglu/context-mode) - 工具输出沙箱化思路
