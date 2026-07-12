const express = require("express");
const cors = require("cors");
const http = require("http");
const path = require("path");
const { WebSocketServer } = require("ws");
const { FindingsStore } = require("./findings-store");
const { CommandQueue } = require("./command-queue");
const { SessionHistory } = require("./session-history");
const { generateScript, validateFindings } = require("./script-generator");
const { translateChatToAction } = require("./chat-ai");

const PORT = process.env.PORT || 3847;
const GG_STALE_MS = 15000;

const app = express();
app.use(cors());
app.use(express.json({ limit: "4mb" }));
app.use(express.static(path.join(__dirname, "../web")));

const server = http.createServer(app);
const wss = new WebSocketServer({ server });

const findingsStore = new FindingsStore();
const commandQueue = new CommandQueue();
const sessionHistory = new SessionHistory();

const state = {
  status: "idle",
  mode: "idle",
  prompt: "",
  apiKey: "",
  provider: "openai",
  model: "gpt-4o-mini",
  game: "",
  scriptStyle: "simple_toggle",
  serverUrl: `http://127.0.0.1:${PORT}`,
  startedAt: null,
  stoppedAt: null,
  lastGgPing: null,
  resultsCount: 0,
  currentAction: null,
  foundAddresses: [],
  logs: [],
  userAck: null,
  chat: [],
  exportedScript: null,
  sessionId: null,
};

const MAX_LOGS = 500;

function broadcast(message) {
  const payload = JSON.stringify(message);
  for (const client of wss.clients) {
    if (client.readyState === 1) client.send(payload);
  }
}

function pushLog(entry) {
  const log = {
    id: `${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
    timestamp: new Date().toISOString(),
    ...entry,
  };
  state.logs.unshift(log);
  if (state.logs.length > MAX_LOGS) state.logs.length = MAX_LOGS;
  broadcast({ type: "log", data: log });
  return log;
}

function pushChat(role, content, meta = {}) {
  const message = {
    id: `${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
    role,
    content,
    timestamp: new Date().toISOString(),
    ...meta,
  };
  state.chat.push(message);
  if (state.chat.length > 200) state.chat.shift();
  broadcast({ type: "chat", data: message });
  return message;
}

function publicState() {
  const ggConnected =
    state.lastGgPing &&
    Date.now() - new Date(state.lastGgPing).getTime() < GG_STALE_MS;

  return {
    status: state.status,
    mode: state.mode,
    prompt: state.prompt,
    provider: state.provider,
    model: state.model,
    game: state.game,
    scriptStyle: state.scriptStyle,
    serverUrl: state.serverUrl,
    startedAt: state.startedAt,
    stoppedAt: state.stoppedAt,
    lastGgPing: state.lastGgPing,
    ggConnected,
    resultsCount: state.resultsCount,
    currentAction: state.currentAction,
    foundAddresses: state.foundAddresses,
    findings: findingsStore.toJSON(),
    hasApiKey: Boolean(state.apiKey),
    userAck: state.userAck,
    logCount: state.logs.length,
    chatCount: state.chat.length,
    commands: commandQueue.snapshot(),
    exportedScriptReady: Boolean(state.exportedScript),
    sessionId: state.sessionId,
  };
}

function resetSession(keepLogs = false) {
  state.status = "idle";
  state.mode = "idle";
  state.prompt = "";
  state.apiKey = "";
  state.provider = "openai";
  state.model = "gpt-4o-mini";
  state.game = "";
  state.scriptStyle = "simple_toggle";
  state.startedAt = null;
  state.stoppedAt = null;
  state.resultsCount = 0;
  state.currentAction = null;
  state.foundAddresses = [];
  state.userAck = null;
  state.chat = [];
  state.exportedScript = null;
  state.sessionId = null;
  findingsStore.reset();
  commandQueue.reset();
  if (!keepLogs) state.logs = [];
}

wss.on("connection", (ws) => {
  ws.send(JSON.stringify({ type: "state", data: publicState() }));
  ws.send(JSON.stringify({ type: "logs", data: state.logs.slice(0, 100) }));
  ws.send(JSON.stringify({ type: "chat_history", data: state.chat }));
});

app.get("/api/health", (_req, res) => {
  res.json({ ok: true, port: PORT, version: "2.0.0" });
});

app.get("/api/state", (_req, res) => res.json(publicState()));

app.get("/api/logs", (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 100, MAX_LOGS);
  res.json(state.logs.slice(0, limit));
});

