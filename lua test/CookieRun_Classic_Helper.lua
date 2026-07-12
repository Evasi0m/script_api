--[[
   CookieRun Classic GameGuardian Helper Script
   สคริปต์โกงเลือดไม่ลด (อมตะ) สำหรับบิลด์ 64-bit / Emulator
--]]

local items = {
    "⚡ 1. เปิดโปรอมตะ (เลือดไม่ลด)",
    "🔄 2. ปิดโปร (คืนค่าปกติ)",
    "❌ 3. ออกจากสคริปต์"
}

local choice = gg.choice(items, nil, "--- CookieRun Classic Cheats ---")

if choice == 1 then
    local ranges = gg.getRangesList()
    local base = nil
    
    -- ค้นหาแอดเดรสฐานของ libgame.so
    for i, v in ipairs(ranges) do
        if v.name:find("libgame.so") then
            base = v.start
            break
        end
    end
    
    if base ~= nil then
        local target_addr = base + 0x6852bc
        local item = {}
        item[1] = {
            address = target_addr, 
            flags = gg.TYPE_DWORD, 
            value = 1148846080, -- Float 999.0
            freeze = true,
            name = "CR Classic - Immortal (999.0)"
        }
        
        gg.clearList()
        gg.addListItems(item)
        gg.setValues(item) -- บันทึกค่าลงแรมทันที
        gg.alert("✅ เปิดโปรอมตะสำเร็จ!\n\n" ..
                 "แอดเดรสเป้าหมาย: " .. string.format("0x%X", target_addr) .. "\n" ..
                 "แก้ไขและล็อกค่าเป็น: 999.0\n\n" ..
                 "👉 กดเริ่มเล่นเกมได้เลย หลอดเลือดจะยาวไม่มีวันลดครับ!")
    else
        gg.alert("❌ ไม่พบโมดูล libgame.so ในแรม กรุณาตรวจสอบว่าได้เปิดเกมและเลือกกระบวนการเกมใน GG หรือยัง")
    end

elseif choice == 2 then
    local ranges = gg.getRangesList()
    local base = nil
    
    for i, v in ipairs(ranges) do
        if v.name:find("libgame.so") then
            base = v.start
            break
        end
    end
    
    if base ~= nil then
        local target_addr = base + 0x6852bc
        local item = {}
        item[1] = {
            address = target_addr, 
            flags = gg.TYPE_DWORD, 
            value = 1062232653, -- Float 0.814 (ค่าเริ่มต้น)
            name = "CR Classic - Original (0.814)"
        }
        
        gg.clearList()
        gg.addListItems(item)
        gg.setValues(item) -- คืนค่ากลับสู่ปกติ
        gg.alert("🔄 คืนค่าเลือดเป็นปกติเรียบร้อยแล้ว!")
    else
        gg.alert("❌ ไม่พบโมดูล libgame.so")
    end
end
