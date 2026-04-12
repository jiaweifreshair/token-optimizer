# Token Optimizer

Claude Code / Codex 三层 Token 优化系统。自动压缩输出、自动检测上下文污染、自动交接压缩快照 - 用户零感知。

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
    |                        读 transcript 行数/体积（lovstudio 规则）
    |                        超阈值 -> 注入 <auto-context> 提示
    |                        Agent 自判断: 继续 / /fork / /btw
    v
Agent 执行任务
    |
    v
[PreToolUse hook] ─── suggest-compact.js
    |                  10次工具调用后建议 /compact
    v
[Edit/Write 完成]
    |
    v
[自动压缩触发]
    |
    v
[PreCompact hook] ─── enhanced-pre-compact.js
    |                   提取: 15条用户消息 + 代码片段 + 文件路径
    |                   写入: <AGENT_HOME>/handoff/<session>.md (<=2KB)
    v
[SessionStart hook] ─── enhanced-session-start.js
                         source=compact -> 恢复快照
                         验证: cwd匹配 + 15分钟窗口
                         注入: 快照作为 additional context
```

## 文件结构

```
<AGENT_HOME>/skills/token-optimizer/
├── SKILL.md                           # Skill 定义（/token-optimizer 入口）
├── README.md                          # 本文件
└── scripts/
    ├── install.sh                     # 一键安装脚本
    ├── status.sh                      # 状态诊断
    ├── compress-claudemd.sh           # CLAUDE.md 无损压缩
    ├── context_sense.py               # AutoContext hook（lovstudio 规则迁移）
    ├── auto-context-SKILL.md          # /auto-context skill 模板
    ├── enhanced-pre-compact.js        # PreCompact hook（上下文快照）
    ├── enhanced-session-start.js      # SessionStart hook（自动恢复）
    └── suggest-compact.js             # PreToolUse hook（10次建议 /compact）

<AGENT_HOME>/plugins/installed/auto-context/
├── .claude-plugin/plugin.json         # Plugin 清单
├── hooks/hooks.json                   # UserPromptSubmit hook 定义
├── scripts/context_sense.py           # 上下文卫生检测脚本（lovstudio 规则迁移）
└── skills/auto-context/SKILL.md       # /auto-context 手动触发

<AGENT_HOME>/skills/caveman/           # Caveman 输出压缩 skill
<AGENT_HOME>/skills/caveman-compress/  # CLAUDE.md 压缩 skill
<AGENT_HOME>/skills/auto-context/      # AutoContext 手动触发 skill
<AGENT_HOME>/handoff/                  # 上下文快照存储
```

## Hooks 注册

要让 Token Optimizer 在 Claude 本地环境中自动生效，除了运行安装脚本，还需要在 `~/.claude/settings.json` 顶层注册 hooks。

在 `<AGENT_HOME>/settings.json` 中注册以下 hooks：

| Hook 事件 | 脚本 | 功能 |
|-----------|------|------|
| `UserPromptSubmit` | `context_sense.py` | 上下文卫生自动检测 |
| `PreCompact` | `enhanced-pre-compact.js` | 压缩前保存上下文快照 |
| `SessionStart` | `enhanced-session-start.js` | 压缩后恢复快照 |
| `PreToolUse` (Edit/Write) | `suggest-compact.js` | 工具调用计数，建议 /compact |

Claude 本地环境可直接使用下面的配置片段：

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/apus/.claude/plugins/installed/auto-context/scripts/context_sense.py"
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/apus/.claude/skills/token-optimizer/scripts/enhanced-pre-compact.js"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/apus/.claude/skills/token-optimizer/scripts/enhanced-session-start.js"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/apus/.claude/skills/token-optimizer/scripts/suggest-compact.js"
          }
        ]
      }
    ]
  }
}
```

说明：
- `UserPromptSubmit` 使用的是安装后部署到 `~/.claude/plugins/installed/auto-context/scripts/context_sense.py` 的脚本
- 其余 3 个 hook 使用的是 `~/.claude/skills/token-optimizer/scripts/` 下的脚本
- `PreToolUse` 只建议匹配 `Edit|Write`，避免扩大触发范围

## 使用

完成安装脚本和 `~/.claude/settings.json` hooks 配置后，重启或新开一个 Claude session，所有自动化组件才会自动生效。

安装后会自动部署 Layer 2（AutoContext）到：
- `<AGENT_HOME>/plugins/installed/auto-context/scripts/context_sense.py`
- `<AGENT_HOME>/skills/auto-context/SKILL.md`

建议先运行下面的命令确认配置完成：

```bash
bash ~/.claude/skills/token-optimizer/scripts/status.sh
```

若配置正确，至少应看到这些检查项为绿色：
- `AutoContext hook 已注册`
- `PreCompact hook 已配置`
- `SessionStart hook 已配置`
- `Strategic Compact 建议已配置`

如果仍有红项，通常只应剩下 Caveman 未安装这一类与 hooks 配置无关的提示。

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
/token-optimizer compress <AGENT_HOME>/CLAUDE.md
```

## 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `HANDOFF_MAX_USER_MESSAGES` | `15` | 快照中保留的最大用户消息数 |
| `HANDOFF_DEDUP_THRESHOLD` | `0.85` | 消息去重相似度阈值 |
| `HANDOFF_MAX_AGE_SEC` | `900` | 快照恢复最大时间窗口（秒） |
| `AUTO_CONTEXT_MESSAGE_THRESHOLD` | `40` | AutoContext 普通提醒阈值（消息数） |
| `AUTO_CONTEXT_TRANSCRIPT_BYTES_STRONG` | `153600` | AutoContext 强提醒阈值（bytes，默认 150KB） |
| `AUTO_CONTEXT_COOLDOWN_MESSAGES` | `10` | AutoContext 提醒冷却（消息条数） |
| `AGENT_HOME` | 自动识别 | Agent 工作目录（优先 `AGENT_HOME/CLAUDE_DIR/CODEX_HOME`，再按 `CLAUDE_SESSION_ID/CODEX_SESSION_ID` 判断运行时，最后保守回退 `~/.claude`） |
| `COMPACT_THRESHOLD` | `10` | 建议 /compact 的工具调用阈值 |

## 设计理念

借鉴 [AutoContext](https://mp.weixin.qq.com/s/QeKkh0-vBEB3t9reYWKjPQ) (lovstudio) 的 Plugin + Skill 双层架构：

- **Plugin (Hook)** 负责自动触发 - 用户不需要记得什么时候该检查上下文
- **Skill** 负责手动触发 - 用户主动检查时获得完整报告
- **脚本做"笨"的量化检测** - 行数/体积/冷却
- **Agent 做"聪明"的定性判断** - 信噪比/话题相关度

三层决策框架 (Sense -> Decide -> Evolve)：
1. **Sense** - 量化检测上下文负载（行数、体积、工具调用次数）
2. **Decide** - Agent 自主判断：继续 / 压缩 / fork / 全新 session
3. **Evolve** - 项目配置（CLAUDE.md）随使用自动沉淀经验

## 致谢

- [lovstudio/skills](https://github.com/lovstudio/skills) - AutoContext 原始实现
- [lovstudio/claude-code-plugin](https://github.com/lovstudio/claude-code-plugin) - AutoContext 自动触发架构参考
- [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) - Caveman 输出压缩
- [who96/claude-code-context-handoff](https://github.com/who96/claude-code-context-handoff) - 上下文交接机制
- [mksglu/context-mode](https://github.com/mksglu/context-mode) - 工具输出沙箱化思路