app.get("/api/session/findings", (_req, res) => {
  res.json(findingsStore.toJSON());
});

app.get("/api/history", (_req, res) => {
  res.json(sessionHistory.list());
});

app.get("/api/history/:id", (req, res) => {
  const item = sessionHistory.get(req.params.id);
  if (!item) return res.status(404).json({ error: "not found" });
  res.json(item);
});

app.post("/api/session/start", (req, res) => {
  const { prompt, apiKey, provider = "openai", model, game, scriptStyle } = req.body || {};
  if (!prompt?.trim()) return res.status(400).json({ error: "prompt is required" });
  if (!apiKey?.trim()) return res.status(400).json({ error: "apiKey is required" });

  resetSession(true);
  state.sessionId = `session_${Date.now()}`;
  state.prompt = String(prompt).trim();
  state.apiKey = String(apiKey).trim();
  state.provider = provider === "anthropic" ? "anthropic" : "openai";
  state.model =
    model ||
    (state.provider === "anthropic" ? "claude-3-5-haiku-latest" : "gpt-4o-mini");
  state.game = game?.trim() || "";
  state.scriptStyle = scriptStyle || "simple_toggle";
  findingsStore.setMeta({ game: state.game, scriptStyle: state.scriptStyle });
  state.status = "running";
  state.mode = "hunting";
  state.startedAt = new Date().toISOString();

  pushLog({
    level: "info",
    source: "web",
    message: "เริ่ม session ใหม่ — รอ GameGuardian เชื่อมต่อ",
    detail: { prompt: state.prompt, provider: state.provider, model: state.model },
  });
  pushChat("system", "เริ่ม session แล้ว รอ GG script เชื่อมต่อ");

  broadcast({ type: "state", data: publicState() });
  res.json(publicState());
});

app.post("/api/session/stop", (_req, res) => {
  state.status = "stopped";
  state.mode = "idle";
  state.stoppedAt = new Date().toISOString();
  pushLog({ level: "warn", source: "web", message: "ผู้ใช้สั่งหยุด session" });
  broadcast({ type: "state", data: publicState() });
  res.json(publicState());
});

app.post("/api/session/reset", (_req, res) => {
  resetSession(false);
  broadcast({ type: "state", data: publicState() });
  broadcast({ type: "logs", data: [] });
  broadcast({ type: "chat_history", data: [] });
  res.json(publicState());
});

app.post("/api/session/save", (_req, res) => {
  const item = sessionHistory.add({
    id: state.sessionId || `session_${Date.now()}`,
    prompt: state.prompt,
    game: state.game || findingsStore.game,
    scriptStyle: findingsStore.scriptStyle,
    findings: findingsStore.list(),
    exportedScript: state.exportedScript,
    createdAt: state.startedAt || new Date().toISOString(),
  });
  pushLog({ level: "info", source: "web", message: "บันทึก session ลง history แล้ว", detail: { id: item.id } });
  res.json(item);
});

app.get("/api/gg/session", (_req, res) => {
  state.lastGgPing = new Date().toISOString();
  res.json({
    status: state.status,
    mode: state.mode,
    prompt: state.prompt,
    apiKey: state.apiKey,
    provider: state.provider,
    model: state.model,
    game: state.game,
    scriptStyle: state.scriptStyle,
    userAck: state.userAck,
    stoppedAt: state.stoppedAt,
    findings: findingsStore.list(),
  });
});

