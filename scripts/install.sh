#!/usr/bin/env bash
# Token Optimizer 一键安装脚本
# 安装三层 Token 优化系统到 Claude Code / Codex

set -euo pipefail

# 解析 Agent 工作目录。
# 是什么: Claude/Codex 通用目录解析函数。
# 做什么: 按环境变量优先级和本地目录存在性定位工作目录。
# 为什么: 避免脚本硬编码单一运行时路径，确保同一安装脚本可跨环境复用。
resolve_agent_home() {
    if [ -n "${AGENT_HOME:-}" ]; then
        echo "${AGENT_HOME}"
        return
    fi
    if [ -n "${CODEX_HOME:-}" ]; then
        echo "${CODEX_HOME}"
        return
    fi
    if [ -n "${CLAUDE_DIR:-}" ]; then
        echo "${CLAUDE_DIR}"
        return
    fi
    if [ -d "$HOME/.codex" ]; then
        echo "$HOME/.codex"
        return
    fi
    echo "$HOME/.claude"
}

AGENT_HOME="$(resolve_agent_home)"
HOOKS_DIR="$AGENT_HOME/scripts/hooks"
HANDOFF_DIR="$AGENT_HOME/handoff"
SKILL_DIR="$AGENT_HOME/skills/token-optimizer"
BACKUP_DIR="$AGENT_HOME/scripts/hooks/backup-$(date +%Y%m%d%H%M%S)"
AUTO_CONTEXT_PLUGIN_DIR="$AGENT_HOME/plugins/installed/auto-context"
AUTO_CONTEXT_SCRIPT_DIR="$AUTO_CONTEXT_PLUGIN_DIR/scripts"
AUTO_CONTEXT_HOOKS_DIR="$AUTO_CONTEXT_PLUGIN_DIR/hooks"
AUTO_CONTEXT_META_DIR="$AUTO_CONTEXT_PLUGIN_DIR/.claude-plugin"
AUTO_CONTEXT_SKILL_DIR="$AGENT_HOME/skills/auto-context"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERR]${NC} $1"; }
log_info() { echo -e "  -> $1"; }

echo "============================================"
echo "  Token Optimizer - 三层优化系统安装"
echo "============================================"
echo ""

# Step 1: 创建必要目录
echo "--- Step 1: 创建目录结构 ---"
mkdir -p "$HOOKS_DIR" "$HANDOFF_DIR" "$BACKUP_DIR" \
    "$AUTO_CONTEXT_SCRIPT_DIR" "$AUTO_CONTEXT_HOOKS_DIR" "$AUTO_CONTEXT_META_DIR" "$AUTO_CONTEXT_SKILL_DIR"
log_ok "目录创建完成"
log_info "Agent Home: $AGENT_HOME"
log_info "Hooks: $HOOKS_DIR"
log_info "Handoff: $HANDOFF_DIR"
echo ""

# Step 2: 备份现有 hooks
echo "--- Step 2: 备份现有 hooks ---"
backup_count=0
for f in pre-compact.js session-start.js suggest-compact.js; do
    if [ -f "$HOOKS_DIR/$f" ]; then
        cp "$HOOKS_DIR/$f" "$BACKUP_DIR/$f"
        backup_count=$((backup_count + 1))
    fi
done
if [ -f "$AUTO_CONTEXT_SCRIPT_DIR/context_sense.py" ]; then
    cp "$AUTO_CONTEXT_SCRIPT_DIR/context_sense.py" "$BACKUP_DIR/context_sense.py"
    backup_count=$((backup_count + 1))
fi
if [ $backup_count -gt 0 ]; then
    log_ok "已备份 $backup_count 个文件到 $BACKUP_DIR"
else
    log_info "无需备份（文件不存在）"
fi
echo ""

# Step 3: 部署增强版 hooks
echo "--- Step 3: 部署增强版 hooks ---"

# 部署 pre-compact.js
cp "$SKILL_DIR/scripts/enhanced-pre-compact.js" "$HOOKS_DIR/pre-compact.js"
chmod +x "$HOOKS_DIR/pre-compact.js"
log_ok "pre-compact.js 已部署（上下文快照功能）"

# 部署 session-start.js
cp "$SKILL_DIR/scripts/enhanced-session-start.js" "$HOOKS_DIR/session-start.js"
chmod +x "$HOOKS_DIR/session-start.js"
log_ok "session-start.js 已部署（自动恢复功能）"

# 部署 suggest-compact.js
cp "$SKILL_DIR/scripts/suggest-compact.js" "$HOOKS_DIR/suggest-compact.js"
chmod +x "$HOOKS_DIR/suggest-compact.js"
log_ok "suggest-compact.js 已部署（10次工具调用建议 /compact）"
echo ""

# Step 4: 部署 AutoContext（lovstudio 规则迁移）
echo "--- Step 4: 部署 AutoContext (lovstudio) ---"
if [ -f "$SKILL_DIR/scripts/context_sense.py" ]; then
    cp "$SKILL_DIR/scripts/context_sense.py" "$AUTO_CONTEXT_SCRIPT_DIR/context_sense.py"
    chmod +x "$AUTO_CONTEXT_SCRIPT_DIR/context_sense.py"
    log_ok "context_sense.py 已部署"
