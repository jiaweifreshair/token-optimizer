#!/usr/bin/env node
/**
 * 增强版 PreCompact Hook - 压缩前捕获上下文快照
 *
 * 功能:
 * 1. 从 stdin 读取 session 事件数据
 * 2. 提取最近用户消息（去重）
 * 3. 提取代码片段
 * 4. 提取活跃文件路径
 * 5. 构建优先级快照写入 handoff 目录
 *
 * 借鉴: who96/claude-code-context-handoff
 */

const fs = require('fs');
const path = require('path');
const os = require('os');

/**
 * 解析 Agent 工作目录。
 * 是什么: Claude/Codex 通用的目录定位器。
 * 做什么: 优先读取环境变量，其次自动探测 ~/.codex，最后回退 ~/.claude。
 * 为什么: 让同一套 hook 在 Claude Code 和 Codex 中都可直接复用。
 */
function resolveAgentHome() {
    if (process.env.AGENT_HOME) return process.env.AGENT_HOME;
    if (process.env.CODEX_HOME) return process.env.CODEX_HOME;
    if (process.env.CLAUDE_DIR) return process.env.CLAUDE_DIR;

    const codexDir = path.join(os.homedir(), '.codex');
    if (fs.existsSync(codexDir)) return codexDir;
    return path.join(os.homedir(), '.claude');
}

// 配置
const AGENT_HOME = resolveAgentHome();
const MAX_USER_MESSAGES = parseInt(process.env.HANDOFF_MAX_USER_MESSAGES || '15', 10);
const MAX_ASSISTANT_CHARS = parseInt(process.env.HANDOFF_MAX_ASSISTANT_CHARS || '800', 10);
const DEDUP_THRESHOLD = parseFloat(process.env.HANDOFF_DEDUP_THRESHOLD || '0.85');
const HANDOFF_DIR = path.join(AGENT_HOME, 'handoff');
const SESSIONS_DIR = path.join(AGENT_HOME, 'sessions');

/** 确保目录存在 */
function ensureDir(dir) {
    if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
    }
}

/** 简单字符串相似度（Jaccard） */
function similarity(a, b) {
    if (!a || !b) return 0;
    const setA = new Set(a.toLowerCase().split(/\s+/));
    const setB = new Set(b.toLowerCase().split(/\s+/));
    const intersection = new Set([...setA].filter(x => setB.has(x)));
    const union = new Set([...setA, ...setB]);
    return union.size === 0 ? 0 : intersection.size / union.size;
}

/** 去重消息列表 */
function dedup(messages, threshold) {
    const result = [];
    for (const msg of messages) {
        const isDup = result.some(existing => similarity(existing, msg) >= threshold);
        if (!isDup) {
            result.push(msg);
        }
    }
    return result;
}

/** 判断是否为有意义的代码片段 */
function isUsefulCode(text) {
    if (!text || text.length < 20) return false;
    // 过滤纯命令输出、日志、空内容
    const junkPatterns = [
        /^[\s\d\-:.]+$/,           // 纯时间戳/数字
        /^(ok|done|success|error)/i, // 简单状态
        /^\s*$/,                     // 空白
        /^#\s/,                      // markdown 标题
    ];
    return !junkPatterns.some(p => p.test(text.trim()));
}

/** 从文本中提取文件路径 */
function extractPaths(text) {
    const pathRegex = /(?:\/[\w\-.]+)+(?:\.\w+)?/g;
    const matches = text.match(pathRegex) || [];
    return [...new Set(matches)].filter(p => {
        // 过滤明显非文件路径
        return !p.startsWith('/usr/') && !p.startsWith('/bin/') &&
               !p.startsWith('/etc/') && !p.startsWith('/tmp/') &&
               p.includes('.');
    });
}

/** 获取时间戳 */
function timestamp() {
    return new Date().toISOString().replace('T', ' ').split('.')[0];
}

