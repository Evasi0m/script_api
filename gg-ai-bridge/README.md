# GG AI Memory Hunter v2

ระบบให้ AI คุม GameGuardian ค้นหา memory อัตโนมัติ แปลงเป็น `module + offset` แบบ `lua test/` แก้ค่าผ่านเว็บด้วย chat และ export script `.lua` ใช้ซ้ำได้

## ความสามารถหลัก

- **Hunt Mode** — AI สั่ง GG ค้นหา/refine/resolve module/offset/probe type
- **Interactive Mode** — หลังเจอค่าแล้ว แก้ค่า/freeze/read ผ่านเว็บหรือ chat
- **Chat** — คุยภาษาธรรมชาติ แล้วแปลเป็นคำสั่ง GG
- **Script Export** — สร้าง `.lua` แบบ `simple_toggle`, `preset_values`, `multi_hack`
- **Web UI** — Dark theme, SVG icons, รองรับ desktop/mobile

## เริ่มใช้งาน

```bash
cd gg-ai-bridge
npm install
npm start
```

เปิด `http://127.0.0.1:3847`

```bash
adb reverse tcp:3847 tcp:3847
```

คัดลอกไป GameGuardian:
- `gg-script/AI_Memory_Hunter.lua`
- `gg-script/json.lua`

## Flow

1. กรอก prompt + API key + script style บนเว็บ → เริ่มค้นหา
2. รัน `AI_Memory_Hunter.lua` ใน GG
3. AI ค้นหา → resolve `libgame.so + offset` → probe type → found
4. เข้า **Interactive Mode** — แก้ค่า/chat บนเว็บ
5. กด **Generate** → Download script แบบ `lua test/`

## Script Templates

| Style | คล้ายไฟล์ | เหมาะกับ |
|-------|----------|----------|
| `simple_toggle` | `CookieRun_Classic_Helper.lua` | เปิด/ปิดโปร |
| `preset_values` | `Fix.lua` | เลือกหลายระดับค่า |
| `multi_hack` | `CookieRun_Classic_Helper2.lua` | หลาย offset |

## API สำคัญ

| Endpoint | ใช้ทำอะไร |
|----------|-----------|
| `POST /api/session/start` | เริ่ม hunt session |
| `POST /api/chat` | คุยกับ AI/GG |
| `POST /api/commands` | ส่งคำสั่งไป GG โดยตรง |
| `GET /api/gg/commands/next` | GG poll คำสั่ง |
| `POST /api/gg/findings` | อัปเดต findings |
| `POST /api/script/generate` | สร้าง script `.lua` |
| `GET /api/history` | ดู session ที่บันทึกไว้ |

## โครงสร้าง

```
gg-ai-bridge/
├── server/
│   ├── index.js
│   ├── command-queue.js
│   ├── findings-store.js
│   ├── script-generator.js
│   ├── chat-ai.js
│   └── session-history.js
├── templates/
├── gg-script/
├── web/
└── data/
```

## หมายเหตุ

- API key เก็บใน session และใช้ทั้งจาก GG (hunt) และ server (chat)
- GG ต้องรองรับ `gg.makeRequest()` HTTPS
- คุณภาพ script ขึ้นกับว่า AI resolve module/offset ได้ถูกต้อง — ควร test ก่อน export
