local base = nil
local ranges = gg.getRangesList()
for i, v in ipairs(ranges) do
    if v.name:find("libgame.so") then base = v.start; break end
end
if not base then gg.alert("❌ ไม่พบ libgame.so"); return end

local addr = base + 0x6852bc
local vals = {0.8954, 1.0582, 1.221, 1.628, 0.814}
local labels = {
    "เพิ่ม 10% (0.8954)",
    "เพิ่ม 30% (1.0582)",
    "เพิ่ม 50% (1.221)",
    "เพิ่ม 100% (1.628)",
    "คืนค่าปกติ (0.814)"
}

-- 1. แสดงเมนูให้เลือกแค่รอบเดียว (ไม่มี while true คร่อมแล้ว)
local choice = gg.choice(labels, "เลือกเพิ่มพลังชีวิต")

-- 2. ถ้าผู้ใช้กดปิด หรือกดยกเลิก (เมนูเป็น nil) ให้จบการทำงานทันที
if choice == nil then 
    gg.toast("🛑 ยกเลิกการทำงาน")
    return 
end

-- 3. แสดงข้อความแจ้งเตือนก่อนว่าสคริปต์กำลังเริ่มทำงาน
gg.toast("⏳ สคริปต์กำลังทำงาน... กรุณารอสักครู่")
gg.sleep(1000) -- หน่วงเวลา 1 วินาทีให้เห็นข้อความชัดขึ้น (ใส่หรือไม่ใส่ก็ได้)

-- 4. ทำการเปลี่ยนค่าในเมมโมรี่
gg.setValues({
    {address = addr, flags = gg.TYPE_FLOAT, value = vals[choice], freeze = false}
})

-- 5. แจ้งเตือนเมื่อทำงานเสร็จสิ้น
gg.alert("✅ สคริปต์ทำงานเสร็จสิ้น!\nตั้งค่าเป็น: " .. vals[choice])