#!/usr/bin/env bash
# CLAUDE.md 无损压缩脚本
# 用法: bash compress-claudemd.sh <path-to-CLAUDE.md>
#
# 压缩策略:
# 1. 合并连续空行为单个空行
# 2. 移除行尾空白
# 3. 压缩重复分隔线
# 4. 移除纯装饰性注释（保留指令性内容）
# 5. 保留: 代码块、URL、文件路径、配置项

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "用法: $0 <path-to-CLAUDE.md>"
    echo "      压缩 CLAUDE.md 文件，减少 token 消耗"
    echo "      原文件备份为 .original.md"
    exit 1
fi

INPUT="$1"

if [ ! -f "$INPUT" ]; then
    echo "错误: 文件不存在: $INPUT"
    exit 1
fi

BACKUP="${INPUT%.md}.original.md"
TEMP=$(mktemp)

# 备份原文件
cp "$INPUT" "$BACKUP"

# 统计原始大小
ORIG_LINES=$(wc -l < "$INPUT" | tr -d ' ')
ORIG_BYTES=$(wc -c < "$INPUT" | tr -d ' ')

# 压缩处理
cat "$INPUT" | \
    # 移除行尾空白
    sed 's/[[:space:]]*$//' | \
    # 合并连续空行为单个空行
    cat -s | \
    # 压缩多余的 --- 分隔线（连续出现时保留1个）
    sed '/^---$/{ N; /^---\n---$/d; }' | \
    # 移除纯装饰性注释行（如 <!-- ... -->）但保留有内容的
    sed '/^<!--[[:space:]]*$/d' | \
    # 移除行首行尾的多余空白（但保留代码块缩进）
    awk '
    BEGIN { in_code = 0 }
    /^```/ { in_code = !in_code }
    {
        if (in_code) {
            print
        } else {
            # 移除行尾空白，但保留行首缩进（用于列表等）
            sub(/[[:space:]]+$/, "")
            print
        }
    }
    ' > "$TEMP"

# 写回原文件
cp "$TEMP" "$INPUT"
rm -f "$TEMP"

# 统计压缩后大小
NEW_LINES=$(wc -l < "$INPUT" | tr -d ' ')
NEW_BYTES=$(wc -c < "$INPUT" | tr -d ' ')

# 计算压缩率
if [ "$ORIG_BYTES" -gt 0 ]; then
    SAVED=$((ORIG_BYTES - NEW_BYTES))
    PCT=$((SAVED * 100 / ORIG_BYTES))
else
    SAVED=0
    PCT=0
fi

echo "========================================"
echo "  CLAUDE.md 压缩完成"
echo "========================================"
echo ""
echo "  原始: ${ORIG_LINES} 行, ${ORIG_BYTES} bytes"
echo "  压缩: ${NEW_LINES} 行, ${NEW_BYTES} bytes"
echo "  节省: ${SAVED} bytes (${PCT}%)"
echo ""
echo "  备份: $BACKUP"
echo "  输出: $INPUT"
echo ""
echo "  提示: 压缩后请检查文件内容是否完整"
echo "        如需恢复: cp '$BACKUP' '$INPUT'"
