const fs = require("fs");
const path = require("path");

const DATA_DIR = path.join(__dirname, "../data");
const HISTORY_FILE = path.join(DATA_DIR, "sessions.json");

class SessionHistory {
  constructor() {
    this.items = [];
    this.load();
  }

  load() {
    try {
      if (fs.existsSync(HISTORY_FILE)) {
        const raw = fs.readFileSync(HISTORY_FILE, "utf8");
        this.items = JSON.parse(raw);
      }
    } catch (_error) {
      this.items = [];
    }
  }

  save() {
    if (!fs.existsSync(DATA_DIR)) {
      fs.mkdirSync(DATA_DIR, { recursive: true });
    }
    fs.writeFileSync(HISTORY_FILE, JSON.stringify(this.items.slice(0, 50), null, 2));
  }

  add(entry) {
    const item = {
      id: entry.id || `session_${Date.now()}`,
      prompt: entry.prompt || "",
      game: entry.game || "",
      scriptStyle: entry.scriptStyle || "simple_toggle",
      findings: entry.findings || [],
      exportedScript: entry.exportedScript || null,
      createdAt: entry.createdAt || new Date().toISOString(),
    };
    this.items.unshift(item);
    if (this.items.length > 50) {
      this.items.length = 50;
    }
    this.save();
    return item;
  }

  list() {
    return this.items;
  }

  get(id) {
    return this.items.find((item) => item.id === id) || null;
  }
}

module.exports = { SessionHistory };
