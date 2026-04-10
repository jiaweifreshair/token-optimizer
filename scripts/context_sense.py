#!/usr/bin/env python3
"""
AutoContext UserPromptSubmit Hook（迁移自 lovstudio:auto-context 规则）

规则来源:
- 对话条目超过 40 条时提醒一次
- transcript 体积超过 150KB 时强提醒
- 冷却窗口默认 10 条消息，避免重复刷屏

说明:
- 本脚本只做量化检测，不做业务决策
- 通过 stderr 注入 <auto-context> 轻量提示
- 通过 stdout 原样透传 hook 输入，不阻塞主流程
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Dict


def resolve_agent_home() -> Path:
    """
    是什么: Claude/Codex 通用目录解析函数。
    做什么: 优先读取 AGENT_HOME/CODEX_HOME/CLAUDE_DIR，未设置时探测 ~/.codex，最后回退 ~/.claude。
    为什么: 让同一脚本可复用于 Claude Code 与 Codex 环境。
    """
    env = os.environ
    for key in ("AGENT_HOME", "CODEX_HOME", "CLAUDE_DIR"):
        value = env.get(key)
        if value:
            return Path(value).expanduser()

    codex_dir = Path.home() / ".codex"
    if codex_dir.exists():
        return codex_dir
    return Path.home() / ".claude"


AGENT_HOME = resolve_agent_home()
STATE_FILE = AGENT_HOME / "plugins" / "installed" / "auto-context" / ".state" / "context-sense-state.json"

MESSAGE_THRESHOLD = int(os.environ.get("AUTO_CONTEXT_MESSAGE_THRESHOLD", "40"))
TRANSCRIPT_BYTES_STRONG = int(os.environ.get("AUTO_CONTEXT_TRANSCRIPT_BYTES_STRONG", str(150 * 1024)))
COOLDOWN_MESSAGES = int(os.environ.get("AUTO_CONTEXT_COOLDOWN_MESSAGES", "10"))
COOLDOWN_SECONDS_FALLBACK = int(os.environ.get("AUTO_CONTEXT_COOLDOWN_SECONDS", "600"))


def load_state() -> Dict[str, Any]:
    """
    是什么: AutoContext 的轻量状态读取器。
    做什么: 从磁盘恢复会话级冷却状态，读取失败时返回空状态。
    为什么: 避免每次 prompt 都重复提醒，控制干扰频率。
    """
    try:
        if not STATE_FILE.exists():
            return {"sessions": {}, "updated_at": 0}
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {"sessions": {}, "updated_at": 0}


def save_state(state: Dict[str, Any]) -> None:
    """
    是什么: 状态持久化函数。
    做什么: 将会话冷却信息写入本地文件。
    为什么: 保持跨请求连续性，减少重复告警。
    """
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")


def safe_int(value: Any) -> int:
    try:
        return int(value)
    except Exception:
        return 0


def parse_message_count(payload: Dict[str, Any]) -> int:
    """
    是什么: 消息数提取器。
    做什么: 优先从 messages 数组取长度，失败时回退常见计数字段。
    为什么: hook 输入结构可能随运行时版本变化，需要稳健兼容。
    """
    messages = payload.get("messages")
    if isinstance(messages, list):
        return len(messages)

    for key in ("message_count", "messages_count", "turn_count", "transcript_line_count"):
        value = payload.get(key)
        if value is not None:
            return safe_int(value)
    return 0


def parse_transcript_bytes(payload: Dict[str, Any]) -> int:
    """
    是什么: transcript 体积提取器。
    做什么: 读取常见大小字段并统一成 bytes。
    为什么: 150KB 强提醒依赖体积指标，需要跨字段兼容。
    """
    for key in ("transcript_bytes", "transcript_size_bytes", "transcript_size"):
        value = payload.get(key)
        if value is not None:
            return safe_int(value)
    return 0


def resolve_session_id(payload: Dict[str, Any]) -> str:
    return (
        str(payload.get("session_id") or payload.get("sessionId") or "").strip()
        or os.environ.get("CODEX_SESSION_ID", "").strip()
        or os.environ.get("CLAUDE_SESSION_ID", "").strip()
        or "global"
    )


def should_emit(
    session_state: Dict[str, Any],
    message_count: int,
    transcript_bytes: int,
    now_ts: int,
) -> bool:
    """
    是什么: 提醒触发判定器。
    做什么: 按阈值 + 冷却规则决定是否输出 <auto-context>。
    为什么: 保证提醒有效但不过度打断正常对话。
    """
    hit_threshold = (message_count >= MESSAGE_THRESHOLD) or (transcript_bytes >= TRANSCRIPT_BYTES_STRONG)
    if not hit_threshold:
        return False

    last_message_count = safe_int(session_state.get("last_message_count"))
    last_emit_ts = safe_int(session_state.get("last_emit_ts"))

    if message_count > 0:
        return (message_count - last_message_count) >= COOLDOWN_MESSAGES
    return (now_ts - last_emit_ts) >= COOLDOWN_SECONDS_FALLBACK


def emit_reminder(message_count: int, transcript_bytes: int) -> None:
    kb = transcript_bytes // 1024 if transcript_bytes > 0 else 0
    lines = [
        "<auto-context>",
        "检测到上下文负载升高，请先判断当前任务与历史上下文是否仍相关。",
    ]
    if message_count > 0:
        lines.append(f"- 当前消息数: {message_count}（阈值: {MESSAGE_THRESHOLD}）")
    if kb > 0:
        lines.append(f"- transcript 体积: {kb}KB（强提醒阈值: {TRANSCRIPT_BYTES_STRONG // 1024}KB）")
    lines.append("若话题已切换，建议使用 /fork 或 /btw 保持上下文纯净。")
    lines.append("</auto-context>")
    sys.stderr.write("\n".join(lines) + "\n")


def main() -> int:
    raw = ""
    try:
        raw = sys.stdin.read()
    except Exception:
        raw = ""

    payload: Dict[str, Any] = {}
    if raw.strip():
        try:
            payload = json.loads(raw)
        except Exception:
            payload = {}

    now_ts = int(time.time())
    session_id = resolve_session_id(payload)
    message_count = parse_message_count(payload)
    transcript_bytes = parse_transcript_bytes(payload)

    state = load_state()
    sessions = state.setdefault("sessions", {})
    session_state = sessions.setdefault(session_id, {"last_message_count": 0, "last_emit_ts": 0})

    if should_emit(session_state, message_count, transcript_bytes, now_ts):
        emit_reminder(message_count, transcript_bytes)
        session_state["last_message_count"] = message_count
        session_state["last_emit_ts"] = now_ts
        state["updated_at"] = now_ts
        save_state(state)

    # 透传输入，保证 hook 链路兼容
    if raw:
        sys.stdout.write(raw)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # 不阻塞主流程
        sys.stderr.write(f"[auto-context] error: {exc}\n")
        raise SystemExit(0)
