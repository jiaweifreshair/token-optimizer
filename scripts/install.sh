#!/usr/bin/env bash
# Token Optimizer 一键安装脚本
# 安装三层 Token 优化系统到 Claude Code

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/scripts/hooks"
HANDOFF_DIR="$CLAUDE_DIR/handoff"
SKILL_DIR="$CLAUDE_DIR/skills/token-optimizer"
BACKUP_DIR="$CLAUDE_DIR/scripts/hooks/backup-$(date +%Y%m%d%H%M%S)"

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
mkdir -p "$HOOKS_DIR" "$HANDOFF_DIR" "$BACKUP_DIR"
log_ok "目录创建完成"
log_info "Hooks: $HOOKS_DIR"
log_info "Handoff: $HANDOFF_DIR"
echo ""

# Step 2: 备份现有 hooks
echo "--- Step 2: 备份现有 hooks ---"
backup_count=0
for f in pre-compact.js session-start.js; do
    if [ -f "$HOOKS_DIR/$f" ]; then
        cp "$HOOKS_DIR/$f" "$BACKUP_DIR/$f"
        backup_count=$((backup_count + 1))
    fi
done
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
log_ok "pre-compact.js 已部署（上下文快照功能）"

# 部署 session-start.js
cp "$SKILL_DIR/scripts/enhanced-session-start.js" "$HOOKS_DIR/session-start.js"
log_ok "session-start.js 已部署（自动恢复功能）"
echo ""

# Step 4: 检查 context-mode plugin
echo "--- Step 4: 检查 Context-Mode Plugin ---"
if command -v context-mode &>/dev/null; then
    log_ok "context-mode 已安装"
else
    log_warn "context-mode 未安装"
    log_info "请在 Claude Code 中执行:"
    log_info "  /plugin marketplace add mksglu/context-mode"
    log_info "  /plugin install context-mode@context-mode"
fi
echo ""

# Step 5: 检查 caveman skill
echo "--- Step 5: 检查 Caveman Skill ---"
if [ -d "$CLAUDE_DIR/skills/caveman" ] || [ -f "$CLAUDE_DIR/skills/caveman/SKILL.md" ]; then
    log_ok "caveman skill 已安装"
else
    # 尝试检查 plugin 安装
    caveman_found=false
    for d in "$CLAUDE_DIR"/plugins/*/skills/caveman; do
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
        log_info "或在 Claude Code 中: /plugin install caveman@caveman"
    fi
fi
echo ""

# Step 6: 验证 settings.json hooks 配置
echo "--- Step 6: 验证 hooks 配置 ---"
SETTINGS="$CLAUDE_DIR/settings.json"
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
else
    log_err "settings.json 不存在: $SETTINGS"
fi
echo ""

# Step 7: 确保 lib/utils.js 存在
echo "--- Step 7: 检查依赖 ---"
LIB_DIR="$CLAUDE_DIR/scripts/lib"
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
echo "  [Layer 3] 增强版 pre-compact.js  (上下文快照)"
echo "  [Layer 3] 增强版 session-start.js (自动恢复)"
echo ""
echo "待安装组件 (需在 Claude Code 中手动执行):"
echo "  [Layer 1] caveman: npx skills add JuliusBrussee/caveman"
echo "  [Layer 2] context-mode: /plugin marketplace add mksglu/context-mode"
echo ""
echo "验证安装: bash $SKILL_DIR/scripts/status.sh"
echo ""