async function main() {
    ensureDir(HANDOFF_DIR);

    // 读取 stdin（hook 输入数据）
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
        // 非 JSON 输入
    }

    const sessionId = hookData.session_id || process.env.CLAUDE_SESSION_ID || 'unknown';
    const cwd = hookData.cwd || process.cwd();

    // 从 transcript 或 hook 数据中提取信息
    const userMessages = [];
    const codeSnippets = [];
    const filePaths = new Set();

    // 尝试读取 session transcript
    const transcriptPatterns = [
        path.join(AGENT_HOME, 'projects', '**', sessionId, 'transcript.jsonl'),
    ];

    // 从 hookData 提取（如果有 messages 字段）
    if (hookData.messages && Array.isArray(hookData.messages)) {
        for (const msg of hookData.messages.slice(-30)) {
            if (msg.role === 'user' && msg.content) {
                const text = typeof msg.content === 'string' ? msg.content : JSON.stringify(msg.content);
                if (text.length > 5 && text.length < 2000) {
                    userMessages.push(text.substring(0, 500));
                }
            }
            if (msg.role === 'assistant' && msg.content) {
                const text = typeof msg.content === 'string' ? msg.content : JSON.stringify(msg.content);
                // 提取代码块
                const codeBlocks = text.match(/```[\s\S]*?```/g) || [];
                for (const block of codeBlocks.slice(-5)) {
                    if (isUsefulCode(block) && block.length < MAX_ASSISTANT_CHARS) {
                        codeSnippets.push(block.substring(0, MAX_ASSISTANT_CHARS));
                    }
                }
                // 提取文件路径
                extractPaths(text).forEach(p => filePaths.add(p));
            }
        }
    }

    // 从 hookData.tool_uses 提取文件路径
    if (hookData.tool_uses && Array.isArray(hookData.tool_uses)) {
        for (const tool of hookData.tool_uses) {
            const input = tool.input || tool.tool_input || {};
            if (input.file_path) filePaths.add(input.file_path);
            if (input.path) filePaths.add(input.path);
            if (input.command) {
                extractPaths(input.command).forEach(p => filePaths.add(p));
            }
        }
    }

    // 去重用户消息
    const dedupedMessages = dedup(userMessages, DEDUP_THRESHOLD).slice(-MAX_USER_MESSAGES);

    // 构建快照
    const snapshot = [];
    snapshot.push(`# Context Handoff Snapshot`);
    snapshot.push(`<!-- Generated: ${timestamp()} -->`);
    snapshot.push(`<!-- Session: ${sessionId} -->`);
    snapshot.push(`<!-- CWD: ${cwd} -->`);
    snapshot.push('');

    if (dedupedMessages.length > 0) {
        snapshot.push('## Recent User Messages');
        for (const msg of dedupedMessages) {
            snapshot.push(`- ${msg.substring(0, 200)}`);
        }
        snapshot.push('');
    }

    if (filePaths.size > 0) {
        snapshot.push('## Active Files');
        const sortedPaths = [...filePaths].slice(0, 20);
        for (const p of sortedPaths) {
            snapshot.push(`- ${p}`);
        }
        snapshot.push('');
    }

    if (codeSnippets.length > 0) {
        snapshot.push('## Recent Code Context');
        for (const snippet of codeSnippets.slice(-5)) {
            snapshot.push(snippet);
            snapshot.push('');
        }
    }

    const content = snapshot.join('\n');

    // 写入快照文件
    const snapshotFile = path.join(HANDOFF_DIR, `${sessionId}.md`);
    const latestFile = path.join(HANDOFF_DIR, 'latest-handoff.md');
    const metaFile = path.join(HANDOFF_DIR, 'latest-handoff.json');

    fs.writeFileSync(snapshotFile, content, 'utf8');
    fs.writeFileSync(latestFile, content, 'utf8');
    fs.writeFileSync(metaFile, JSON.stringify({
        session_id: sessionId,
        cwd: cwd,
        timestamp: new Date().toISOString(),
        user_messages: dedupedMessages.length,
        file_paths: filePaths.size,
        code_snippets: codeSnippets.length,
        snapshot_bytes: Buffer.byteLength(content, 'utf8'),
    }, null, 2), 'utf8');

    // 记录到压缩日志
    ensureDir(SESSIONS_DIR);
    const logFile = path.join(SESSIONS_DIR, 'compaction-log.txt');
    fs.appendFileSync(logFile,
        `[${timestamp()}] Snapshot saved: ${dedupedMessages.length} msgs, ` +
        `${filePaths.size} files, ${codeSnippets.length} code blocks, ` +
        `${Buffer.byteLength(content, 'utf8')} bytes\n`
    );

    console.error(`[PreCompact] Snapshot saved: ${dedupedMessages.length} msgs, ${filePaths.size} files, ${codeSnippets.length} code`);

    // 输出原始 stdin 数据（hook 要求）
    console.log(inputData);
    process.exit(0);
}

main().catch(err => {
    console.error('[PreCompact] Error:', err.message);
    process.exit(0); // 不阻塞
});
