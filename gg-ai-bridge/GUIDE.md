# GG AI Memory Hunter — เอกสารฉบับสมบูรณ์

> เอกสารนี้รวมทุกอย่างที่คุยและสร้างไว้ทั้งหมด  
> สำหรับนำไปทำต่อบน **Cursor Desktop**  
> Repo: `script_api` · Branch: `cursor/gg-ai-memory-hunter-4564` · PR: #1

---

## สารบัญ

1. [เป้าหมายโปรเจกต์](#1-เป้าหมายโปรเจกต์)
2. [สถาปัตยกรรมระบบ](#2-สถาปัตยกรรมระบบ)
3. [โครงสร้างไฟล์](#3-โครงสร้างไฟล์)
4. [วิธีติดตั้งและรัน](#4-วิธีติดตั้งและรัน)
5. [Flow การใช้งานจริง](#5-flow-การใช้งานจริง)
6. [Phase ที่ทำเสร็จแล้ว](#6-phase-ที่ทำเสร็จแล้ว)
7. [GameGuardian Script](#7-gameguardian-script)
8. [Bridge Server API](#8-bridge-server-api)
9. [Findings Data Model](#9-findings-data-model)
10. [Command Queue (Interactive)](#10-command-queue-interactive)
11. [Chat Layer](#11-chat-layer)
12. [Script Generator & Templates](#12-script-generator--templates)
13. [Web UI](#13-web-ui)
14. [รูปแบบเป้าหมายจาก lua test](#14-รูปแบบเป้าหมายจาก-lua-test)
15. [ข้อจำกัดและ Known Issues](#15-ข้อจำกัดและ-known-issues)
16. [แนวทางพัฒนาต่อบน Cursor Desktop](#16-แนวทางพัฒนาต่อบน-cursor-desktop)
17. [Troubleshooting](#17-troubleshooting)
18. [Quick Reference Commands](#18-quick-reference-commands)

---

## 1) เป้าหมายโปรเจกต์

### North Star

ผู้ใช้พิมพ์บนเว็บ (PC) ว่า:

> "หาค่าเลือดอมตะ แล้วทำสคริปต์เปิด/ปิดโปร"

ระบบต้องทำได้ครบวงจร:

| ลำดับ | ความสามารถ |
|-------|------------|
| 1 | **AI คุม GameGuardian** ค้นหา/refine memory อัตโนมัติ |
| 2 | แปลงผลเป็น **`module + offset + type + on/off values`** แบบ `lua test/` |
| 3 | **แก้/ทดสอบค่า** ผ่านเว็บ (chat + ปุ่มควบคุม) หลังหาเจอ |
| 4 | **Generate script `.lua`** เรียบง่าย เอาไปรันครั้งถัดไปได้โดยไม่ต้องมีเว็บ |
| 5 | **Web UI** dark theme, SVG icons, รองรับ desktop + mobile |

### บทบาทแต่ละส่วน

| ส่วน | รันที่ไหน | หน้าที่ |
|------|-----------|---------|
| **GG Script** | Android Emulator | เรียก AI, ค้นหา memory, รับคำสั่งแก้ค่า |
| **Bridge Server** | PC (port 3847) | sync session, queue คำสั่ง, chat, generate script |
| **Web UI** | PC browser | ป้อน prompt, chat, แก้ค่า, export script |
| **AI API** | Cloud | ตัดสินใจขั้นค้นหา + แปลง chat เป็นคำสั่ง GG |

### หลักการสำคัญ

- **API Key** ถูกส่งจากเว็บ → เก็บใน session → **GG เรียก AI โดยตรง** ในโหมด hunt
- **Chat ในโหมด interactive** ใช้ API key จาก session บน server แปลงเป็นคำสั่ง queue
- GG **ไม่มี WebSocket** — ใช้ HTTP polling ผ่าน `gg.makeRequest()`
- ผลลัพธ์สุดท้ายต้องเป็น **script standalone** ไม่พึ่ง bridge

---

## 2) สถาปัตยกรรมระบบ

```
┌─────────────────────────────────────────────────────────────────┐
│  PC (เครื่องที่รัน Emulator)                                     │
│                                                                 │
│  ┌──────────────┐    WebSocket/REST    ┌─────────────────────┐ │
│  │  Web UI      │ ◄──────────────────► │  Bridge Server      │ │
│  │  (port 3847) │                      │  Express + WS       │ │
│  │  Dark + SVG  │                      │  Command Queue      │ │
│  └──────────────┘                      │  Findings Store     │ │
│                                        │  Script Generator   │ │
│                                        │  Chat AI            │ │
│                                        └──────────▲──────────┘ │
│                                                   │ HTTP       │
└───────────────────────────────────────────────────┼────────────┘
                                                    │
┌───────────────────────────────────────────────────▼────────────┐
│  Android Emulator + GameGuardian                               │
│                                                                │
│  AI_Memory_Hunter.lua                                          │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Hunt Mode:                                              │  │
│  │    AI → search/refine/resolve_module/probe_type/found   │  │
│  │                                                          │  │
│  │  Interactive Mode:                                       │  │
│  │    poll command queue → set_value/freeze/read/test      │  │
│  └──────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │  OpenAI / Claude │
                    └──────────────────┘
```

### การเชื่อม Emulator ↔ PC

| วิธี | URL | หมายเหตุ |
|------|-----|----------|
| **adb reverse** (แนะนำ) | `http://127.0.0.1:3847` | รัน `adb reverse tcp:3847 tcp:3847` |
| Android Emulator host | `http://10.0.2.2:3847` | สำหรับ AVD |
| LAN IP | `http://192.168.x.x:3847` | BlueStacks, LDPlayer, MuMu |

---

## 3) โครงสร้างไฟล์

```
gg-ai-bridge/
├── package.json
├── package-lock.json
├── .gitignore
├── README.md
├── GUIDE.md                    ← เอกสารฉบับนี้
│
├── server/
│   ├── index.js                # Main server + routes + WebSocket
│   ├── command-queue.js        # คิวคำสั่ง Web → GG
│   ├── findings-store.js       # เก็บ findings แบบ structured
│   ├── script-generator.js     # render .lua จาก template
│   ├── chat-ai.js              # แปลง chat → คำสั่ง GG
│   └── session-history.js        # บันทึก session ลง data/sessions.json
│
├── templates/
│   ├── simple_toggle.lua.tpl   # แบบ CookieRun_Classic_Helper.lua
│   ├── preset_values.lua.tpl   # แบบ Fix.lua
│   └── multi_hack.lua.tpl      # แบบ CookieRun_Classic_Helper2.lua
│
├── gg-script/
│   ├── AI_Memory_Hunter.lua    # สคริปต์หลัก v2
│   └── json.lua                # JSON encode/decode สำหรับ GG
│
├── web/
│   ├── index.html              # UI หลัก (dark + SVG)
│   ├── style.css
│   └── app.js
│
└── data/
    └── sessions.json           # (สร้างอัตโนมัติ) session history
```

### ไฟล์อ้างอิงในโปรเจกต์ (lua test/)

```
lua test/
├── CookieRun_Classic_Helper.lua    # simple toggle: เปิด/ปิดอมตะ
├── CookieRun_Classic_Helper2.lua   # multi hack: ตัวใหญ่+วิ่งไว+แม่เหล็ก
├── Fix.lua                         # preset values: เลือกระดับ %
└── Fix2.lua
```

---

## 4) วิธีติดตั้งและรัน

### บน PC

```bash
cd gg-ai-bridge
npm install
npm start
```

Server จะรันที่ `http://127.0.0.1:3847`

### เชื่อม Emulator

```bash
adb reverse tcp:3847 tcp:3847
```

ตรวจสอบ:

```bash
curl http://127.0.0.1:3847/api/health
# {"ok":true,"port":3847,"version":"2.0.0"}
```

### บน GameGuardian

1. คัดลอกไปยัง emulator:
   - `gg-script/AI_Memory_Hunter.lua`
   - `gg-script/json.lua`
2. แนะนำ path: `/sdcard/GG/scripts/`
3. เปิดเกม → เลือก process ใน GG
4. รันสคริปต์ `AI_Memory_Hunter.lua`
5. เลือก URL ของ bridge server

---

## 5) Flow การใช้งานจริง

```
[1] เปิดเว็บ http://127.0.0.1:3847
         ↓
[2] กรอก Prompt + API Key + Script Style → กด "เริ่มค้นหา"
         ↓
[3] รัน AI_Memory_Hunter.lua ใน GG
         ↓
[4] Hunt Mode — AI วน loop:
      search → refine → wait_user → resolve_module → probe_type → found
         ↓
[5] เข้า Interactive Mode — แก้ค่า/chat บนเว็บ
         ↓
[6] แท็บ Script → Generate → Download .lua
         ↓
[7] รัน script ที่ export บน GG ครั้งถัดไป (ไม่ต้องมีเว็บ)
```

### Session States

| Status | ความหมาย |
|--------|----------|
| `idle` | ยังไม่เริ่ม |
| `running` | กำลังทำงาน |
| `hunting` | AI กำลังค้นหา (mode) |
| `waiting_user` | รอผู้ใช้ทำอะไรในเกม |
| `found` | พบค่าแล้ว |
| `interactive` | โหมดแก้ค่า/chat |
| `stopped` | หยุดแล้ว |
| `error` | เกิดข้อผิดพลาด |

---

## 6) Phase ที่ทำเสร็จแล้ว

### Phase 1 — Hunt Upgrade ✅

- Module resolver: แปลง absolute address → `libgame.so + 0xOFFSET`
- Value analyzer: ทดสอบ FLOAT vs DWORD
- AI actions เพิ่ม: `resolve_module`, `probe_type`, `capture_baseline`
- Findings store บน server

### Phase 2 — Interactive Mode ✅

- Command queue สองทาง (Web → GG → Web)
- Chat panel + AI แปลงข้อความเป็นคำสั่ง
- GG interactive loop (poll 500ms)
- Value Inspector: Set / Freeze / Unfreeze / Read / Test

### Phase 3 — Script Generator ✅

- Template 3 แบบตาม `lua test/`
- API generate + preview
- Download / Copy บนเว็บ

### Phase 4 — UI Redesign ✅

- Dark theme
- SVG icons (inline sprite)
- Responsive: desktop 3-panel + mobile bottom tabs
- แท็บ: Chat · Values · Script · Logs

### Phase 5 — Hardening ✅

- GG Online/Offline indicator
- Session history (`/api/history`, `/api/session/save`)
- Validate findings ก่อน export
- GG reconnect ผ่าน polling ต่อเนื่อง

---

## 7) GameGuardian Script

**ไฟล์:** `gg-ai-bridge/gg-script/AI_Memory_Hunter.lua`

### โหมดการทำงาน

#### Hunt Mode

AI เรียกผ่าน `gg.makeRequest()` ไปยัง OpenAI/Anthropic แล้วรันคำสั่ง:

| Action | ทำอะไร |
|--------|--------|
| `search` | `gg.searchNumber()` ค้นหาใหม่ |
| `refine` | `gg.refineNumber()` กรองผล |
| `clear` | `gg.clearResults()` |
| `get_results` | ดึงตัวอย่าง address |
| `resolve_module` | หา module base + คำนวณ offset |
| `probe_type` | ทดสอบ FLOAT vs DWORD |
| `capture_baseline` | เก็บค่าปกติก่อนแก้ |
| `freeze` | ล็อกค่า |
| `wait_user` | รอผู้ใช้ทำในเกม + ยืนยันบนเว็บ |
| `found` | สรุป finding แบบ structured → เข้า interactive |
| `give_up` | หยุดเพราะหาไม่ได้ |

#### Interactive Mode

หลัง `found` สำเร็จ → poll `/api/gg/commands/next` ทุก 500ms

| Command Type | ทำอะไร |
|--------------|--------|
| `read_value` | อ่านค่าปัจจุบันจาก finding |
| `set_value` | เขียนค่าใหม่ |
| `freeze` | ล็อกค่า |
| `unfreeze` | ปลดล็อก |
| `test_value` | ทดสอบค่า + mark verified |

### Fuzzy Refine (GG notation)

| Condition | ค่าที่ใช้ใน refine |
|-----------|-------------------|
| `decreased` | `;2` |
| `increased` | `;1` |
| `changed` | `;3` |
| `unchanged` | `;4` |
| `equal` | ค่าตัวเลขตรงๆ |

### Config ในสคริปต์

```lua
local CONFIG = {
  SERVER_URL = "http://127.0.0.1:3847",
  POLL_MS = 1500,              -- hunt mode poll
  INTERACTIVE_POLL_MS = 500,   -- interactive poll
  AI_TIMEOUT_MS = 60000,
  MAX_AI_STEPS = 45,
}
```

### Dependency

ต้องมี `json.lua` ในโฟลเดอร์เดียวกัน — ไฟล์ `gg-ai-bridge/gg-script/json.lua`

---

## 8) Bridge Server API

**Base URL:** `http://127.0.0.1:3847`

### Health & State

| Method | Path | คำอธิบาย |
|--------|------|----------|
| GET | `/api/health` | ตรวจว่า server รันอยู่ |
| GET | `/api/state` | สถานะ session ทั้งหมด |
| GET | `/api/logs?limit=100` | ดึง logs |

### Session

| Method | Path | Body | คำอธิบาย |
|--------|------|------|----------|
| POST | `/api/session/start` | `{ prompt, apiKey, provider?, model?, game?, scriptStyle? }` | เริ่ม hunt |
| POST | `/api/session/stop` | — | หยุด session |
| POST | `/api/session/reset` | — | รีเซ็ตทั้งหมด |
| POST | `/api/session/save` | — | บันทึกลง history |

**scriptStyle values:** `simple_toggle` | `preset_values` | `multi_hack`

### Findings

| Method | Path | คำอธิบาย |
|--------|------|----------|
| GET | `/api/session/findings` | ดึง findings ปัจจุบัน |
| POST | `/api/gg/findings` | GG อัปเดต findings |
| PATCH | `/api/findings/:id` | แก้ finding จากเว็บ |

### GG Endpoints (เรียกจากสคริปต์ GG)

| Method | Path | คำอธิบาย |
|--------|------|----------|
| GET | `/api/gg/session` | ดึง session config (prompt, apiKey, findings) |
| POST | `/api/gg/log` | ส่ง log |
| POST | `/api/gg/status` | อัปเดต status/mode |
| GET | `/api/gg/user-ack` | ดึง user ack (แล้ว clear) |
| GET | `/api/gg/commands/next` | ดึงคำสั่งถัดไปจาก queue |
| POST | `/api/gg/commands/result` | ส่งผลการรันคำสั่ง |

### Commands (จากเว็บ)

| Method | Path | Body |
|--------|------|------|
| POST | `/api/commands` | `{ type, target, payload }` |
| GET | `/api/commands/:id/result` | ดูผลคำสั่ง |

**Command types:** `read_value` | `set_value` | `freeze` | `unfreeze` | `test_value`

### Chat

| Method | Path | Body |
|--------|------|------|
| GET | `/api/chat` | ประวัติ chat |
| POST | `/api/chat` | `{ message }` — AI แปลงเป็นคำสั่งหรือตอบอธิบาย |

### Script Export

| Method | Path | Body |
|--------|------|------|
| POST | `/api/script/generate` | `{ scriptStyle?, game? }` |
| GET | `/api/script/preview` | ดู script ที่ generate ล่าสุด |

### History

| Method | Path |
|--------|------|
| GET | `/api/history` |
| GET | `/api/history/:id` |

### User Interaction

| Method | Path | Body |
|--------|------|------|
| POST | `/api/user/ack` | `{ message? }` — ยืนยันทำขั้นตอนในเกมแล้ว |

### WebSocket Events

| Event | Data |
|-------|------|
| `state` | สถานะ session อัปเดต |
| `log` | log ใหม่ |
| `logs` | log ทั้งหมด (ตอน connect) |
| `chat` | ข้อความ chat ใหม่ |
| `chat_history` | ประวัติ chat (ตอน connect) |
| `command` | คำสั่งใหม่ถูก enqueue |
| `command_result` | ผลคำสั่งจาก GG |
| `script` | script ที่ generate แล้ว |

---

## 9) Findings Data Model

```json
{
  "id": "finding_123",
  "name": "immortal_hp",
  "label": "เปิดโปรอมตะ (เลือดไม่ลด)",
  "module": "libgame.so",
  "offset": "0x6852BC",
  "flags": "TYPE_DWORD",
  "address": "0x7B4A2C6852BC",
  "verified": true,
  "values": {
    "on": 1148846080,
    "off": 1062232653,
    "on_display": "999.0",
    "off_display": "0.814",
    "original": 1062232653,
    "presets": [
      { "label": "เพิ่ม 10%", "value": 0.8954 },
      { "label": "เพิ่ม 30%", "value": 1.0582 }
    ]
  },
  "freeze_on_enable": true
}
```

### เงื่อนไขพร้อม Export

- มี findings อย่างน้อย 1 รายการ
- ทุก finding มี `module`, `offset`, `flags`

---

## 10) Command Queue (Interactive)

### Flow

```
Web ส่ง POST /api/commands
        ↓
Server เก็บในคิว (status: pending)
        ↓
GG poll GET /api/gg/commands/next
        ↓
GG รันคำสั่ง (set_value, freeze, ...)
        ↓
GG ส่ง POST /api/gg/commands/result
        ↓
Web ได้รับผลผ่าน WebSocket (command_result)
```

### ตัวอย่าง: ตั้งค่าและ freeze

```bash
curl -X POST http://127.0.0.1:3847/api/commands \
  -H "Content-Type: application/json" \
  -d '{
    "type": "set_value",
    "target": "finding_123",
    "payload": { "value": 999, "freeze": true }
  }'
```

---

## 11) Chat Layer

### การทำงาน

1. ผู้ใช้พิมพ์ในแท็บ Chat
2. Server เรียก AI (ใช้ apiKey จาก session)
3. AI ตอบเป็น:
   - `{ "action": "explain", "message": "..." }` — อธิบายอย่างเดียว
   - `{ "action": "command", "type": "set_value", "target": "...", "payload": {...} }` — สั่ง GG
4. ถ้าเป็น command → enqueue → GG รัน → ตอบกลับใน chat

### ตัวอย่างข้อความที่ใช้ได้

- "ตั้งเลือดเป็น 999 แล้ว freeze"
- "อ่านค่าปัจจุบันให้หน่อย"
- "offset นี้คืออะไร"
- "ทดสอบค่า on ให้หน่อย"

---

## 12) Script Generator & Templates

### Template Mapping

| scriptStyle | คล้ายไฟล์ | เมนู |
|-------------|-----------|------|
| `simple_toggle` | `CookieRun_Classic_Helper.lua` | เปิดโปร / ปิดโปร / ออก |
| `preset_values` | `Fix.lua` | เลือกหลายระดับค่า |
| `multi_hack` | `CookieRun_Classic_Helper2.lua` | หลาย offset ในเมนูเดียว |

### ตัวอย่าง Output (simple_toggle)

```lua
--[[
   CookieRun Classic
   Auto-generated by GG AI Memory Hunter
--]]

local items = {
    "เปิดโปรอมตะ (เลือดไม่ลด)",
    "ปิดโปร (คืนค่าปกติ)",
    "ออกจากสคริปต์"
}

local choice = gg.choice(items, nil, "--- CookieRun Classic ---")
-- ... หา libgame.so → base + offset → setValues
```

### Generate ผ่าน API

```bash
curl -X POST http://127.0.0.1:3847/api/script/generate \
  -H "Content-Type: application/json" \
  -d '{"scriptStyle":"simple_toggle","game":"CookieRun Classic"}'
```

---

## 13) Web UI

**URL:** `http://127.0.0.1:3847`

### ส่วนประกอบ

| ส่วน | รายละเอียด |
|------|------------|
| **Hunt Setup** | Prompt, ชื่อเกม, Provider, Model, API Key, Script Style |
| **Status** | GG Online/Offline, session status pill |
| **Wait Banner** | แสดงเมื่อ AI รอให้ทำในเกม + ปุ่มยืนยัน |
| **แท็บ Chat** | คุยกับ AI/GG |
| **แท็บ Values** | Findings inspector + ปุ่ม Set/Freeze/Read/Test |
| **แท็บ Script** | Preview + Generate + Download + Copy |
| **แท็บ Logs** | Live timeline + stats |

### Responsive

- **Desktop:** layout เต็มรูปแบบ
- **Mobile (<900px):** แท็บแสดงเฉพาะ icon, grid ย่อเป็น 1 คอลัมน์

### ไฟล์ UI

- `web/index.html` — layout + SVG sprite
- `web/style.css` — dark design system
- `web/app.js` — logic ทั้งหมด

---

## 14) รูปแบบเป้าหมายจาก lua test

### สิ่งที่ script ใน `lua test/` ทำ

```lua
-- 1) หา module base
for i, v in ipairs(gg.getRangesList()) do
    if v.name:find("libgame.so") then base = v.start; break end
end

-- 2) ใช้ offset ไม่ใช่ absolute address
local addr = base + 0x6852bc

-- 3) เขียนค่าด้วย type ที่ถูกต้อง
gg.setValues({
    {address = addr, flags = gg.TYPE_DWORD, value = 1148846080, freeze = true}
})

-- 4) เมนูเรียบง่าย
local choice = gg.choice(items, nil, "--- Title ---")
```

### ความแตกต่าง TYPE

| ไฟล์ | Type | ตัวอย่างค่า |
|------|------|------------|
| `CookieRun_Classic_Helper.lua` | `TYPE_DWORD` | `1148846080` (= float 999.0 แบบ bit) |
| `Fix.lua` | `TYPE_FLOAT` | `0.8954`, `1.0582` |

ระบบ v2 รองรับทั้งสองแบบผ่าน `probe_type` + findings.flags

---

## 15) ข้อจำกัดและ Known Issues

| หัวข้อ | รายละเอียด |
|--------|------------|
| **Latency** | GG poll → คำสั่งหน่วง ~0.5–1.5 วินาที |
| **AI ไม่การันตี 100%** | ต้อง test ก่อน export เสมอ |
| **Offset เปลี่ยนเมื่อเกมอัปเดต** | script อาจพัง — ต้องหาใหม่ |
| **ค่าเข้ารหัส** | หาไม่ได้ด้วยวิธีปกติ — ต้อง manual |
| **GG makeRequest** | ต้องรองรับ HTTPS + API ของ GG version ที่ใช้ |
| **Chat ใช้ key บน server** | ไม่ได้เรียกผ่าน GG ในโหมด interactive (ต่างจาก hunt) |
| **หลาย offset** | ต้องหาทีละค่าหรือหลายรอบ AI |

---

## 16) แนวทางพัฒนาต่อบน Cursor Desktop

### ลำดับแนะนำถ้าจะทำต่อ

#### A) ปรับความแม่นยำ AI Hunt

- [ ] ปรับ `SYSTEM_PROMPT` ใน `AI_Memory_Hunter.lua` ให้เฉพาะเกม
- [ ] เพิ่ม game profile config (เช่น CookieRun = libgame.so + DWORD float bits)
- [ ] บังคับให้ AI เรียก `resolve_module` ก่อน `found` เสมอ

#### B) ปรับ Script Generator

- [ ] รองรับ `presets` array อัตโนมัติจาก AI (แบบ Fix.lua)
- [ ] เพิ่ม in-browser script editor ก่อน download
- [ ] ใส่ comment ภาษาไทยใน template อธิบาย offset

#### C) ปรับ Web UI

- [ ] เพิ่มหน้า History แสดง session เก่า
- [ ] เพิ่ม onboarding wizard ขั้นตอนแรก
- [ ] แสดงผล command_result ใน chat แบบ real-time ชัดขึ้น

#### D) ปรับ GG Script

- [ ] รองรับ encrypted search
- [ ] เก็บ API key ใน session ฝั่ง GG โดยไม่ต้องส่งซ้ำทุก poll
- [ ] เพิ่ม retry เมื่อ `gg.makeRequest` ล้มเหลว

#### E) คุณภาพและ Test

- [ ] เพิ่ม unit test สำหรับ `script-generator.js` และ `findings-store.js`
- [ ] เพิ่ม e2e test จำลอง GG ด้วย mock API
- [ ] ทดสอบกับเกมจริง (CookieRun) แล้วปรับ preset

### จุดเริ่มต้นใน Cursor Desktop

```
1. เปิด repo script_api
2. checkout branch: cursor/gg-ai-memory-hunter-4564
3. เปิดโฟลเดอร์ gg-ai-bridge/
4. อ่านไฟล์นี้ (GUIDE.md) + README.md
5. รัน npm start แล้วเปิดเว็บทดสอบ
6. เลือกงานจากหัวข้อ A–E ด้านบน
```

### Git

```bash
git checkout cursor/gg-ai-memory-hunter-4564
git pull origin cursor/gg-ai-memory-hunter-4564
```

PR: https://github.com/Evasi0m/script_api/pull/1

---

## 17) Troubleshooting

| ปัญหา | วิธีแก้ |
|-------|---------|
| เว็บเปิดไม่ได้ | ตรวจ `npm start` รันอยู่ที่ port 3847 |
| GG เชื่อมไม่ได้ | รัน `adb reverse tcp:3847 tcp:3847` |
| GG Offline บนเว็บ | รันสคริปต์ GG + ตรวจ URL ใน GG |
| ไม่พบ json.lua | วาง `json.lua` โฟลเดอร์เดียวกับสคริปต์ |
| AI เรียกไม่สำเร็จ | ตรวจ API key, model, HTTPS บน GG |
| Generate script ไม่ได้ | ต้องมี findings ที่มี module+offset+flags |
| คำสั่ง chat ไม่ทำงาน | ต้องอยู่ในโหมด interactive + GG script รันค้าง |
| Emulator คนละเครื่อง | ใช้ LAN IP แทน 127.0.0.1 |

---

## 18) Quick Reference Commands

```bash
# ติดตั้ง + รัน
cd gg-ai-bridge && npm install && npm start

# เชื่อม emulator
adb reverse tcp:3847 tcp:3847

# ตรวจ health
curl http://127.0.0.1:3847/api/health

# เริ่ม session
curl -X POST http://127.0.0.1:3847/api/session/start \
  -H "Content-Type: application/json" \
  -d '{"prompt":"หาค่าเลือดอมตะ","apiKey":"sk-...","game":"CookieRun","scriptStyle":"simple_toggle"}'

# ส่ง chat
curl -X POST http://127.0.0.1:3847/api/chat \
  -H "Content-Type: application/json" \
  -d '{"message":"ตั้งเลือดเป็น 999 แล้ว freeze"}'

# generate script
curl -X POST http://127.0.0.1:3847/api/script/generate \
  -H "Content-Type: application/json" \
  -d '{"scriptStyle":"simple_toggle"}'

# บันทึก session
curl -X POST http://127.0.0.1:3847/api/session/save
```

---

## ภาคผนวก: แผน 5 Phase (อ้างอิง)

| Phase | ชื่อ | สถานะ |
|-------|------|-------|
| 1 | Hunt Upgrade (module/offset/type) | ✅ เสร็จ |
| 2 | Interactive Mode (chat + command queue) | ✅ เสร็จ |
| 3 | Script Generator (lua test templates) | ✅ เสร็จ |
| 4 | UI Redesign (dark/SVG/responsive) | ✅ เสร็จ |
| 5 | Hardening (history, validation, reconnect) | ✅ เสร็จ |

---

## ภาคผนวก: Definition of Done

- [x] พิมพ์ prompt บนเว็บ → AI คุม GG หาค่า
- [x] ได้ผลแบบ `libgame.so + offset`
- [x] แก้ค่า/freeze ผ่านเว็บหลังเจอ
- [x] Chat สั่ง/อธิบายผ่านเว็บ
- [x] Export `.lua` แบบ `lua test/`
- [x] UI dark + SVG + responsive

---

*อัปเดตล่าสุด: 2026-07-12 · GG AI Memory Hunter v2*
