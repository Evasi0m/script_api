const fs = require("fs");
const path = require("path");

const TEMPLATE_DIR = path.join(__dirname, "../templates");

function flagToLua(flags) {
  const map = {
    TYPE_DWORD: "gg.TYPE_DWORD",
    TYPE_FLOAT: "gg.TYPE_FLOAT",
    TYPE_QWORD: "gg.TYPE_QWORD",
    TYPE_WORD: "gg.TYPE_WORD",
    TYPE_BYTE: "gg.TYPE_BYTE",
    TYPE_DOUBLE: "gg.TYPE_DOUBLE",
  };
  return map[flags] || "gg.TYPE_DWORD";
}

function renderTemplate(name, vars) {
  const file = path.join(TEMPLATE_DIR, `${name}.lua.tpl`);
  let content = fs.readFileSync(file, "utf8");
  for (const [key, value] of Object.entries(vars)) {
    content = content.replaceAll(`{{${key}}}`, String(value));
  }
  return content;
}

function buildSimpleToggle({ game, findings }) {
  const primary = findings[0];
  const onValue = primary.values.on ?? 0;
  const offValue = primary.values.off ?? primary.values.original ?? 0;
  const onLabel = primary.label || "เปิดโปร";
  const offLabel = primary.values.off_display
    ? `ปิดโปร (${primary.values.off_display})`
    : "ปิดโปร (คืนค่าปกติ)";

  return renderTemplate("simple_toggle", {
    GAME_TITLE: game || "Game Helper",
    MODULE_PATTERN: primary.module || "libgame.so",
    OFFSET: primary.offset,
    FLAG: flagToLua(primary.flags),
    ON_VALUE: onValue,
    OFF_VALUE: offValue,
    ON_LABEL: onLabel,
    OFF_LABEL: offLabel,
    FREEZE_ON: primary.freeze_on_enable ? "true" : "false",
    GENERATED_AT: new Date().toISOString(),
  });
}

function buildPresetValues({ game, findings }) {
  const primary = findings[0];
  const presets = primary.values.presets?.length
    ? primary.values.presets
    : [
        { label: "ค่า 1", value: primary.values.on },
        { label: "คืนค่าปกติ", value: primary.values.off || primary.values.original },
      ].filter((item) => item.value !== null && item.value !== undefined);

  const labels = presets.map((item) => `"${item.label}"`).join(",\n    ");
  const vals = presets.map((item) => item.value).join(", ");

  return renderTemplate("preset_values", {
    GAME_TITLE: game || "Game Helper",
    MODULE_PATTERN: primary.module || "libgame.so",
    OFFSET: primary.offset,
    FLAG: flagToLua(primary.flags),
    LABELS: labels,
    VALUES: vals,
    GENERATED_AT: new Date().toISOString(),
  });
}

function buildMultiHack({ game, findings }) {
  const offsets = findings
    .map((item, index) => {
      const key = `offset_${index + 1}`;
      return `local ${key} = ${item.offset}  -- ${item.label}`;
    })
    .join("\n");

  const addrs = findings
    .map((item, index) => `local addr_${index + 1} = base + offset_${index + 1}`)
    .join("\n");

  const onItems = findings
    .map((item, index) => {
      const value = item.values.on ?? 1;
      const flag = flagToLua(item.flags);
      return `      {address = addr_${index + 1}, flags = ${flag}, value = ${value}, freeze = true, name = "${item.label}"}`;
    })
    .join(",\n");

  const offItems = findings
    .map((item, index) => {
      const value = item.values.off ?? item.values.original ?? 0;
      const flag = flagToLua(item.flags);
      return `      {address = addr_${index + 1}, flags = ${flag}, value = ${value}, freeze = false}`;
    })
    .join(",\n");

  return renderTemplate("multi_hack", {
    GAME_TITLE: game || "Game Multi-Hack",
    MODULE_PATTERN: findings[0]?.module || "libgame.so",
    OFFSETS: offsets,
    ADDRS: addrs,
    ON_ITEMS: onItems,
    OFF_ITEMS: offItems,
    GENERATED_AT: new Date().toISOString(),
  });
}

function generateScript({ game, scriptStyle, findings }) {
  if (!findings?.length) {
    throw new Error("no findings to export");
  }

  switch (scriptStyle) {
    case "preset_values":
      return buildPresetValues({ game, findings });
    case "multi_hack":
      return buildMultiHack({ game, findings });
    case "simple_toggle":
    default:
      return findings.length > 1
        ? buildMultiHack({ game, findings })
        : buildSimpleToggle({ game, findings });
  }
}

function validateFindings(findings) {
  const issues = [];
  if (!findings?.length) {
    issues.push("ยังไม่มี findings");
    return issues;
  }
  for (const item of findings) {
    if (!item.module) issues.push(`${item.label}: ไม่มี module`);
    if (!item.offset) issues.push(`${item.label}: ไม่มี offset`);
    if (!item.flags) issues.push(`${item.label}: ไม่มี type flags`);
  }
  return issues;
}

module.exports = { generateScript, validateFindings };
