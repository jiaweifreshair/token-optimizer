#!/usr/bin/env node
/**
 * Strategic Compact 建议 Hook（PreToolUse）
 *
 * 功能:
 * 1. 统计当前会话的工具调用次数
 * 2. 达到阈值后通过 stderr 提示执行 /compact
 * 3. 持久化计数状态，避免会话中断后丢失
 *
 * 兼容: Claude Code / Codex
 */

const fs = require('fs');
const path = require('path');
const os = require('os');

/**
 * 解析 Agent 工作目录。
 * 是什么: 多运行时统一目录定位函数。
 * 做什么: 优先读取显式目录变量，再按当前运行时的 session 环境变量选择 ~/.claude 或 ~/.codex，无法判断时保守回退 ~/.claude。
 * 为什么: 避免仅因 ~/.codex 存在就误判到 Codex，同时保留双运行时兼容。
 */
function resolveAgentHome() {
    if (process.env.AGENT_HOME) return process.env.AGENT_HOME;
    if (process.env.CLAUDE_DIR) return process.env.CLAUDE_DIR;
    if (process.env.CODEX_HOME) return process.env.CODEX_HOME;
    if (process.env.CLAUDE_SESSION_ID) return path.join(os.homedir(), '.claude');
    if (process.env.CODEX_SESSION_ID) return path.join(os.homedir(), '.codex');
    return path.join(os.homedir(), '.claude');
}

// 配置项（默认 10 次触发；之后每 10 次再次提醒）
const AGENT_HOME = resolveAgentHome();
const COMPACT_THRESHOLD = parseInt(process.env.COMPACT_THRESHOLD || '10', 10);
const COMPACT_REMIND_INTERVAL = parseInt(
    process.env.COMPACT_REMIND_INTERVAL || process.env.COMPACT_REMIND_EVERY || String(COMPACT_THRESHOLD),
    10
);
const MAX_SESSION_TRACK = parseInt(process.env.COMPACT_MAX_SESSION_TRACK || '200', 10);
const STATE_FILE = path.join(AGENT_HOME, 'sessions', 'suggest-compact-state.json');

/** 创建目录（如果不存在） */
function ensureDir(dir) {
    if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
    }
}

/** 读取持久化状态 */
function loadState() {
    try {
        if (!fs.existsSync(STATE_FILE)) {
            return { sessions: {}, updated_at: new Date().toISOString() };
        }
        const raw = fs.readFileSync(STATE_FILE, 'utf8');
        const parsed = JSON.parse(raw);
        if (!parsed.sessions || typeof parsed.sessions !== 'object') {
            return { sessions: {}, updated_at: new Date().toISOString() };
        }
        return parsed;
    } catch (_e) {
        return { sessions: {}, updated_at: new Date().toISOString() };
    }
}

/** 持久化状态 */
function saveState(state) {
    ensureDir(path.dirname(STATE_FILE));
    fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2), 'utf8');
}

/**
 * 裁剪状态体积。
 * 是什么: 会话状态上限控制。
 * 做什么: 仅保留最近活跃的 N 个会话计数。
 * 为什么: 防止长期运行后状态文件无限增长。
 */
function pruneState(state) {
    const entries = Object.entries(state.sessions || {});
    if (entries.length <= MAX_SESSION_TRACK) return;

    entries.sort((a, b) => {
        const timeA = Date.parse(a[1].updated_at || 0) || 0;
        const timeB = Date.parse(b[1].updated_at || 0) || 0;
        return timeB - timeA;
    });

    const pruned = {};
    for (const [key, value] of entries.slice(0, MAX_SESSION_TRACK)) {
        pruned[key] = value;
    }
    state.sessions = pruned;
}

/**
 * 提取会话唯一键。
 * 是什么: 会话标识提取器。
 * 做什么: 从 hook payload 和环境变量中按优先级获取 session_id。
 * 为什么: 确保计数与具体会话绑定，避免多会话串扰。
 */
function resolveSessionId(hookData) {
    return (
        hookData.session_id ||
        hookData.sessionId ||
        process.env.CLAUDE_SESSION_ID ||
        process.env.CODEX_SESSION_ID ||
        'global'
    );
}

async function main() {
    let inputData = '';
    try {
        inputData = fs.readFileSync(0, 'utf8');
    } catch (_e) {
        // stdin 为空时不阻塞
    }

    let hookData = {};
    try {
        hookData = JSON.parse(inputData);
    } catch (_e) {
        // 非 JSON 输入时继续执行
    }

    const sessionId = resolveSessionId(hookData);
    const state = loadState();
    const now = new Date().toISOString();

    if (!state.sessions[sessionId]) {
        state.sessions[sessionId] = { count: 0, last_notified: 0, updated_at: now };
    }

    const entry = state.sessions[sessionId];
    entry.count += 1;
    entry.updated_at = now;

    let shouldNotify = false;
    if (entry.count >= COMPACT_THRESHOLD) {
        if (entry.last_notified === 0 && entry.count >= COMPACT_THRESHOLD) {
            shouldNotify = true;
        } else if (entry.count - entry.last_notified >= COMPACT_REMIND_INTERVAL) {
            shouldNotify = true;
        }
    }

    if (shouldNotify) {
        entry.last_notified = entry.count;
        console.error(
            `[SuggestCompact] 当前会话工具调用 ${entry.count} 次，建议执行 /compact ` +
            `(阈值=${COMPACT_THRESHOLD}, 间隔=${COMPACT_REMIND_INTERVAL})`
        );
    }

    state.updated_at = now;
    pruneState(state);
    saveState(state);

    // hook 约定：透传原始输入，避免影响后续流程
    console.log(inputData);
    process.exit(0);
}

main().catch(err => {
    console.error('[SuggestCompact] Error:', err.message);
    process.exit(0); // 建议类 hook 不应阻塞主流程
});
