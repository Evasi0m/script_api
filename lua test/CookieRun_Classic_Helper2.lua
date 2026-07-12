
--[[
   CookieRun Classic GameGuardian Helper Script
   สคริปต์เปิดโหมด: ตัวใหญ่ + วิ่งไว + แม่เหล็ก
--]]

local base = nil
local ranges = gg.getRangesList()

-- 1. ค้นหาแอดเดรสฐานของ libgame.so
for i, v in ipairs(ranges) do
    if v.name:find("libgame.so") then
        base = v.start
        break
    end
end

if base == nil then
    gg.alert("❌ ไม่พบโมดูล libgame.so กรุณาเปิดเกมก่อนรันสคริปต์")
    os.exit()
end

-- ⚠️ [จุดสำคัญ] แทนที่ค่า Offset ด้านล่างนี้ด้วยค่าที่คุณหาได้จริงจากตัวเกมของคุณ
local offset_giant  = 0x6853A0  -- ตัวอย่าง Offset ตัวใหญ่
local offset_speed  = 0x6853A4  -- ตัวอย่าง Offset วิ่งไว
local offset_magnet = 0x6853A8  -- ตัวอย่าง Offset แม่เหล็ก

local addr_giant  = base + offset_giant
local addr_speed  = base + offset_speed
local addr_magnet = base + offset_magnet

while true do
    local items = {
        "🚀 1. เปิดโปร (ตัวใหญ่ + วิ่งไว + แม่เหล็ก)",
        "🔄 2. ปิดโปร (กลับเป็นปกติ)",
        "❌ 3. ออกจากสคริปต์"
    }
    
    local choice = gg.choice(items, nil, "--- CookieRun Classic Multi-Hack ---")
    
    if choice == nil or choice == 3 then
        gg.toast("❌ ปิดสคริปต์")
        break
    end
    
    if choice == 1 then
        -- กำหนดค่าเปิดใช้งาน (โดยทั่วไปไอเทมสถานะจะล็อกค่าเป็น Float หรือ Dword)
        -- ในที่นี้ใช้ตัวอย่างเป็น Float 1.0 (เปิดใช้งาน) หรือความเร็วตามต้องการ
        local item = {
            {address = addr_giant,  flags = gg.TYPE_FLOAT, value = 2.0,   freeze = true, name = "Giant Size"},
            {address = addr_speed,  flags = gg.TYPE_FLOAT, value = 1.5,   freeze = true, name = "Fast Speed"},
            {address = addr_magnet, flags = gg.TYPE_FLOAT, value = 500.0, freeze = true, name = "Magnet Range"}
        }
        
        gg.clearList()
        gg.addListItems(item)
        
        -- ล็อกค่า (Freeze) เพื่อให้เอฟเฟกต์ติดตลอดเวลา ไม่หมดอายุ
        local saved = gg.getListItems()
        if #saved > 0 then
            saved.freeze = true
            gg.addListItems(saved)
        end
        gg.alert("✅ เปิดใช้งานสถานะ ตัวใหญ่ + วิ่งไว + แม่เหล็ก เรียบร้อยแล้ว!")
        
    elseif choice == 2 then
        -- คืนค่าปกติ (Unfreeze และปรับค่ากลับเป็น 0 หรือค่าเริ่มต้นของเกม)
        local item = {
            {address = addr_giant,  flags = gg.TYPE_FLOAT, value = 1.0, freeze = false},
            {address = addr_speed,  flags = gg.TYPE_FLOAT, value = 1.0, freeze = false},
            {address = addr_magnet, flags = gg.TYPE_FLOAT, value = 0.0, freeze = false}
        }
        gg.clearList()
        gg.addListItems(item)
        gg.setValues(item)
        gg.toast("🔄 คืนค่าสถานะตัวละครเป็นปกติ")
    end
end
