function createFindingId() {
  return `finding_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
}

class FindingsStore {
  constructor() {
    this.findings = [];
    this.game = "";
    this.scriptStyle = "simple_toggle";
  }

  reset() {
    this.findings = [];
    this.game = "";
    this.scriptStyle = "simple_toggle";
  }

  setMeta({ game, scriptStyle }) {
    if (game) this.game = game;
    if (scriptStyle) this.scriptStyle = scriptStyle;
  }

  upsert(raw) {
    const finding = {
      id: raw.id || createFindingId(),
      name: raw.name || "target",
      label: raw.label || raw.name || "เป้าหมาย",
      module: raw.module || "libgame.so",
      offset: normalizeOffset(raw.offset),
      flags: raw.flags || "TYPE_DWORD",
      values: {
        on: raw.values?.on ?? raw.on_value ?? null,
        off: raw.values?.off ?? raw.off_value ?? null,
        on_display: raw.values?.on_display ?? raw.on_display ?? "",
        off_display: raw.values?.off_display ?? raw.off_display ?? "",
        original: raw.values?.original ?? raw.original_value ?? null,
        presets: raw.values?.presets || raw.presets || [],
      },
      freeze_on_enable:
        typeof raw.freeze_on_enable === "boolean" ? raw.freeze_on_enable : true,
      verified: Boolean(raw.verified),
      address: raw.address || null,
      updatedAt: new Date().toISOString(),
    };

    const index = this.findings.findIndex((item) => item.id === finding.id);
    if (index >= 0) {
      this.findings[index] = { ...this.findings[index], ...finding };
    } else {
      this.findings.push(finding);
    }
    return finding;
  }

  update(id, patch) {
    const index = this.findings.findIndex((item) => item.id === id);
    if (index < 0) return null;
    this.findings[index] = {
      ...this.findings[index],
      ...patch,
      values: { ...this.findings[index].values, ...(patch.values || {}) },
      updatedAt: new Date().toISOString(),
    };
    return this.findings[index];
  }

  list() {
    return this.findings;
  }

  get(id) {
    return this.findings.find((item) => item.id === id) || null;
  }

  isReadyForExport() {
    return (
      this.findings.length > 0 &&
      this.findings.every((item) => item.module && item.offset && item.flags)
    );
  }

  toJSON() {
    return {
      game: this.game,
      scriptStyle: this.scriptStyle,
      findings: this.findings,
      ready: this.isReadyForExport(),
    };
  }
}

function normalizeOffset(offset) {
  if (!offset) return null;
  const text = String(offset).trim();
  if (text.startsWith("0x") || text.startsWith("0X")) {
    return `0x${text.slice(2).toUpperCase()}`;
  }
  const num = Number(text);
  if (!Number.isNaN(num)) return `0x${num.toString(16).toUpperCase()}`;
  return text;
}

module.exports = { FindingsStore, createFindingId };
