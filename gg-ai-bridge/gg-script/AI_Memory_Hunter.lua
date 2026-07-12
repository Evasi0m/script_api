--[[
  GG AI Memory Hunter
  ให้ AI ควบคุม GameGuardian ค้นหา memory อัตโนมัติ

  วิธีใช้:
  1. รัน bridge server บน PC: npm start (port 3847)
  2. เชื่อม emulator: adb reverse tcp:3847 tcp:3847
  3. เปิดเว็บ http://127.0.0.1:3847 แล้วกรอก prompt + API key
  4. รันสคริปต์นี้ใน GameGuardian (ต้องมี json.lua ในโฟลเดอร์เดียวกัน)
--]]

local function loadJsonModule()
  local paths = { "json.lua", "/sdcard/GG/scripts/json.lua" }
  if gg.getFile then
    local current = gg.getFile()
    if current and current ~= "" then
      table.insert(paths, 1, current:gsub("[^/\\]+$", "") .. "json.lua")
    end
  end
  for _, path in ipairs(paths) do
    local ok, mod = pcall(function()
      return dofile(path)
    end)
    if ok and mod then
      return mod
    end
    local loader = loadfile(path)
    if loader then
      local mod = loader()
      if mod then
        return mod
      end
    end
  end
  return nil
end

local json = loadJsonModule()
if not json then
  gg.alert("❌ ไม่พบ json.lua\nกรุณาวาง json.lua ไว้ในโฟลเดอร์เดียวกับสคริปต์นี้ หรือใน /sdcard/GG/scripts/")
  return
end

local CONFIG = {
  SERVER_URL = "http://127.0.0.1:3847",
  POLL_MS = 1500,
  AI_TIMEOUT_MS = 60000,
  MAX_AI_STEPS = 40,
  MAX_RESULTS_SAMPLE = 8,
  MAX_HISTORY = 12,
}

local TYPE_MAP = {
  DWORD = gg.TYPE_DWORD,
  FLOAT = gg.TYPE_FLOAT,
  QWORD = gg.TYPE_QWORD,
  WORD = gg.TYPE_WORD,
  BYTE = gg.TYPE_BYTE,
  DOUBLE = gg.TYPE_DOUBLE,
  AUTO = gg.TYPE_AUTO,
}

local session = {
  prompt = nil,
  apiKey = nil,
  provider = "openai",
  model = "gpt-4o-mini",
  status = "idle",
}

local history = {}
local lastResultsSample = {}
local lastResultsCount = 0

local SYSTEM_PROMPT = [[You control GameGuardian memory search for an Android game.
Reply with ONE JSON object only. No markdown, no extra text.

Allowed actions:
- search: initial or new search
- refine: narrow existing results
- clear: clear result list
- get_results: inspect current result sample
- freeze: freeze selected addresses
- wait_user: ask the human to change something in-game, then continue
- found: confident target addresses were identified
- give_up: cannot continue safely

JSON schema:
{
  "action": "search|refine|clear|get_results|freeze|wait_user|found|give_up",
  "type": "DWORD|FLOAT|QWORD|WORD|BYTE|DOUBLE|AUTO",
  "value": "search text for GG, e.g. 100 or 1~999 or ??",
  "refine_value": "exact refine value when needed",
  "condition": "equal|decreased|increased|changed|unchanged",
  "freeze_value": "numeric value to write",
  "pick": [{"index":1}],
  "message": "short Thai message for the user when action is wait_user",
  "reasoning": "brief reason"
}

Rules:
- Use small, realistic search steps like a human using GameGuardian.
- Prefer DWORD/FLOAT first unless prompt suggests otherwise.
- If the user must damage/heal/spend currency in-game, use wait_user.
- Use found only when results are likely 1-3 useful addresses.
- Never invent addresses. Use get_results before found/freeze when unsure.
- For unknown starting value, search with a broad range like 1~999999.
- For fuzzy refine without exact value, set condition to decreased/increased/changed/unchanged.
]]

