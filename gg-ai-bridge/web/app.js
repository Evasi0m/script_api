const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => document.querySelectorAll(sel);

const statusPill = $("#statusPill");
const ggConn = $("#ggConn");
const promptEl = $("#prompt");
const gameEl = $("#game");
const providerEl = $("#provider");
const modelEl = $("#model");
const apiKeyEl = $("#apiKey");
const scriptStyleEl = $("#scriptStyle");
const startBtn = $("#startBtn");
const stopBtn = $("#stopBtn");
const resetBtn = $("#resetBtn");
const saveBtn = $("#saveBtn");
const ackBtn = $("#ackBtn");
const waitBanner = $("#waitBanner");
const waitMessageEl = $("#waitMessage");
const chatList = $("#chatList");
const chatForm = $("#chatForm");
const chatInput = $("#chatInput");
const findingsList = $("#findingsList");
const scriptPreview = $("#scriptPreview");
const generateBtn = $("#generateBtn");
const downloadBtn = $("#downloadBtn");
const copyBtn = $("#copyBtn");
const logsEl = $("#logs");
const resultsCountEl = $("#resultsCount");
const currentActionEl = $("#currentAction");
const modeLabelEl = $("#modeLabel");
const ggPingEl = $("#ggPing");

let ws;
let renderedLogs = new Set();
let currentScript = "";
let currentState = null;

function defaultModel(provider) {
  return provider === "anthropic" ? "claude-3-5-haiku-latest" : "gpt-4o-mini";
}

function formatTime(iso) {
  if (!iso) return "-";
  return new Date(iso).toLocaleTimeString("th-TH");
}

function escapeHtml(text) {
  return String(text)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || data.issues?.join(", ") || "Request failed");
  return data;
}

function setActiveTab(name) {
  $$(".tab").forEach((tab) => tab.classList.toggle("active", tab.dataset.tab === name));
  $$(".panel").forEach((panel) => panel.classList.toggle("active", panel.dataset.panel === name));
}

function renderChatMessage(msg) {
  const item = document.createElement("div");
  item.className = `chat-item ${msg.role || "system"}`;
  item.textContent = msg.content;
  chatList.appendChild(item);
  chatList.scrollTop = chatList.scrollHeight;
}

function renderFindings(findingsData) {
  const findings = findingsData?.findings || [];
  if (!findings.length) {
    findingsList.innerHTML = '<div class="empty">ยังไม่มี findings — รอ AI ค้นหาและ resolve offset</div>';
    return;
  }

  findingsList.innerHTML = "";
  for (const item of findings) {
    const card = document.createElement("div");
    card.className = "finding-card";
    card.innerHTML = `
      <h3>${escapeHtml(item.label || item.name)}</h3>
      <div class="meta-grid">
        <div>Module<strong>${escapeHtml(item.module || "-")}</strong></div>
        <div>Offset<strong>${escapeHtml(item.offset || "-")}</strong></div>
        <div>Type<strong>${escapeHtml(item.flags || "-")}</strong></div>
        <div>On<strong>${escapeHtml(String(item.values?.on ?? "-"))}</strong></div>
        <div>Off<strong>${escapeHtml(String(item.values?.off ?? "-"))}</strong></div>
        <div>Verified<strong>${item.verified ? "yes" : "no"}</strong></div>
      </div>
      <div class="inline-input">
        <input type="text" data-id="${item.id}" class="value-input" placeholder="ค่าใหม่" value="${item.values?.on ?? ""}" />
        <button class="btn primary set-btn" data-id="${item.id}">Set</button>
      </div>
      <div class="finding-actions">
        <button class="btn ghost read-btn" data-id="${item.id}">Read</button>
        <button class="btn ghost freeze-btn" data-id="${item.id}">Freeze</button>
        <button class="btn ghost unfreeze-btn" data-id="${item.id}">Unfreeze</button>
        <button class="btn ghost test-btn" data-id="${item.id}">Test</button>
      </div>
    `;
    findingsList.appendChild(card);
  }

  findingsList.querySelectorAll(".set-btn").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const id = btn.dataset.id;
      const input = findingsList.querySelector(`.value-input[data-id="${id}"]`);
      await sendCommand("set_value", id, { value: Number(input.value), freeze: false });
    });
  });
  findingsList.querySelectorAll(".freeze-btn").forEach((btn) => {
    btn.addEventListener("click", () => sendCommand("freeze", btn.dataset.id, { freeze: true }));
  });
  findingsList.querySelectorAll(".unfreeze-btn").forEach((btn) => {
    btn.addEventListener("click", () => sendCommand("unfreeze", btn.dataset.id, { freeze: false }));
  });
  findingsList.querySelectorAll(".read-btn").forEach((btn) => {
    btn.addEventListener("click", () => sendCommand("read_value", btn.dataset.id, {}));
  });
  findingsList.querySelectorAll(".test-btn").forEach((btn) => {
    btn.addEventListener("click", () => sendCommand("test_value", btn.dataset.id, {}));
  });
}

function renderLog(log) {
  if (!log?.id || renderedLogs.has(log.id)) return;
  renderedLogs.add(log.id);
  const item = document.createElement("div");
  item.className = `log-item ${log.level || "info"}`;
  item.innerHTML = `
    <div class="meta">${escapeHtml(log.source || "system")} · ${formatTime(log.timestamp)}</div>
    <div>${escapeHtml(log.message || "")}</div>
  `;
  logsEl.prepend(item);
}

