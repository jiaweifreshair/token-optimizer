#!/usr/bin/env node
/**
 * 增强版 SessionStart Hook - 自动恢复上下文快照
 *
 * 功能:
 * 1. 检测 session 启动来源（startup/resume/compact/clear）
 * 2. 如果来自压缩/清除，自动恢复快照
 * 3. 验证 cwd 匹配和时间窗口
 * 4. 清理过期快照文件
 *
 * 借鉴: who96/claude-code-context-handoff
 */

const fs = require('fs');
const path = require('path');
const os = require('os');

/**
 * 解析 Agent 工作目录。
 * 是什么: Claude/Codex 通用目录解析函数。
 * 做什么: 优先读取显式目录变量，再按当前运行时的 session 环境变量选择 ~/.claude 或 ~/.codex，无法判断时保守回退 ~/.claude。
 * 为什么: 避免仅因 ~/.codex 存在就误判到 Codex，同时保留双运行时兼容性。
 */
function resolveAgentHome() {
    if (process.env.AGENT_HOME) return process.env.AGENT_HOME;
    if (process.env.CLAUDE_DIR) return process.env.CLAUDE_DIR;
    if (process.env.CODEX_HOME) return process.env.CODEX_HOME;
    if (process.env.CLAUDE_SESSION_ID) return path.join(os.homedir(), '.claude');
    if (process.env.CODEX_SESSION_ID) return path.join(os.homedir(), '.codex');
    return path.join(os.homedir(), '.claude');
}

// 配置
const AGENT_HOME = resolveAgentHome();
const MAX_AGE_SEC = parseInt(process.env.HANDOFF_MAX_AGE_SEC || '900', 10); // 15分钟
const HANDOFF_DIR = path.join(AGENT_HOME, 'handoff');
const CLEANUP_AGE_HOURS = 24;

/** 确保目录存在 */
function ensureDir(dir) {
    if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
    }
}

/** 获取文件年龄（秒） */
function fileAgeSec(filepath) {
    try {
        const stat = fs.statSync(filepath);
        return (Date.now() - stat.mtimeMs) / 1000;
    } catch (_e) {
        return Infinity;
    }
}

/** 清理过期快照 */
function cleanupOldSnapshots() {
    if (!fs.existsSync(HANDOFF_DIR)) return;

    const maxAgeMs = CLEANUP_AGE_HOURS * 60 * 60 * 1000;
    const now = Date.now();

    try {
        const files = fs.readdirSync(HANDOFF_DIR);
        for (const file of files) {
            if (file === 'latest-handoff.md' || file === 'latest-handoff.json') continue;
            const filepath = path.join(HANDOFF_DIR, file);
            try {
                const stat = fs.statSync(filepath);
                if (now - stat.mtimeMs > maxAgeMs) {
                    fs.unlinkSync(filepath);
                }
            } catch (_e) {
                // 忽略单个文件错误
            }
        }
    } catch (_e) {
        // 忽略目录读取错误
    }
}

async function main() {
    ensureDir(HANDOFF_DIR);

    // 读取 stdin
    let inputData = '';
    try {
        inputData = fs.readFileSync(0, 'utf8');
    } catch (_e) {
        // stdin 可能为空
    }

    let hookData = {};
    try {
        hookData = JSON.parse(inputData);
    } catch (_e) {
        // 非 JSON
    }

    const source = hookData.source || 'startup';
    const sessionId =
        hookData.session_id ||
        hookData.sessionId ||
        process.env.CLAUDE_SESSION_ID ||
        process.env.CODEX_SESSION_ID ||
        'unknown';
    const cwd = hookData.cwd || process.cwd();

    // 报告基本信息
    console.error(`[SessionStart] Source: ${source}, Session: ${sessionId.substring(0, 8)}...`);

    // 只在 compact 或 clear 后恢复上下文
    if (source === 'compact' || source === 'clear') {
        let snapshot = null;
        let snapshotSource = '';

        // 优先查找 session 级别快照
        const sessionSnapshot = path.join(HANDOFF_DIR, `${sessionId}.md`);
        if (fs.existsSync(sessionSnapshot) && fileAgeSec(sessionSnapshot) < MAX_AGE_SEC) {
            snapshot = fs.readFileSync(sessionSnapshot, 'utf8');
            snapshotSource = 'session-specific';
        }

        // 兜底: latest-handoff.md
        if (!snapshot) {
            const latestSnapshot = path.join(HANDOFF_DIR, 'latest-handoff.md');
            const latestMeta = path.join(HANDOFF_DIR, 'latest-handoff.json');

            if (fs.existsSync(latestSnapshot) && fileAgeSec(latestSnapshot) < MAX_AGE_SEC) {
                // 验证 cwd 匹配
                let cwdMatch = true;
                if (fs.existsSync(latestMeta)) {
                    try {
                        const meta = JSON.parse(fs.readFileSync(latestMeta, 'utf8'));
                        if (meta.cwd && meta.cwd !== cwd) {
                            cwdMatch = false;
                            console.error(`[SessionStart] CWD mismatch: snapshot=${meta.cwd}, current=${cwd}`);
                        }
                    } catch (_e) {
                        // 忽略
                    }
                }

                if (cwdMatch) {
                    snapshot = fs.readFileSync(latestSnapshot, 'utf8');
                    snapshotSource = 'latest-fallback';
                }
            }
        }

        if (snapshot) {
            // 通过 stderr 输出快照作为 additional context
            console.error(`[SessionStart] Restoring context from ${snapshotSource} (${Buffer.byteLength(snapshot, 'utf8')} bytes)`);
            console.error('--- CONTEXT HANDOFF START ---');
            console.error(snapshot);
            console.error('--- CONTEXT HANDOFF END ---');
        } else {
            console.error(`[SessionStart] No valid snapshot found for recovery (source: ${source})`);
        }
    }

    // 检查 learned skills
    const learnedDir = path.join(AGENT_HOME, 'learned-skills');
    if (fs.existsSync(learnedDir)) {
        try {
            const skills = fs.readdirSync(learnedDir).filter(f => f.endsWith('.md'));
            if (skills.length > 0) {
                console.error(`[SessionStart] ${skills.length} learned skill(s) available`);
            }
        } catch (_e) {
            // 忽略
        }
    }

    // 异步清理过期快照
    cleanupOldSnapshots();

    // 输出原始数据
    console.log(inputData);
    process.exit(0);
}

main().catch(err => {
    console.error('[SessionStart] Error:', err.message);
    process.exit(0);
});