local function toast(msg)
  gg.toast(msg)
end

local function sleep(ms)
  gg.sleep(ms)
end

local function urlencode(str)
  return (tostring(str):gsub("([^%w%-%_%.%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function bridgeRequest(method, path, bodyTable)
  local url = CONFIG.SERVER_URL .. path
  local headers = { ["Content-Type"] = "application/json" }
  local body = bodyTable and json.encode(bodyTable) or nil
  local response = gg.makeRequest(url, headers, body, method)
  if not response or not response.content then
    return nil, "no response"
  end
  if response.code and response.code >= 400 then
    return nil, "http " .. tostring(response.code) .. ": " .. tostring(response.content)
  end
  local ok, data = pcall(json.decode, response.content)
  if ok then
    return data
  end
  return response.content
end

local function bridgeLog(level, message, detail)
  bridgeRequest("POST", "/api/gg/log", {
    level = level,
    message = message,
    detail = detail,
    source = "gg",
  })
end

local function bridgeStatus(payload)
  bridgeRequest("POST", "/api/gg/status", payload)
end

local function fetchSession()
  local data = bridgeRequest("GET", "/api/gg/session")
  if type(data) == "table" then
    session.prompt = data.prompt
    session.apiKey = data.apiKey
    session.provider = data.provider or session.provider
    session.model = data.model or session.model
    session.status = data.status or session.status
    return data
  end
  return nil
end

local function fetchUserAck()
  local data = bridgeRequest("GET", "/api/gg/user-ack")
  if type(data) == "table" and data.ack then
    return data.ack
  end
  return nil
end

local function mapType(typeName)
  if not typeName then
    return gg.TYPE_DWORD
  end
  return TYPE_MAP[string.upper(tostring(typeName))] or gg.TYPE_DWORD
end

local function pushHistory(entry)
  history[#history + 1] = entry
  if #history > CONFIG.MAX_HISTORY then
    table.remove(history, 1)
  end
end

local function formatAddress(addr)
  return string.format("0x%X", tonumber(addr) or 0)
end

local function sampleResults()
  local count = gg.getResultsCount()
  lastResultsCount = count
  lastResultsSample = {}
  if count <= 0 then
    return lastResultsSample, count
  end
  local take = math.min(count, CONFIG.MAX_RESULTS_SAMPLE)
  local results = gg.getResults(take)
  for i, item in ipairs(results) do
    lastResultsSample[#lastResultsSample + 1] = {
      index = i,
      address = formatAddress(item.address),
      value = tostring(item.value),
      flags = tonumber(item.flags) or 0,
    }
  end
  return lastResultsSample, count
end

local function conditionToRefineText(condition, refineValue)
  local c = condition and string.lower(condition) or "equal"
  if c == "decreased" then return ";2" end
  if c == "increased" then return ";1" end
  if c == "changed" then return ";3" end
  if c == "unchanged" then return ";4" end
  return refineValue or "0"
end

local function executeSearch(cmd)
  local value = cmd.value or "0"
  local vtype = mapType(cmd.type)
  gg.clearResults()
  gg.searchNumber(value, vtype, false, gg.SIGN_EQUAL, 0, -1)
  local sample, count = sampleResults()
  pushHistory({
    step = "search",
    value = value,
    type = cmd.type or "DWORD",
    count = count,
  })
  return true, "search เสร็จ เหลือ " .. count .. " ผลลัพธ์", sample, count
end

local function executeRefine(cmd)
  local vtype = mapType(cmd.type)
  local text = conditionToRefineText(cmd.condition, cmd.refine_value or cmd.value)
  gg.refineNumber(text, vtype, false, gg.SIGN_EQUAL, 0, -1)
  local sample, count = sampleResults()
  pushHistory({
    step = "refine",
    condition = cmd.condition or "equal",
    refine_value = cmd.refine_value or cmd.value,
    count = count,
  })
  return true, "refine เสร็จ เหลือ " .. count .. " ผลลัพธ์", sample, count
end

local function executeClear()
  gg.clearResults()
  lastResultsSample = {}
  lastResultsCount = 0
  pushHistory({ step = "clear", count = 0 })
  return true, "ล้างผลลัพธ์แล้ว", {}, 0
end

local function executeGetResults()
  local sample, count = sampleResults()
  pushHistory({ step = "get_results", count = count })
  return true, "ดึงตัวอย่างผลลัพธ์ " .. #sample .. " รายการ", sample, count
end

local function executeFreeze(cmd)
  local count = gg.getResultsCount()
  if count <= 0 then
    return false, "ไม่มีผลลัพธ์ให้ freeze", {}, 0
  end

  local picks = cmd.pick or {{ index = 1 }}
  local results = gg.getResults(math.min(count, 20))
  local items = {}
  local frozen = {}

  for _, pick in ipairs(picks) do
    local idx = tonumber(pick.index) or 1
    local target = results[idx]
    if target then
      local newValue = cmd.freeze_value or target.value
      items[#items + 1] = {
        address = target.address,
        flags = target.flags,
        value = newValue,
        freeze = true,
      }
      frozen[#frozen + 1] = {
        index = idx,
        address = formatAddress(target.address),
        value = tostring(newValue),
      }
    end
  end

  if #items == 0 then
    return false, "ไม่พบ address สำหรับ freeze", {}, count
  end

  gg.addListItems(items)
  gg.setValues(items)
  pushHistory({ step = "freeze", frozen = frozen })
  return true, "freeze " .. #items .. " address แล้ว", frozen, count
end

local function executeWaitUser(cmd)
  local message = cmd.message or "กรุณาทำขั้นตอนในเกม แล้วกดยืนยันบนเว็บ"
  bridgeStatus({ status = "waiting_user", currentAction = message })
  bridgeLog("warn", message, { status = "waiting_user" })
  toast("รอผู้ใช้ทำขั้นตอนในเกม...")

  local waited = 0
  while waited < 300000 do
    if session.status == "stopped" then
      return false, "ถูกสั่งหยุดระหว่างรอผู้ใช้", lastResultsSample, lastResultsCount
    end
    local ack = fetchUserAck()
    if ack then
      bridgeStatus({ status = "running", currentAction = "ผู้ใช้ยืนยันแล้ว ดำเนินการต่อ" })
      bridgeLog("info", "ผู้ใช้ยืนยันขั้นตอนในเกมแล้ว", { ack = ack })
      pushHistory({ step = "wait_user", ack = true })
      return true, "ผู้ใช้ยืนยันแล้ว", sampleResults()
    end
    fetchSession()
    sleep(1000)
    waited = waited + 1000
  end

  return false, "หมดเวลารอผู้ใช้", lastResultsSample, lastResultsCount
end

local function executeFound(cmd)
  local sample, count = sampleResults()
  local found = cmd.addresses or sample
  bridgeStatus({
    status = "found",
    foundAddresses = found,
    resultsCount = count,
    currentAction = "พบค่าที่น่าจะใช่แล้ว",
  })
  bridgeLog("success", cmd.message or "พบ address ที่น่าจะใช่แล้ว", {
    status = "found",
    foundAddresses = found,
    resultsCount = count,
    reasoning = cmd.reasoning,
  })
  pushHistory({ step = "found", found = found, count = count })
  return true, "พบค่าแล้ว", found, count
end

local function executeCommand(cmd)
  if not cmd or not cmd.action then
    return false, "คำสั่ง AI ไม่ถูกต้อง", lastResultsSample, lastResultsCount
  end

  local action = string.lower(cmd.action)
  bridgeStatus({ currentAction = action, resultsCount = lastResultsCount })

  if action == "search" then
    return executeSearch(cmd)
  elseif action == "refine" then
    return executeRefine(cmd)
  elseif action == "clear" then
    return executeClear()
  elseif action == "get_results" then
    return executeGetResults()
  elseif action == "freeze" then
    return executeFreeze(cmd)
  elseif action == "wait_user" then
    return executeWaitUser(cmd)
  elseif action == "found" then
    return executeFound(cmd)
  elseif action == "give_up" then
    bridgeLog("warn", cmd.message or "AI หยุดการค้นหา", { status = "stopped", reasoning = cmd.reasoning })
    return false, cmd.message or "AI หยุดการค้นหา", lastResultsSample, lastResultsCount
  end

  return false, "ไม่รู้จัก action: " .. tostring(cmd.action), lastResultsSample, lastResultsCount
end

local function buildUserContext()
  local sample, count = sampleResults()
  return {
    goal = session.prompt,
    resultsCount = count,
    resultsSample = sample,
    history = history,
  }
end

local function callOpenAI(messages)
  local payload = {
    model = session.model,
    temperature = 0.2,
    response_format = { type = "json_object" },
    messages = messages,
  }
  local response = gg.makeRequest(
    "https://api.openai.com/v1/chat/completions",
    {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. session.apiKey,
    },
    json.encode(payload),
    "POST",
    CONFIG.AI_TIMEOUT_MS
  )
  if not response or not response.content then
    return nil, "OpenAI response empty"
  end
  local body = json.extract_object(response.content)
  if not body then
    return nil, response.content
  end
  local content = body.choices and body.choices[1] and body.choices[1].message and body.choices[1].message.content
  if not content then
    return nil, response.content
  end
  return content
end

local function callAnthropic(messages)
  local systemText = SYSTEM_PROMPT
  local anthropicMessages = {}
  for _, msg in ipairs(messages) do
    if msg.role ~= "system" then
      anthropicMessages[#anthropicMessages + 1] = {
        role = msg.role,
        content = msg.content,
      }
    else
      systemText = msg.content
    end
  end

  local payload = {
    model = session.model,
    max_tokens = 800,
    temperature = 0.2,
    system = systemText,
    messages = anthropicMessages,
  }

  local response = gg.makeRequest(
    "https://api.anthropic.com/v1/messages",
    {
      ["Content-Type"] = "application/json",
      ["x-api-key"] = session.apiKey,
      ["anthropic-version"] = "2023-06-01",
    },
    json.encode(payload),
    "POST",
    CONFIG.AI_TIMEOUT_MS
  )
  if not response or not response.content then
    return nil, "Anthropic response empty"
  end
  local body = json.extract_object(response.content)
  if not body then
    return nil, response.content
  end
  local content = body.content and body.content[1] and body.content[1].text
  if not content then
    return nil, response.content
  end
  return content
end

local function askAI()
  local context = buildUserContext()
  local messages = {
    { role = "system", content = SYSTEM_PROMPT },
    {
      role = "user",
      content = "Goal: " .. tostring(session.prompt)
        .. "\nCurrent context JSON:\n"
        .. json.encode(context)
        .. "\nReturn the next single GameGuardian command as JSON.",
    },
  }

  local content, err
  if session.provider == "anthropic" then
    content, err = callAnthropic(messages)
  else
    content, err = callOpenAI(messages)
  end

  if not content then
    return nil, err or "AI call failed"
  end

  local cmd = json.extract_object(content)
  if not cmd then
    return nil, "AI did not return JSON: " .. tostring(content)
  end
  return cmd, content
end

local function chooseServerUrl()
  local options = {
    "http://127.0.0.1:3847 (แนะนำ + adb reverse)",
    "http://10.0.2.2:3847 (Android Emulator host)",
    "กรอกเอง",
  }
  local choice = gg.choice(options, nil, "เลือก URL ของ bridge server")
  if choice == 1 then
    CONFIG.SERVER_URL = "http://127.0.0.1:3847"
  elseif choice == 2 then
    CONFIG.SERVER_URL = "http://10.0.2.2:3847"
  elseif choice == 3 then
    local custom = gg.prompt("ใส่ URL เช่น http://192.168.1.10:3847", "http://127.0.0.1:3847", "Server URL")
    if custom and custom ~= "" then
      CONFIG.SERVER_URL = custom
    end
  else
    return false
  end
  return true
end

local function waitForSession()
  toast("รอ prompt + API key จากเว็บ...")
  bridgeLog("info", "สคริปต์ GG เชื่อมต่อแล้ว กำลังรอ session จากเว็บ", {
    serverUrl = CONFIG.SERVER_URL,
  })

  while true do
    local data = fetchSession()
    if data and data.status == "running" and data.prompt and data.prompt ~= "" and data.apiKey and data.apiKey ~= "" then
      session.prompt = data.prompt
      session.apiKey = data.apiKey
      session.provider = data.provider or "openai"
      session.model = data.model or "gpt-4o-mini"
      session.status = "running"
      bridgeLog("info", "ได้รับ session จากเว็บแล้ว เริ่ม AI agent", {
        prompt = session.prompt,
        provider = session.provider,
        model = session.model,
        status = "running",
      })
      return true
    end
    if data and data.status == "stopped" then
      toast("Session ถูกหยุดบนเว็บ")
      return false
    end
    sleep(CONFIG.POLL_MS)
  end
end

local function runAgent()
  bridgeStatus({ status = "running", currentAction = "เริ่ม AI agent" })

  for step = 1, CONFIG.MAX_AI_STEPS do
    fetchSession()
    if session.status == "stopped" then
      bridgeLog("warn", "หยุดตามคำสั่งจากเว็บ", { status = "stopped" })
      return
    end

    bridgeLog("info", "ขั้นตอน AI #" .. step .. " กำลังขอคำสั่ง...", {
      resultsCount = lastResultsCount,
      currentAction = "ask_ai",
    })

    local cmd, raw = askAI()
    if not cmd then
      bridgeLog("error", "เรียก AI ไม่สำเร็จ", { error = raw, status = "error" })
      gg.alert("❌ เรียก AI ไม่สำเร็จ:\n" .. tostring(raw))
      return
    end

    bridgeLog("info", "AI สั่ง: " .. tostring(cmd.action), {
      command = cmd,
      aiRaw = raw,
      currentAction = cmd.action,
    })

    local ok, message, sample, count = executeCommand(cmd)
    bridgeLog(ok and "info" or "warn", message, {
      command = cmd,
      resultsCount = count,
      resultsSample = sample,
      currentAction = cmd.action,
    })

    if cmd.action == "found" then
      gg.alert("✅ พบค่าที่น่าจะใช่แล้ว\n\n" .. message .. "\n\nดูรายละเอียดบนเว็บได้")
      return
    end

    if cmd.action == "give_up" or not ok and cmd.action ~= "wait_user" then
      gg.alert("⚠️ หยุดการทำงาน\n\n" .. message)
      return
    end

    sleep(800)
  end

  bridgeLog("warn", "ครบจำนวนรอบสูงสุดแล้ว", { status = "stopped" })
  gg.alert("⚠️ ครบจำนวนรอบ AI สูงสุด (" .. CONFIG.MAX_AI_STEPS .. ")\nลองปรับ prompt หรือเริ่มใหม่")
end

local function main()
  gg.showUiButton()
  if not chooseServerUrl() then
    return
  end

  local health = bridgeRequest("GET", "/api/health")
  if not health then
    gg.alert(
      "❌ เชื่อม bridge server ไม่ได้\n\n"
        .. "ตรวจสอบ:\n"
        .. "1) รัน npm start ใน gg-ai-bridge\n"
        .. "2) adb reverse tcp:3847 tcp:3847\n"
        .. "3) URL: " .. CONFIG.SERVER_URL
    )
    return
  end

  if not waitForSession() then
    return
  end

  runAgent()
end

main()
