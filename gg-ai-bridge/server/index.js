const express = require("express");
const cors = require("cors");
const http = require("http");
const path = require("path");
const { WebSocketServer } = require("ws");

const PORT = process.env.PORT || 3847;

const app = express();
app.use(cors());
app.use(express.json({ limit: "2mb" }));
app.use(express.static(path.join(__dirname, "../web")));

const server = http.createServer(app);
const wss = new WebSocketServer({ server });

const state = {
  status: "idle",
  prompt: "",
  apiKey: "",
  provider: "openai",
  model: "gpt-4o-mini",
  serverUrl: `http://127.0.0.1:${PORT}`,
  startedAt: null,
  stoppedAt: null,
  lastGgPing: null,
  resultsCount: 0,
  currentAction: null,
  foundAddresses: [],
  logs: [],
  userAck: null,
};

const MAX_LOGS = 500;

function broadcast(message) {
  const payload = JSON.stringify(message);
  for (const client of wss.clients) {
    if (client.readyState === 1) {
      client.send(payload);
    }
  }
}

function pushLog(entry) {
  const log = {
    id: Date.now() + Math.random(),
    timestamp: new Date().toISOString(),
    ...entry,
  };
  state.logs.unshift(log);
  if (state.logs.length > MAX_LOGS) {
    state.logs.length = MAX_LOGS;
  }
  broadcast({ type: "log", data: log });
  return log;
}

function publicState() {
  return {
    status: state.status,
    prompt: state.prompt,
    provider: state.provider,
    model: state.model,
    serverUrl: state.serverUrl,
    startedAt: state.startedAt,
    stoppedAt: state.stoppedAt,
    lastGgPing: state.lastGgPing,
    resultsCount: state.resultsCount,
    currentAction: state.currentAction,
    foundAddresses: state.foundAddresses,
    hasApiKey: Boolean(state.apiKey),
    userAck: state.userAck,
    logCount: state.logs.length,
  };
}

function resetSession(keepLogs = false) {
  state.status = "idle";
  state.prompt = "";
  state.apiKey = "";
  state.provider = "openai";
  state.model = "gpt-4o-mini";
  state.startedAt = null;
  state.stoppedAt = null;
  state.resultsCount = 0;
  state.currentAction = null;
  state.foundAddresses = [];
  state.userAck = null;
  if (!keepLogs) {
    state.logs = [];
  }
}

wss.on("connection", (ws) => {
  ws.send(JSON.stringify({ type: "state", data: publicState() }));
  ws.send(
    JSON.stringify({
      type: "logs",
      data: state.logs.slice(0, 100),
    })
  );
});

app.get("/api/health", (_req, res) => {
  res.json({ ok: true, port: PORT });
});

app.get("/api/state", (_req, res) => {
  res.json(publicState());
});

app.get("/api/logs", (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 100, MAX_LOGS);
  res.json(state.logs.slice(0, limit));
});

app.post("/api/session/start", (req, res) => {
  const { prompt, apiKey, provider = "openai", model } = req.body || {};

  if (!prompt || !String(prompt).trim()) {
    return res.status(400).json({ error: "prompt is required" });
  }
  if (!apiKey || !String(apiKey).trim()) {
    return res.status(400).json({ error: "apiKey is required" });
  }

  resetSession(true);
  state.prompt = String(prompt).trim();
  state.apiKey = String(apiKey).trim();
  state.provider = provider === "anthropic" ? "anthropic" : "openai";
  state.model =
    model ||
    (state.provider === "anthropic" ? "claude-3-5-haiku-latest" : "gpt-4o-mini");
  state.status = "running";
  state.startedAt = new Date().toISOString();

  pushLog({
    level: "info",
    source: "web",
    message: "เริ่ม session ใหม่ — รอ GameGuardian script เชื่อมต่อ",
    detail: { prompt: state.prompt, provider: state.provider, model: state.model },
  });

  broadcast({ type: "state", data: publicState() });
  res.json(publicState());
});

app.post("/api/session/stop", (_req, res) => {
  state.status = "stopped";
  state.stoppedAt = new Date().toISOString();
  pushLog({
    level: "warn",
    source: "web",
    message: "ผู้ใช้สั่งหยุด session",
  });
  broadcast({ type: "state", data: publicState() });
  res.json(publicState());
});

app.post("/api/session/reset", (_req, res) => {
  resetSession(false);
  broadcast({ type: "state", data: publicState() });
  broadcast({ type: "logs", data: [] });
  res.json(publicState());
});

app.get("/api/gg/session", (_req, res) => {
  state.lastGgPing = new Date().toISOString();
  res.json({
    status: state.status,
    prompt: state.prompt,
    apiKey: state.apiKey,
    provider: state.provider,
    model: state.model,
    userAck: state.userAck,
    stoppedAt: state.stoppedAt,
  });
});

app.post("/api/gg/log", (req, res) => {
  const { level = "info", message, detail, source = "gg" } = req.body || {};
  if (!message) {
    return res.status(400).json({ error: "message is required" });
  }

  state.lastGgPing = new Date().toISOString();
  const log = pushLog({ level, source, message, detail });

  if (detail) {
    if (typeof detail.resultsCount === "number") {
      state.resultsCount = detail.resultsCount;
    }
    if (detail.currentAction) {
      state.currentAction = detail.currentAction;
    }
    if (Array.isArray(detail.foundAddresses)) {
      state.foundAddresses = detail.foundAddresses;
    }
    if (detail.status) {
      state.status = detail.status;
    }
  }

  broadcast({ type: "state", data: publicState() });
  res.json({ ok: true, id: log.id });
});

app.post("/api/gg/status", (req, res) => {
  const { status, resultsCount, currentAction, foundAddresses } = req.body || {};
  state.lastGgPing = new Date().toISOString();

  if (status) state.status = status;
  if (typeof resultsCount === "number") state.resultsCount = resultsCount;
  if (currentAction) state.currentAction = currentAction;
  if (Array.isArray(foundAddresses)) state.foundAddresses = foundAddresses;

  broadcast({ type: "state", data: publicState() });
  res.json({ ok: true });
});

app.post("/api/user/ack", (req, res) => {
  const { message = "done" } = req.body || {};
  state.userAck = {
    message,
    at: new Date().toISOString(),
  };
  pushLog({
    level: "info",
    source: "web",
    message: "ผู้ใช้ยืนยันขั้นตอนในเกมแล้ว",
    detail: { ack: state.userAck },
  });
  broadcast({ type: "state", data: publicState() });
  res.json({ ok: true });
});

app.post("/api/gg/user-ack", (_req, res) => {
  const ack = state.userAck;
  state.userAck = null;
  res.json({ ack });
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`GG AI Bridge running at http://127.0.0.1:${PORT}`);
  console.log(`Web UI: http://127.0.0.1:${PORT}`);
  console.log(`GG script should use: http://127.0.0.1:${PORT} (with adb reverse)`);
  console.log(`Or emulator host alias: http://10.0.2.2:${PORT}`);
});
