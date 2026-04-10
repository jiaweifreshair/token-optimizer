#!/usr/bin/env bash
# Token Optimizer 状态检查脚本

# 解析 Agent 工作目录。
# 是什么: Claude/Codex 通用目录解析函数。
# 做什么: 读取环境变量并自动探测本地目录，得到统一的状态检查根目录。
# 为什么: 让同一状态脚本同时适配 Claude 与 Codex，避免重复维护两套脚本。
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
HANDOFF_DIR="$AGENT_HOME/handoff"
HOOKS_DIR="$AGENT_HOME/scripts/hooks"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

check_ok()   { echo -e "  ${GREEN}[OK]${NC} $1"; }
check_warn() { echo -e "  ${YELLOW}[--]${NC} $1"; }
check_fail() { echo -e "  ${RED}[NO]${NC} $1"; }

echo "========================================"
echo "  Token Optimizer 状态检查"
echo "========================================"
echo ""
echo "Agent Home: $AGENT_HOME"
echo ""

# Layer 1: Caveman
echo "--- Layer 1: 输出压缩 (Caveman) ---"
caveman_found=false
if [ -d "$AGENT_HOME/skills/caveman" ]; then
    check_ok "Caveman skill 已安装 (skills/caveman)"
    caveman_found=true
fi
while IFS= read -r d; do
    if [ -d "$d" ]; then
        check_ok "Caveman 已通过 plugin 安装"
        caveman_found=true
        break
    fi
done < <(find "$AGENT_HOME/plugins" -maxdepth 3 -type d -name "caveman" 2>/dev/null)
if ! $caveman_found; then
    check_fail "Caveman 未安装"
    echo "         安装: npx skills add JuliusBrussee/caveman"
fi
echo ""

# Layer 2: Context-Mode
echo "--- Layer 2: AutoContext 上下文卫生 ---"
SETTINGS="$AGENT_HOME/settings.json"
if grep -q "UserPromptSubmit" "$SETTINGS" 2>/dev/null; then
    check_ok "AutoContext hook 已注册 (UserPromptSubmit)"
else
    check_fail "AutoContext hook 未注册"
fi
AC_SCRIPT="$AGENT_HOME/plugins/installed/auto-context/scripts/context_sense.py"
if [ -f "$AC_SCRIPT" ]; then
    check_ok "context_sense.py 脚本存在"
else
    check_fail "context_sense.py 不存在: $AC_SCRIPT"
fi
AC_SKILL="$AGENT_HOME/skills/auto-context/SKILL.md"
if [ -f "$AC_SKILL" ]; then
    check_ok "/auto-context 手动触发可用"
else
    check_warn "/auto-context skill 未安装"
fi
echo ""

# Layer 3: Context Handoff
echo "--- Layer 3: 上下文交接 (Context-Handoff) ---"

# 检查增强版 hooks
if [ -f "$HOOKS_DIR/pre-compact.js" ]; then
    if grep -q "HANDOFF_DIR\|handoff\|snapshot" "$HOOKS_DIR/pre-compact.js" 2>/dev/null; then
        check_ok "增强版 pre-compact.js 已部署"
    else
        check_warn "pre-compact.js 存在但为旧版（无快照功能）"
    fi
else
    check_fail "pre-compact.js 不存在"
fi

if [ -f "$HOOKS_DIR/session-start.js" ]; then
    if grep -q "HANDOFF_DIR\|handoff\|snapshot\|CONTEXT HANDOFF" "$HOOKS_DIR/session-start.js" 2>/dev/null; then
        check_ok "增强版 session-start.js 已部署"
    else
        check_warn "session-start.js 存在但为旧版（无恢复功能）"
    fi
else
    check_fail "session-start.js 不存在"
fi

if [ -f "$HOOKS_DIR/suggest-compact.js" ]; then
    check_ok "suggest-compact.js 已部署"
    if grep -q "COMPACT_THRESHOLD || '10'" "$HOOKS_DIR/suggest-compact.js" 2>/dev/null; then
        check_ok "suggest-compact 默认阈值为 10 次"
    else
        check_warn "suggest-compact 默认阈值不是 10（请检查 COMPACT_THRESHOLD）"
    fi
else
    check_fail "suggest-compact.js 不存在"
fi

# Handoff 目录
if [ -d "$HANDOFF_DIR" ]; then
    snapshot_count=$(find "$HANDOFF_DIR" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
    latest_size=0
    if [ -f "$HANDOFF_DIR/latest-handoff.md" ]; then
        latest_size=$(wc -c < "$HANDOFF_DIR/latest-handoff.md" | tr -d ' ')
    fi
    check_ok "Handoff 目录存在 ($snapshot_count 个快照, 最新 ${latest_size} bytes)"
else
    check_warn "Handoff 目录不存在（首次压缩后自动创建）"
fi
echo ""

# Settings.json hooks 验证
echo "--- Hooks 配置验证 ---"
SETTINGS="$AGENT_HOME/settings.json"
if [ -f "$SETTINGS" ]; then
    if grep -q '"PreCompact"' "$SETTINGS"; then
        check_ok "PreCompact hook 已配置"
    else
        check_fail "PreCompact hook 未配置"
    fi
    if grep -q '"SessionStart"' "$SETTINGS"; then
        check_ok "SessionStart hook 已配置"
    else
        check_fail "SessionStart hook 未配置"
    fi
    if grep -q 'suggest-compact' "$SETTINGS"; then
        check_ok "Strategic Compact 建议已配置"
    else
        check_warn "Strategic Compact 建议未配置"
    fi
else
    check_fail "settings.json 不存在"
fi
echo ""

echo "========================================"
echo "  检查完成"
echo "========================================"