app.post("/api/gg/findings", (req, res) => {
  const { findings, game, scriptStyle } = req.body || {};
  state.lastGgPing = new Date().toISOString();
  if (game) {
    state.game = game;
    findingsStore.setMeta({ game });
  }
  if (scriptStyle) {
    state.scriptStyle = scriptStyle;
    findingsStore.setMeta({ scriptStyle });
  }
  const saved = [];
  if (Array.isArray(findings)) {
    for (const item of findings) saved.push(findingsStore.upsert(item));
  } else if (req.body?.finding) {
    saved.push(findingsStore.upsert(req.body.finding));
  }
  broadcast({ type: "state", data: publicState() });
  res.json({ ok: true, findings: saved, ready: findingsStore.isReadyForExport() });
});

app.patch("/api/findings/:id", (req, res) => {
  const updated = findingsStore.update(req.params.id, req.body || {});
  if (!updated) return res.status(404).json({ error: "finding not found" });
  broadcast({ type: "state", data: publicState() });
  res.json(updated);
});

app.post("/api/gg/log", (req, res) => {
  const { level = "info", message, detail, source = "gg" } = req.body || {};
  if (!message) return res.status(400).json({ error: "message is required" });

  state.lastGgPing = new Date().toISOString();
  const log = pushLog({ level, source, message, detail });

  if (detail) {
    if (typeof detail.resultsCount === "number") state.resultsCount = detail.resultsCount;
    if (detail.currentAction) state.currentAction = detail.currentAction;
    if (Array.isArray(detail.foundAddresses)) state.foundAddresses = detail.foundAddresses;
    if (detail.status) state.status = detail.status;
    if (detail.mode) state.mode = detail.mode;
    if (Array.isArray(detail.findings)) {
      for (const item of detail.findings) findingsStore.upsert(item);
    }
  }

  broadcast({ type: "state", data: publicState() });
  res.json({ ok: true, id: log.id });
});

app.post("/api/gg/status", (req, res) => {
  const { status, mode, resultsCount, currentAction, foundAddresses } = req.body || {};
  state.lastGgPing = new Date().toISOString();
  if (status) state.status = status;
  if (mode) state.mode = mode;
  if (typeof resultsCount === "number") state.resultsCount = resultsCount;
  if (currentAction) state.currentAction = currentAction;
  if (Array.isArray(foundAddresses)) state.foundAddresses = foundAddresses;
  broadcast({ type: "state", data: publicState() });
  res.json({ ok: true });
});

app.post("/api/user/ack", (req, res) => {
  const { message = "done" } = req.body || {};
  state.userAck = { message, at: new Date().toISOString() };
  pushLog({
    level: "info",
    source: "web",
    message: "ผู้ใช้ยืนยันขั้นตอนในเกมแล้ว",
    detail: { ack: state.userAck },
  });
  broadcast({ type: "state", data: publicState() });
  res.json({ ok: true });
});

app.get("/api/gg/user-ack", (_req, res) => {
  const ack = state.userAck;
  state.userAck = null;
  res.json({ ack });
});

app.post("/api/commands", (req, res) => {
  const { type, target, payload, source = "web" } = req.body || {};
  if (!type) return res.status(400).json({ error: "type is required" });
  const command = commandQueue.enqueue({ type, target, payload, source });
  pushLog({
    level: "info",
    source: "web",
    message: `ส่งคำสั่ง ${type} ไปยัง GG`,
    detail: { command },
  });
  broadcast({ type: "state", data: publicState() });
  broadcast({ type: "command", data: command });
  res.json(command);
});

app.get("/api/gg/commands/next", (_req, res) => {
  state.lastGgPing = new Date().toISOString();
  const command = commandQueue.next();
  res.json({ command });
});