else
    log_err "缺少 context_sense.py: $SKILL_DIR/scripts/context_sense.py"
fi

if [ -f "$SKILL_DIR/scripts/auto-context-SKILL.md" ]; then
    cp "$SKILL_DIR/scripts/auto-context-SKILL.md" "$AUTO_CONTEXT_SKILL_DIR/SKILL.md"
    log_ok "/auto-context skill 已部署"
else
    log_err "缺少 auto-context-SKILL.md: $SKILL_DIR/scripts/auto-context-SKILL.md"
fi

cat > "$AUTO_CONTEXT_HOOKS_DIR/hooks.json" <<EOF
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$AUTO_CONTEXT_SCRIPT_DIR/context_sense.py"
          }
        ]
      }
    ]
  }
}
EOF
log_ok "auto-context hooks.json 已生成"

cat > "$AUTO_CONTEXT_META_DIR/plugin.json" <<EOF
{
  "name": "auto-context",
  "version": "1.0.0",
  "description": "AutoContext hook and skill migrated from lovstudio rules",
  "author": { "name": "lovstudio (migrated by token-optimizer)" },
  "license": "MIT"
}
EOF
log_ok "auto-context plugin.json 已生成"
echo ""

# Step 5: 检查 caveman skill
echo "--- Step 5: 检查 Caveman Skill ---"
if [ -d "$AGENT_HOME/skills/caveman" ] || [ -f "$AGENT_HOME/skills/caveman/SKILL.md" ]; then
    log_ok "caveman skill 已安装"
else
    # 尝试检查 plugin 安装
    caveman_found=false
    for d in "$AGENT_HOME"/plugins/*/skills/caveman; do
        if [ -d "$d" ]; then
            caveman_found=true
            break
        fi
    done
    if $caveman_found; then
        log_ok "caveman 已通过 plugin 安装"
    else
        log_warn "caveman 未安装"
        log_info "请执行: npx skills add JuliusBrussee/caveman"
        log_info "或在 Claude Code / Codex 中: /plugin install caveman@caveman"
    fi
fi
echo ""

# Step 6: 验证 settings.json hooks 配置
echo "--- Step 6: 验证 hooks 配置 ---"
SETTINGS="$AGENT_HOME/settings.json"
if [ -f "$SETTINGS" ]; then
    # 检查 PreCompact hook
    if grep -q "pre-compact.js" "$SETTINGS"; then
        log_ok "PreCompact hook 已配置"
    else
        log_warn "PreCompact hook 未在 settings.json 中配置"
        log_info "请确保 settings.json 包含 PreCompact hook 指向 pre-compact.js"
    fi

    # 检查 SessionStart hook
    if grep -q "session-start.js" "$SETTINGS"; then
        log_ok "SessionStart hook 已配置"
    else
        log_warn "SessionStart hook 未在 settings.json 中配置"
    fi

    # 检查 PreToolUse compact 建议 hook
    if grep -q "suggest-compact.js" "$SETTINGS"; then
        log_ok "PreToolUse suggest-compact hook 已配置"
    else
        log_warn "suggest-compact hook 未在 settings.json 中配置"
    fi

    # 检查 UserPromptSubmit auto-context hook
    if grep -q "UserPromptSubmit" "$SETTINGS" && grep -q "context_sense.py" "$SETTINGS"; then
        log_ok "UserPromptSubmit auto-context hook 已配置"
    else
        log_warn "auto-context hook 未在 settings.json 中配置"
    fi
else
    log_err "settings.json 不存在: $SETTINGS"
fi
echo ""

# Step 7: 确保 lib/utils.js 存在
echo "--- Step 7: 检查依赖 ---"
LIB_DIR="$AGENT_HOME/scripts/lib"
if [ -f "$LIB_DIR/utils.js" ]; then
    log_ok "lib/utils.js 存在"
else
    log_warn "lib/utils.js 不存在，增强 hooks 使用独立实现，无外部依赖"
fi
echo ""

echo "============================================"
echo "  安装完成!"
echo "============================================"
echo ""
echo "已安装组件:"
echo "  [Layer 2] AutoContext context_sense.py (lovstudio 规则迁移)"
echo "  [Layer 2] /auto-context skill          (手动检查)"
echo "  [Layer 3] 增强版 pre-compact.js  (上下文快照)"
echo "  [Layer 3] 增强版 session-start.js (自动恢复)"
echo "  [Layer 3] suggest-compact.js      (10次工具调用建议 /compact)"
echo ""
echo "待安装组件 (需在 Claude Code / Codex 中手动执行):"
echo "  [Layer 1] caveman: npx skills add JuliusBrussee/caveman"
echo "  [可选] context-mode: /plugin marketplace add mksglu/context-mode"
echo ""
echo "验证安装: bash $SKILL_DIR/scripts/status.sh"
echo ""
