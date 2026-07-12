--[[
  GG AI Memory Hunter v2
  Hunt + Module/Offset Resolver + Interactive Mode
  Requires json.lua in the same folder.
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
    local ok, mod = pcall(function() return dofile(path) end)
    if ok and mod then return mod end
    local loader = loadfile(path)
    if loader then
      local mod = loader()
      if mod then return mod end
    end
  end
  return nil
end

local json = loadJsonModule()
if not json then
  gg.alert("ไม่พบ json.lua\nวางไฟล์ json.lua ในโฟลเดอร์เดียวกับสคริปต์")
  return
end

local CONFIG = {
  SERVER_URL = "http://127.0.0.1:3847",
  POLL_MS = 1500,
  INTERACTIVE_POLL_MS = 500,
  AI_TIMEOUT_MS = 60000,
  MAX_AI_STEPS = 45,
  MAX_RESULTS_SAMPLE = 8,
  MAX_HISTORY = 16,
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

local FLAG_NAME = {
  [gg.TYPE_DWORD] = "TYPE_DWORD",
  [gg.TYPE_FLOAT] = "TYPE_FLOAT",
  [gg.TYPE_QWORD] = "TYPE_QWORD",
  [gg.TYPE_WORD] = "TYPE_WORD",
  [gg.TYPE_BYTE] = "TYPE_BYTE",
  [gg.TYPE_DOUBLE] = "TYPE_DOUBLE",
}

local session = {
  prompt = nil,
  apiKey = nil,
  provider = "openai",
  model = "gpt-4o-mini",
  status = "idle",
  mode = "hunting",
  game = "",
  scriptStyle = "simple_toggle",
}

local history = {}
local findings = {}
local lastResultsSample = {}
local lastResultsCount = 0
local selectedResultIndex = 1
local baselines = {}

local SYSTEM_PROMPT = [[You control GameGuardian for Android game memory hacking.
Reply ONE JSON object only.

Actions:
- search, refine, clear, get_results, freeze, wait_user, give_up
- resolve_module: convert found address to module + offset
- probe_type: test whether value should be written as FLOAT or DWORD
- capture_baseline: store current value as original/off value
- found: finalize structured finding for script export

Schema:
{
  "action": "...",
  "type": "DWORD|FLOAT|...",
  "value": "search text",
  "refine_value": "value",
  "condition": "equal|decreased|increased|changed|unchanged",
  "freeze_value": "number",
  "pick": [{"index":1}],
  "module_pattern": "libgame.so",
  "name": "immortal_hp",
  "label": "เปิดโปรอมตะ",
  "script_style": "simple_toggle|preset_values|multi_hack",
  "on_value": 999,
  "off_value": 0.814,
  "on_display": "999.0",
  "off_display": "0.814",
  "presets": [{"label":"เพิ่ม 10%","value":0.8954}],
  "message": "Thai message",
  "reasoning": "brief"
}

Rules:
- Work like a human using GameGuardian.
- Before found, run resolve_module and probe_type when possible.
- Prefer module+offset output, never only absolute address.
- Use wait_user when the player must change game state.
- Use found only when module, offset, flags, on/off values are known.
]]

local function toast(msg) gg.toast(msg) end
local function sleep(ms) gg.sleep(ms) end

local function bridgeRequest(method, path, bodyTable)
  local url = CONFIG.SERVER_URL .. path
  local headers = { ["Content-Type"] = "application/json" }
  local body = bodyTable and json.encode(bodyTable) or nil
  local response = gg.makeRequest(url, headers, body, method)
  if not response or not response.content then return nil, "no response" end
  if response.code and response.code >= 400 then
    return nil, "http " .. tostring(response.code)
  end
  local ok, data = pcall(json.decode, response.content)
  if ok then return data end
  return response.content
end

local function bridgeLog(level, message, detail)
  bridgeRequest("POST", "/api/gg/log", { level = level, message = message, detail = detail, source = "gg" })
end

local function bridgeStatus(payload)
  bridgeRequest("POST", "/api/gg/status", payload)
end

local function pushFindingsToServer()
  bridgeRequest("POST", "/api/gg/findings", {
    findings = findings,
    game = session.game,
    scriptStyle = session.scriptStyle,
  })
end

local function fetchSession()
  local data = bridgeRequest("GET", "/api/gg/session")
  if type(data) == "table" then
    session.prompt = data.prompt
    session.apiKey = data.apiKey
    session.provider = data.provider or session.provider
    session.model = data.model or session.model
    session.status = data.status or session.status
    session.mode = data.mode or session.mode
    session.game = data.game or session.game
    session.scriptStyle = data.scriptStyle or session.scriptStyle
    if type(data.findings) == "table" and #data.findings > 0 then
      findings = data.findings
    end
    return data
  end
  return nil
end

local function fetchUserAck()
  local data = bridgeRequest("GET", "/api/gg/user-ack")
  if type(data) == "table" and data.ack then return data.ack end
  return nil
end

local function fetchNextCommand()
  local data = bridgeRequest("GET", "/api/gg/commands/next")
  if type(data) == "table" then return data.command end
  return nil
end

local function reportCommandResult(command_id, ok, message, data)
  bridgeRequest("POST", "/api/gg/commands/result", {
    command_id = command_id,
    ok = ok,
    message = message,
    data = data,
  })
end

local function mapType(typeName)
  if not typeName then return gg.TYPE_DWORD end
  return TYPE_MAP[string.upper(tostring(typeName))] or gg.TYPE_DWORD
end

local function flagName(flag)
  return FLAG_NAME[flag] or "TYPE_DWORD"
end

local function pushHistory(entry)
  history[#history + 1] = entry
  if #history > CONFIG.MAX_HISTORY then table.remove(history, 1) end
end

local function formatAddress(addr)
  return string.format("0x%X", tonumber(addr) or 0)
end

local function formatOffset(offset)
  return string.format("0x%X", tonumber(offset) or 0)
end

local function sampleResults()
  local count = gg.getResultsCount()
  lastResultsCount = count
  lastResultsSample = {}
  if count <= 0 then return lastResultsSample, count end
  local take = math.min(count, CONFIG.MAX_RESULTS_SAMPLE)
  local results = gg.getResults(take)
  for i, item in ipairs(results) do
    lastResultsSample[#lastResultsSample + 1] = {
      index = i,
      address = formatAddress(item.address),
      address_num = tonumber(item.address),
      value = tostring(item.value),
      flags = tonumber(item.flags) or 0,
      flag_name = flagName(item.flags),
    }
  end
  return lastResultsSample, count
end

local function getResultByIndex(index)
  local count = gg.getResultsCount()
  if count <= 0 then return nil end
  local idx = tonumber(index) or 1
  local results = gg.getResults(math.min(count, 20))
  return results[idx]
end

local function findModuleForAddress(address)
  local addr = tonumber(address)
  if not addr then return nil end
  local ranges = gg.getRangesList()
  local best = nil
  for _, range in ipairs(ranges) do
    local startAddr = tonumber(range.start)
    local endAddr = tonumber(range["end"])
    if startAddr and endAddr and addr >= startAddr and addr <= endAddr then
      best = {
        name = range.name or "unknown",
        start = startAddr,
        ["end"] = endAddr,
      }
      break
    end
  end
  return best
end

local function resolveModuleOffset(address, modulePattern)
  local addr = tonumber(address)
  if not addr then return nil end
  local ranges = gg.getRangesList()
  for _, range in ipairs(ranges) do
    local name = range.name or ""
    if (not modulePattern or modulePattern == "") or name:find(modulePattern, 1, true) then
      local startAddr = tonumber(range.start)
      local endAddr = tonumber(range["end"])
      if startAddr and endAddr and addr >= startAddr and addr <= endAddr then
        return {
          module = name,
          module_pattern = modulePattern or name,
          base = startAddr,
          offset = addr - startAddr,
          offset_hex = formatOffset(addr - startAddr),
          address = formatAddress(addr),
        }
      end
    end
  end
  local fallback = findModuleForAddress(addr)
  if fallback then
    return {
      module = fallback.name,
      module_pattern = fallback.name,
      base = fallback.start,
      offset = addr - fallback.start,
      offset_hex = formatOffset(addr - fallback.start),
      address = formatAddress(addr),
    }
  end
  return nil
end

local function readAtAddress(address, flags)
  local items = {{ address = tonumber(address), flags = flags }}
  local values = gg.getValues(items)
  if values and values[1] then return values[1].value end
  return nil
end

local function writeAtAddress(address, flags, value, freeze)
  local item = {
    address = tonumber(address),
    flags = flags,
    value = value,
    freeze = freeze or false,
  }
  gg.setValues({ item })
  if freeze then gg.addListItems({ item }) end
  return item
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
  pushHistory({ step = "search", value = value, type = cmd.type or "DWORD", count = count })
  return true, "search เหลือ " .. count .. " ผลลัพธ์", sample, count
end

local function executeRefine(cmd)
  local vtype = mapType(cmd.type)
  local text = conditionToRefineText(cmd.condition, cmd.refine_value or cmd.value)
  gg.refineNumber(text, vtype, false, gg.SIGN_EQUAL, 0, -1)
  local sample, count = sampleResults()
  pushHistory({ step = "refine", condition = cmd.condition, count = count })
  return true, "refine เหลือ " .. count .. " ผลลัพธ์", sample, count
end

local function executeClear()
  gg.clearResults()
  lastResultsSample = {}
  lastResultsCount = 0
  return true, "ล้างผลลัพธ์แล้ว", {}, 0
end

local function executeGetResults()
  local sample, count = sampleResults()
  return true, "ดึงตัวอย่าง " .. #sample .. " รายการ", sample, count
end

local function executeResolveModule(cmd)
  local pick = cmd.pick and cmd.pick[1] or { index = selectedResultIndex }
  local target = getResultByIndex(pick.index)
  if not target then return false, "ไม่มีผลลัพธ์สำหรับ resolve_module", lastResultsSample, lastResultsCount end
  local resolved = resolveModuleOffset(target.address, cmd.module_pattern or "libgame.so")
  if not resolved then return false, "ไม่พบ module ของ address นี้", lastResultsSample, lastResultsCount end
  selectedResultIndex = pick.index
  pushHistory({ step = "resolve_module", resolved = resolved })
  bridgeLog("info", "resolve module สำเร็จ", { resolved = resolved })
  return true, resolved.module .. " + " .. resolved.offset_hex, { resolved = resolved }, lastResultsCount
end

local function executeProbeType(cmd)
  local pick = cmd.pick and cmd.pick[1] or { index = selectedResultIndex }
  local target = getResultByIndex(pick.index)
  if not target then return false, "ไม่มีผลลัพธ์สำหรับ probe_type", lastResultsSample, lastResultsCount end

  local addr = target.address
  local floatVal = readAtAddress(addr, gg.TYPE_FLOAT)
  local dwordVal = readAtAddress(addr, gg.TYPE_DWORD)
  local chosen = "TYPE_FLOAT"
  local writeValue = floatVal

  if cmd.prefer == "DWORD" then
    chosen = "TYPE_DWORD"
    writeValue = dwordVal
  elseif floatVal == nil and dwordVal ~= nil then
    chosen = "TYPE_DWORD"
    writeValue = dwordVal
  end

  local probe = {
    address = formatAddress(addr),
    float_value = floatVal,
    dword_value = dwordVal,
    chosen_flags = chosen,
    chosen_value = writeValue,
  }
  pushHistory({ step = "probe_type", probe = probe })
  return true, "probe type เลือก " .. chosen, { probe = probe }, lastResultsCount
end

local function executeCaptureBaseline(cmd)
  local pick = cmd.pick and cmd.pick[1] or { index = selectedResultIndex }
  local target = getResultByIndex(pick.index)
  if not target then return false, "ไม่มีผลลัพธ์สำหรับ capture_baseline", lastResultsSample, lastResultsCount end
  local key = formatAddress(target.address)
  baselines[key] = {
    value = target.value,
    flags = target.flags,
    flag_name = flagName(target.flags),
  }
  pushHistory({ step = "capture_baseline", baseline = baselines[key] })
  return true, "เก็บ baseline แล้ว", { baseline = baselines[key] }, lastResultsCount
end

local function executeStructuredFound(cmd)
  local pick = cmd.pick and cmd.pick[1] or { index = selectedResultIndex }
  local target = getResultByIndex(pick.index)
  if not target then
    local sample = lastResultsSample[1]
    if not sample then return false, "ไม่มีผลลัพธ์สำหรับ found", {}, 0 end
    target = { address = sample.address_num, flags = sample.flags, value = sample.value }
  end

  local resolved = resolveModuleOffset(target.address, cmd.module_pattern or "libgame.so")
  if not resolved then return false, "found ไม่สำเร็จ: ไม่มี module/offset", lastResultsSample, lastResultsCount end

  local baseline = baselines[formatAddress(target.address)]
  local flags = cmd.flags or (baseline and baseline.flag_name) or flagName(target.flags)
  local finding = {
    id = cmd.id or ("finding_" .. tostring(#findings + 1)),
    name = cmd.name or "target",
    label = cmd.label or cmd.name or "เป้าหมาย",
    module = resolved.module_pattern or "libgame.so",
    offset = resolved.offset_hex,
    flags = flags,
    address = resolved.address,
    verified = true,
    values = {
      on = cmd.on_value or cmd.freeze_value or target.value,
      off = cmd.off_value or (baseline and baseline.value) or target.value,
      on_display = tostring(cmd.on_display or cmd.on_value or ""),
      off_display = tostring(cmd.off_display or cmd.off_value or ""),
      original = baseline and baseline.value or target.value,
      presets = cmd.presets or {},
    },
    freeze_on_enable = cmd.freeze_on_enable ~= false,
  }

  findings[#findings + 1] = finding
  if cmd.script_style then session.scriptStyle = cmd.script_style end
  if cmd.game then session.game = cmd.game end

  pushFindingsToServer()
  bridgeStatus({ status = "found", mode = "interactive", currentAction = "พบค่าแล้ว เข้าสู่โหมด interactive" })
  bridgeLog("success", cmd.message or "พบค่าและแปลงเป็น offset แล้ว", {
    status = "found",
    mode = "interactive",
    findings = findings,
  })

  session.mode = "interactive"
  pushHistory({ step = "found", finding = finding })
  return true, "พบค่า " .. finding.label .. " ที่ " .. finding.offset, { finding = finding, findings = findings }, lastResultsCount
end

local function executeWaitUser(cmd)
  local message = cmd.message or "ทำขั้นตอนในเกม แล้วกดยืนยันบนเว็บ"
  bridgeStatus({ status = "waiting_user", currentAction = message })
  bridgeLog("warn", message, { status = "waiting_user" })
  local waited = 0
  while waited < 300000 do
    fetchSession()
    if session.status == "stopped" then return false, "ถูกสั่งหยุด", lastResultsSample, lastResultsCount end
    if fetchUserAck() then
      bridgeStatus({ status = "running", currentAction = "ผู้ใช้ยืนยันแล้ว" })
      return true, "ผู้ใช้ยืนยันแล้ว", sampleResults()
    end
    sleep(1000)
    waited = waited + 1000
  end
  return false, "หมดเวลารอผู้ใช้", lastResultsSample, lastResultsCount
end

local function executeFreeze(cmd)
  local pick = cmd.pick and cmd.pick[1] or { index = selectedResultIndex }
  local target = getResultByIndex(pick.index)
  if not target then return false, "ไม่มีผลลัพธ์ให้ freeze", {}, lastResultsCount end
  writeAtAddress(target.address, target.flags, cmd.freeze_value or target.value, true)
  return true, "freeze แล้ว", { address = formatAddress(target.address) }, lastResultsCount
end

local function executeCommand(cmd)
  if not cmd or not cmd.action then return false, "คำสั่งไม่ถูกต้อง", lastResultsSample, lastResultsCount end
  local action = string.lower(cmd.action)
  bridgeStatus({ currentAction = action, resultsCount = lastResultsCount })

  if action == "search" then return executeSearch(cmd)
  elseif action == "refine" then return executeRefine(cmd)
  elseif action == "clear" then return executeClear()
  elseif action == "get_results" then return executeGetResults()
  elseif action == "resolve_module" then return executeResolveModule(cmd)
  elseif action == "probe_type" then return executeProbeType(cmd)
  elseif action == "capture_baseline" then return executeCaptureBaseline(cmd)
  elseif action == "freeze" then return executeFreeze(cmd)
  elseif action == "wait_user" then return executeWaitUser(cmd)
  elseif action == "found" then return executeStructuredFound(cmd)
  elseif action == "give_up" then
    bridgeLog("warn", cmd.message or "AI หยุด", { status = "stopped" })
    return false, cmd.message or "AI หยุด", lastResultsSample, lastResultsCount
  end
  return false, "ไม่รู้จัก action: " .. action, lastResultsSample, lastResultsCount
end

local function getFindingById(id)
  for _, item in ipairs(findings) do
    if item.id == id then return item end
  end
  return findings[1]
end

local function executeInteractiveCommand(command)
  if not command then return end
  local finding = getFindingById(command.target)
  local payload = command.payload or {}

  if command.type == "read_value" then
    if not finding then
      reportCommandResult(command.id, false, "ไม่พบ finding", nil)
      return
    end
    local baseRange = resolveModuleOffset(tonumber(finding.address, 16) or 0, finding.module)
    local addr = (baseRange and baseRange.base or 0) + tonumber(finding.offset, 16)
    local value = readAtAddress(addr, mapType(finding.flags))
    reportCommandResult(command.id, true, "อ่านค่าสำเร็จ", { value = value, finding = finding })
    return
  end

  if command.type == "set_value" or command.type == "freeze" or command.type == "unfreeze" or command.type == "test_value" then
    if not finding then
      reportCommandResult(command.id, false, "ไม่พบ finding", nil)
      return
    end
    local ranges = gg.getRangesList()
    local base = nil
    for _, range in ipairs(ranges) do
      if (range.name or ""):find(finding.module or "libgame.so", 1, true) then
        base = tonumber(range.start)
        break
      end
    end
    if not base then
      reportCommandResult(command.id, false, "ไม่พบ module " .. tostring(finding.module), nil)
      return
    end
    local addr = base + tonumber(finding.offset, 16)
    local flags = mapType(finding.flags)
    local value = payload.value or finding.values.on
    local freeze = command.type == "freeze" or payload.freeze == true
    if command.type == "unfreeze" then freeze = false end
    writeAtAddress(addr, flags, value, freeze)

    if command.type == "test_value" then
      finding.verified = true
      pushFindingsToServer()
    end

    reportCommandResult(command.id, true, "ตั้งค่า " .. tostring(value) .. (freeze and " และ freeze" or ""), {
      value = value,
      freeze = freeze,
      finding = finding,
    })
    return
  end

  reportCommandResult(command.id, false, "ไม่รู้จักคำสั่ง " .. tostring(command.type), nil)
end

local function buildUserContext()
  local sample, count = sampleResults()
  return {
    goal = session.prompt,
    game = session.game,
    scriptStyle = session.scriptStyle,
    resultsCount = count,
    resultsSample = sample,
    findings = findings,
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
    { ["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. session.apiKey },
    json.encode(payload),
    "POST",
    CONFIG.AI_TIMEOUT_MS
  )
  if not response or not response.content then return nil, "OpenAI empty" end
  local body = json.extract_object(response.content)
  local content = body and body.choices and body.choices[1] and body.choices[1].message and body.choices[1].message.content
  if not content then return nil, response.content end
  return content
end

local function callAnthropic(messages)
  local systemText = SYSTEM_PROMPT
  local anthropicMessages = {}
  for _, msg in ipairs(messages) do
    if msg.role ~= "system" then
      anthropicMessages[#anthropicMessages + 1] = { role = msg.role, content = msg.content }
    else
      systemText = msg.content
    end
  end
  local payload = {
    model = session.model,
    max_tokens = 900,
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
  if not response or not response.content then return nil, "Anthropic empty" end
  local body = json.extract_object(response.content)
  local content = body and body.content and body.content[1] and body.content[1].text
  if not content then return nil, response.content end
  return content
end

local function askAI()
  local context = buildUserContext()
  local messages = {
    { role = "system", content = SYSTEM_PROMPT },
    {
      role = "user",
      content = "Goal: " .. tostring(session.prompt)
        .. "\nContext:\n" .. json.encode(context)
        .. "\nReturn next command JSON.",
    },
  }
  local content
  if session.provider == "anthropic" then
    content = select(1, callAnthropic(messages))
  else
    content = select(1, callOpenAI(messages))
  end
  if not content then return nil, "AI call failed" end
  local cmd = json.extract_object(content)
  if not cmd then return nil, "AI JSON invalid" end
  return cmd, content
end

local function chooseServerUrl()
  local options = {
    "http://127.0.0.1:3847 (adb reverse)",
    "http://10.0.2.2:3847 (Emulator host)",
    "กำหนดเอง",
  }
  local choice = gg.choice(options, nil, "Bridge Server URL")
  if choice == 1 then CONFIG.SERVER_URL = "http://127.0.0.1:3847"
  elseif choice == 2 then CONFIG.SERVER_URL = "http://10.0.2.2:3847"
  elseif choice == 3 then
    local custom = gg.prompt("URL", "http://127.0.0.1:3847", "Server")
    if custom and custom ~= "" then CONFIG.SERVER_URL = custom end
  else return false end
  return true
end

local function waitForSession()
  bridgeLog("info", "GG script เชื่อมต่อแล้ว รอ session", { serverUrl = CONFIG.SERVER_URL })
  while true do
    local data = fetchSession()
    if data and data.status == "running" and data.prompt and data.prompt ~= "" and data.apiKey and data.apiKey ~= "" then
      session.prompt = data.prompt
      session.apiKey = data.apiKey
      session.provider = data.provider or "openai"
      session.model = data.model or "gpt-4o-mini"
      session.status = "running"
      session.mode = data.mode or "hunting"
      session.game = data.game or ""
      session.scriptStyle = data.scriptStyle or "simple_toggle"
      bridgeLog("info", "เริ่ม session", { prompt = session.prompt, mode = session.mode })
      return true
    end
    if data and data.status == "stopped" then return false end
    sleep(CONFIG.POLL_MS)
  end
end

local function runInteractiveLoop()
  bridgeStatus({ status = "found", mode = "interactive", currentAction = "โหมด interactive" })
  bridgeLog("info", "เข้าสู่โหมด interactive", { mode = "interactive", findings = findings })
  toast("เข้าสู่โหมด interactive")

  while true do
    fetchSession()
    if session.status == "stopped" then
      bridgeLog("warn", "หยุด interactive mode", { status = "stopped" })
      return
    end
    local command = fetchNextCommand()
    if command then executeInteractiveCommand(command) end
    sleep(CONFIG.INTERACTIVE_POLL_MS)
  end
end

local function runAgent()
  bridgeStatus({ status = "running", mode = "hunting", currentAction = "เริ่ม AI hunt" })

  for step = 1, CONFIG.MAX_AI_STEPS do
    fetchSession()
    if session.status == "stopped" then return end

    bridgeLog("info", "AI ขั้นตอน #" .. step, { currentAction = "ask_ai", resultsCount = lastResultsCount })
    local cmd, raw = askAI()
    if not cmd then
      bridgeLog("error", "เรียก AI ไม่สำเร็จ", { error = raw, status = "error" })
      gg.alert("เรียก AI ไม่สำเร็จ:\n" .. tostring(raw))
      return
    end

    bridgeLog("info", "AI: " .. tostring(cmd.action), { command = cmd, aiRaw = raw })
    local ok, message = executeCommand(cmd)
    bridgeLog(ok and "info" or "warn", message, { command = cmd, currentAction = cmd.action })

    if cmd.action == "found" and ok then
      gg.alert("พบค่าแล้ว\n" .. message .. "\nเข้าสู่โหมด interactive บนเว็บ")
      runInteractiveLoop()
      return
    end
    if cmd.action == "give_up" or (not ok and cmd.action ~= "wait_user") then
      gg.alert("หยุดการทำงาน\n" .. tostring(message))
      return
    end
    sleep(700)
  end
  bridgeLog("warn", "ครบจำนวนรอบสูงสุด", { status = "stopped" })
end

local function main()
  gg.showUiButton()
  if not chooseServerUrl() then return end
  if not bridgeRequest("GET", "/api/health") then
    gg.alert("เชื่อม server ไม่ได้\n1) npm start\n2) adb reverse tcp:3847 tcp:3847")
    return
  end
  if not waitForSession() then return end
  if session.mode == "interactive" and #findings > 0 then
    runInteractiveLoop()
  else
    runAgent()
  end
end

main()