app.post("/api/gg/commands/result", (req, res) => {
  const { command_id, ok, message, data } = req.body || {};
  if (!command_id) return res.status(400).json({ error: "command_id is required" });
  state.lastGgPing = new Date().toISOString();
  const result = commandQueue.complete(command_id, { ok, message, data });

  pushLog({
    level: ok ? "success" : "warn",
    source: "gg",
    message: message || "คำสั่งเสร็จสิ้น",
    detail: { result },
  });

  if (data?.finding) findingsStore.upsert(data.finding);
  if (data?.findings) {
    for (const item of data.findings) findingsStore.upsert(item);
  }

  pushChat("system", message || "คำสั่ง GG เสร็จแล้ว", { command_id, data });
  broadcast({ type: "command_result", data: result });
  broadcast({ type: "state", data: publicState() });
  res.json({ ok: true, result });
});

app.get("/api/commands/:id/result", (req, res) => {
  const result = commandQueue.getResult(req.params.id);
  if (!result) return res.status(404).json({ error: "not found" });
  res.json(result);
});

app.get("/api/chat", (_req, res) => {
  res.json(state.chat);
});

app.post("/api/chat", async (req, res) => {
  const { message } = req.body || {};
  if (!message?.trim()) return res.status(400).json({ error: "message is required" });

  pushChat("user", message.trim());

  if (!state.apiKey) {
    const reply = "ยังไม่มี API key ใน session กรุณาเริ่ม session ใหม่";
    pushChat("assistant", reply);
    return res.json({ ok: true, reply });
  }

  try {
    const action = await translateChatToAction({
      provider: state.provider,
      apiKey: state.apiKey,
      model: state.model,
      message: message.trim(),
      findings: findingsStore.list(),
      sessionPrompt: state.prompt,
    });

    if (action.action === "command") {
      const command = commandQueue.enqueue({
        type: action.type,
        target: action.target,
        payload: action.payload || {},
        source: "chat",
      });
      const reply = `ส่งคำสั่ง ${action.type} ไปยัง GG แล้ว`;
      pushChat("assistant", reply, { command });
      broadcast({ type: "command", data: command });
      broadcast({ type: "state", data: publicState() });
      return res.json({ ok: true, reply, command, action });
    }

    const reply = action.message || "รับทราบครับ";
    pushChat("assistant", reply);
    return res.json({ ok: true, reply, action });
  } catch (error) {
    const reply = `เรียก AI ไม่สำเร็จ: ${error.message}`;
    pushChat("assistant", reply);
    return res.status(500).json({ error: error.message });
  }
});

app.post("/api/script/generate", (req, res) => {
  const { scriptStyle, game } = req.body || {};
  const findings = findingsStore.list();
  const issues = validateFindings(findings);
  if (issues.length) return res.status(400).json({ error: "findings not ready", issues });

  const style = scriptStyle || findingsStore.scriptStyle || state.scriptStyle;
  const script = generateScript({
    game: game || findingsStore.game || state.game || "Game Helper",
    scriptStyle: style,
    findings,
  });

  state.exportedScript = script;
  findingsStore.setMeta({ scriptStyle: style });
  state.scriptStyle = style;

  pushLog({
    level: "success",
    source: "web",
    message: "สร้างสคริปต์ GG สำเร็จ",
    detail: { scriptStyle: style, length: script.length },
  });
  pushChat("system", `สร้างสคริปต์แบบ ${style} พร้อม export แล้ว`);

  broadcast({ type: "state", data: publicState() });
  broadcast({ type: "script", data: { script, scriptStyle: style } });
  res.json({ script, scriptStyle: style, findings });
});

app.get("/api/script/preview", (_req, res) => {
  if (!state.exportedScript) {
    return res.status(404).json({ error: "no generated script yet" });
  }
  res.json({
    script: state.exportedScript,
    scriptStyle: state.scriptStyle,
    findings: findingsStore.list(),
  });
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`GG AI Bridge v2 running at http://127.0.0.1:${PORT}`);
});