function renderState(state) {
  currentState = state;
  statusPill.textContent = state.status || "idle";
  statusPill.className = `status-pill ${state.status || "idle"}`;

  ggConn.classList.toggle("online", Boolean(state.ggConnected));
  ggConn.classList.toggle("offline", !state.ggConnected);
  ggConn.querySelector("span").textContent = state.ggConnected ? "GG Online" : "GG Offline";

  resultsCountEl.textContent = String(state.resultsCount ?? 0);
  currentActionEl.textContent = state.currentAction || "-";
  modeLabelEl.textContent = state.mode || "idle";
  ggPingEl.textContent = formatTime(state.lastGgPing);

  if (state.status === "waiting_user") {
    waitBanner.classList.remove("hidden");
    waitMessageEl.textContent = state.currentAction || "รอให้ทำขั้นตอนในเกม";
  } else {
    waitBanner.classList.add("hidden");
  }

  renderFindings(state.findings || { findings: [] });
}

async function sendCommand(type, target, payload) {
  await api("/api/commands", {
    method: "POST",
    body: JSON.stringify({ type, target, payload }),
  });
}

function connectWs() {
  const protocol = location.protocol === "https:" ? "wss" : "ws";
  ws = new WebSocket(`${protocol}://${location.host}`);

  ws.onmessage = (event) => {
    const payload = JSON.parse(event.data);
    if (payload.type === "state") renderState(payload.data);
    if (payload.type === "log") renderLog(payload.data);
    if (payload.type === "chat") renderChatMessage(payload.data);
    if (payload.type === "chat_history") {
      chatList.innerHTML = "";
      payload.data.forEach(renderChatMessage);
    }
    if (payload.type === "logs") {
      logsEl.innerHTML = "";
      renderedLogs = new Set();
      payload.data.slice().reverse().forEach(renderLog);
    }
    if (payload.type === "script") {
      currentScript = payload.data.script || "";
      scriptPreview.textContent = currentScript || "ยังไม่มีสคริปต์";
    }
  };

  ws.onclose = () => setTimeout(connectWs, 1500);
}

$$(".tab").forEach((tab) => {
  tab.addEventListener("click", () => setActiveTab(tab.dataset.tab));
});

providerEl.addEventListener("change", () => {
  if (!modelEl.value || modelEl.dataset.auto === "true") {
    modelEl.value = defaultModel(providerEl.value);
    modelEl.dataset.auto = "true";
  }
});
modelEl.addEventListener("input", () => { modelEl.dataset.auto = "false"; });

startBtn.addEventListener("click", async () => {
  try {
    const state = await api("/api/session/start", {
      method: "POST",
      body: JSON.stringify({
        prompt: promptEl.value,
        apiKey: apiKeyEl.value,
        provider: providerEl.value,
        model: modelEl.value || defaultModel(providerEl.value),
        game: gameEl.value,
        scriptStyle: scriptStyleEl.value,
      }),
    });
    renderState(state);
    setActiveTab("logs");
  } catch (error) {
    alert(error.message);
  }
});

stopBtn.addEventListener("click", async () => {
  renderState(await api("/api/session/stop", { method: "POST", body: "{}" }));
});

resetBtn.addEventListener("click", async () => {
  renderState(await api("/api/session/reset", { method: "POST", body: "{}" }));
  logsEl.innerHTML = "";
  chatList.innerHTML = "";
  renderedLogs = new Set();
  currentScript = "";
  scriptPreview.textContent = "ยังไม่มีสคริปต์";
});

saveBtn.addEventListener("click", async () => {
  try {
    const item = await api("/api/session/save", { method: "POST", body: "{}" });
    alert(`บันทึก session ${item.id} แล้ว`);
  } catch (error) {
    alert(error.message);
  }
});

ackBtn.addEventListener("click", async () => {
  await api("/api/user/ack", {
    method: "POST",
    body: JSON.stringify({ message: "user completed in-game step" }),
  });
});

chatForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const message = chatInput.value.trim();
  if (!message) return;
  chatInput.value = "";
  try {
    await api("/api/chat", {
      method: "POST",
      body: JSON.stringify({ message }),
    });
  } catch (error) {
    renderChatMessage({ role: "assistant", content: error.message });
  }
});

generateBtn.addEventListener("click", async () => {
  try {
    const data = await api("/api/script/generate", {
      method: "POST",
      body: JSON.stringify({
        scriptStyle: scriptStyleEl.value,
        game: gameEl.value,
      }),
    });
    currentScript = data.script;
    scriptPreview.textContent = currentScript;
    setActiveTab("script");
  } catch (error) {
    alert(error.message);
  }
});

downloadBtn.addEventListener("click", () => {
  if (!currentScript) return alert("ยังไม่มีสคริปต์");
  const blob = new Blob([currentScript], { type: "text/plain" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `${(gameEl.value || "game").replace(/\s+/g, "_")}_helper.lua`;
  a.click();
  URL.revokeObjectURL(url);
});

copyBtn.addEventListener("click", async () => {
  if (!currentScript) return alert("ยังไม่มีสคริปต์");
  await navigator.clipboard.writeText(currentScript);
  alert("คัดลอกแล้ว");
});

async function bootstrap() {
  modelEl.value = defaultModel(providerEl.value);
  modelEl.dataset.auto = "true";
  connectWs();
  try {
    const state = await api("/api/state");
    renderState(state);
    const logs = await api("/api/logs?limit=100");
    logs.slice().reverse().forEach(renderLog);
    const chat = await api("/api/chat");
    chat.forEach(renderChatMessage);
    const preview = await api("/api/script/preview").catch(() => null);
    if (preview?.script) {
      currentScript = preview.script;
      scriptPreview.textContent = currentScript;
    }
  } catch (_error) {
    // server starting
  }
}

bootstrap();
