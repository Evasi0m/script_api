# GG AI Memory Hunter

ระบบให้ AI ควบคุม GameGuardian ค้นหา memory อัตโนมัติ พร้อมเว็บบน PC สำหรับป้อน prompt และดู log แบบ real-time

## ส่วนประกอบ

| ส่วน | ไฟล์ | หน้าที่ |
|------|------|---------|
| Bridge Server | `server/index.js` | เชื่อม GG กับเว็บ, broadcast log ผ่าน WebSocket |
| Web UI | `web/` | ป้อน prompt + API key, ดูสถานะและ log |
| GG Script | `gg-script/AI_Memory_Hunter.lua` | เรียก AI โดยตรงและรันคำสั่งค้นหาใน GG |
| JSON helper | `gg-script/json.lua` | encode/decode JSON ในสคริปต์ Lua |

## วิธีใช้

### 1) รัน server บน PC

```bash
cd gg-ai-bridge
npm install
npm start
```

เปิดเว็บที่ `http://127.0.0.1:3847`

### 2) เชื่อม Emulator กับ PC

แนะนำใช้ `adb reverse`:

```bash
adb reverse tcp:3847 tcp:3847
```

ถ้าใช้ Android Emulator (AVD) แบบไม่ reverse ให้เลือก URL `http://10.0.2.2:3847` ในสคริปต์ GG

### 3) คัดลอกสคริปต์ไปยัง GameGuardian

วางไฟล์เหล่านี้ในโฟลเดอร์เดียวกันบนเครื่อง/emulator:

- `gg-script/AI_Memory_Hunter.lua`
- `gg-script/json.lua`

แนะนำ path: `/sdcard/GG/scripts/`

### 4) เริ่มใช้งาน

1. เปิดเกม + เลือก process ใน GameGuardian
2. รันสคริปต์ `AI_Memory_Hunter.lua`
3. เลือก URL ของ bridge server
4. บนเว็บ กรอก prompt, API key, เลือก provider แล้วกด **เริ่มค้นหา**
5. AI จะสั่ง GG ค้นหา/refine อัตโนมัติ
6. ถ้า AI สั่ง `wait_user` ให้ทำตามในเกม แล้วกด **ทำเสร็จแล้ว / ยืนยัน** บนเว็บ

## ตัวอย่าง Prompt

- `หาค่าเลือดที่ลดลงเมื่อโดนตี`
- `หาค่าเงินในเกมที่ลดเมื่อซื้อของ`
- `หาค่า speed ของตัวละคร`

## AI Providers

- **OpenAI**: ใส่ `sk-...` เลือก model เช่น `gpt-4o-mini`
- **Anthropic**: ใส่ Claude API key เลือก model เช่น `claude-3-5-haiku-latest`

API key ถูกส่งจากเว็บไปยัง GG ผ่าน bridge server ใน session เดียว และ GG เป็นคนเรียก AI API โดยตรง

## คำสั่งที่ AI ใช้ควบคุม GG

| action | ความหมาย |
|--------|----------|
| `search` | ค้นหาใหม่ |
| `refine` | กรองผลลัพธ์ |
| `clear` | ล้างผลลัพธ์ |
| `get_results` | ดึงตัวอย่าง address ปัจจุบัน |
| `freeze` | ล็อกค่า |
| `wait_user` | รอให้ผู้ใช้ทำขั้นตอนในเกม |
| `found` | พบค่าแล้ว |
| `give_up` | หยุดเพราะหาไม่ได้ |

## หมายเหตุ

- GameGuardian ต้องรองรับ `gg.makeRequest()` และการเข้าถึง HTTPS
- บาง emulator อาจต้องใช้ LAN IP แทน `127.0.0.1`
- การค้นหา fuzzy (`decreased`, `increased`, `changed`, `unchanged`) ใช้รูปแบบ `;1` / `;2` / `;3` / `;4` ตามสไตล์ GameGuardian
- ถ้า AI หลุดจาก JSON ให้ลองเริ่ม session ใหม่หรือเปลี่ยน model
