const statusPill = document.getElementById("statusPill");
const promptEl = document.getElementById("prompt");
const providerEl = document.getElementById("provider");
const modelEl = document.getElementById("model");
const apiKeyEl = document.getElementById("apiKey");
const startBtn = document.getElementById("startBtn");
const stopBtn = document.getElementById("stopBtn");
const resetBtn = document.getElementById("resetBtn");
const ackBtn = document.getElementById("ackBtn");
const clearLogsBtn = document.getElementById("clearLogsBtn");
const logsEl = document.getElementById("logs");
const ggPingEl = document.getElementById("ggPing");
const resultsCountEl = document.getElementById("resultsCount");
const currentActionEl = document.getElementById("currentAction");
const providerLabelEl = document.getElementById("providerLabel");
const foundAddressesEl = document.getElementById("foundAddresses");
const waitBanner = document.getElementById("waitBanner");
const waitMessageEl = document.getElementById("waitMessage");

let ws;
let renderedLogs = new Set();

function defaultModelForProvider(provider) {
  return provider === "anthropic" ? "claude-3-5-haiku-latest" : "gpt-4o-mini";
}

function formatTime(iso) {
  if (!iso) return "-";
  return new Date(iso).toLocaleTimeString("th-TH");
}

function renderState(state) {
  statusPill.textContent = state.status || "idle";
  statusPill.className = `status-pill ${state.status || "idle"}`;

  ggPingEl.textContent = formatTime(state.lastGgPing);
  resultsCountEl.textContent = String(state.resultsCount ?? 0);
  currentActionEl.textContent = state.currentAction || "-";
  providerLabelEl.textContent = state.provider
    ? `${state.provider} / ${state.model || "-"}`
    : "-";

  if (state.status === "waiting_user") {
    waitBanner.classList.remove("hidden");
    waitMessageEl.textContent =
      state.currentAction || "AI รอให้คุณทำขั้นตอนในเกม แล้วกดยืนยัน";
  } else {
    waitBanner.classList.add("hidden");
  }

  if (state.foundAddresses?.length) {
    foundAddressesEl.textContent = JSON.stringify(state.foundAddresses, null, 2);
  } else {
    foundAddressesEl.textContent = "ยังไม่พบ";
  }
}

function renderLog(log) {
  if (!log?.id || renderedLogs.has(log.id)) return;
  renderedLogs.add(log.id);

  const item = document.createElement("div");
  item.className = `log-item ${log.level || "info"}`;
  item.innerHTML = `
    <div class="meta">
      <span class="badge">${log.level || "info"}</span>
      <span>${log.source || "system"}</span>
      <span>${formatTime(log.timestamp)}</span>
    </div>
    <div>${escapeHtml(log.message || "")}</div>
  `;

  if (log.detail) {
    const pre = document.createElement("pre");
    pre.textContent = JSON.stringify(log.detail, null, 2);
    item.appendChild(pre);
  }

  logsEl.prepend(item);
}

function escapeHtml(text) {
  return text
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
  if (!response.ok) {
    throw new Error(data.error || "Request failed");
  }
  return data;
}

function connectWs() {
  const protocol = location.protocol === "https:" ? "wss" : "ws";
  ws = new WebSocket(`${protocol}://${location.host}`);

  ws.onmessage = (event) => {
    const payload = JSON.parse(event.data);
    if (payload.type === "state") {
      renderState(payload.data);
    }
    if (payload.type === "log") {
      renderLog(payload.data);
    }
    if (payload.type === "logs") {
      logsEl.innerHTML = "";
      renderedLogs = new Set();
      payload.data.slice().reverse().forEach(renderLog);
    }
  };

  ws.onclose = () => {
    setTimeout(connectWs, 1500);
  };
}

providerEl.addEventListener("change", () => {
  if (!modelEl.value || modelEl.dataset.auto === "true") {
    modelEl.value = defaultModelForProvider(providerEl.value);
    modelEl.dataset.auto = "true";
  }
});

modelEl.addEventListener("input", () => {
  modelEl.dataset.auto = "false";
});

startBtn.addEventListener("click", async () => {
  try {
    const state = await api("/api/session/start", {
      method: "POST",
      body: JSON.stringify({
        prompt: promptEl.value,
        apiKey: apiKeyEl.value,
        provider: providerEl.value,
        model: modelEl.value || defaultModelForProvider(providerEl.value),
      }),
    });
    renderState(state);
  } catch (error) {
    alert(error.message);
  }
});

stopBtn.addEventListener("click", async () => {
  const state = await api("/api/session/stop", { method: "POST", body: "{}" });
  renderState(state);
});

resetBtn.addEventListener("click", async () => {
  const state = await api("/api/session/reset", { method: "POST", body: "{}" });
  logsEl.innerHTML = "";
  renderedLogs = new Set();
  renderState(state);
});

ackBtn.addEventListener("click", async () => {
  await api("/api/user/ack", {
    method: "POST",
    body: JSON.stringify({ message: "user completed in-game step" }),
  });
});

clearLogsBtn.addEventListener("click", () => {
  logsEl.innerHTML = "";
  renderedLogs = new Set();
});

async function bootstrap() {
  modelEl.value = defaultModelForProvider(providerEl.value);
  modelEl.dataset.auto = "true";
  connectWs();

  try {
    const state = await api("/api/state");
    renderState(state);
    const logs = await api("/api/logs?limit=100");
    logs.slice().reverse().forEach(renderLog);
  } catch (_error) {
    // server may still be starting
  }
}

bootstrap();
