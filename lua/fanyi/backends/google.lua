-- Google 后端：mode=auto 时有 api_key 走 Cloud Translation v2，否则走 gtx 免费接口（可配 proxy）。
local lang = require("fanyi.lang")

local M = {}

M.name = "google"
M.label = "Google"

local GTX_URL = "https://translate.googleapis.com/translate_a/single"
local CLOUD_URL = "https://translation.googleapis.com/language/translate/v2"
local STATUS_MARK = "\n__FANYI_HTTP_STATUS__:"

local function decode_entities(text)
  text = text:gsub("&#(%d+);", function(code)
    local ok, char = pcall(vim.fn.nr2char, tonumber(code))
    return ok and char or ""
  end)
  text = text:gsub("&#[xX](%x+);", function(code)
    local ok, char = pcall(vim.fn.nr2char, tonumber(code, 16))
    return ok and char or ""
  end)
  text = text:gsub("&quot;", '"'):gsub("&apos;", "'")
  text = text:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&nbsp;", " ")
  text = text:gsub("&amp;", "&")
  return text
end

local function split_status(stdout)
  local pos = stdout:find(STATUS_MARK, 1, true)
  if not pos then
    return stdout, nil
  end
  local code = tonumber(stdout:sub(pos + #STATUS_MARK):match("^%s*(%d%d%d)"))
  return stdout:sub(1, pos - 1), code
end

local function curl_error(obj, timeout)
  if obj.code == nil then
    return "Google 请求被中断"
  end
  if obj.code == 28 then
    return string.format("Google 请求超时（%d 秒；gtx 通常需要代理）", timeout)
  end
  local stderr = obj.stderr and vim.trim(obj.stderr) or ""
  return string.format("Google 请求失败（curl 退出码 %d）%s", obj.code, stderr ~= "" and ("：" .. stderr) or "")
end

local function normalize_mode(opts)
  local mode = vim.trim(opts.mode or "auto"):lower()
  local key = vim.trim(opts.api_key or "")
  local proxy = vim.trim(opts.proxy or "")
  key = key:gsub("^%s*[Bb][Ee][Aa][Rr][Ee][Rr]%s+", "")

  if mode == "" or mode == "auto" then
    if key ~= "" then
      mode = "cloud"
    elseif proxy ~= "" then
      mode = "gtx"
    else
      return nil,
        "未配置 Google 翻译：请在 lua/plugins/fanyi.lua 的 opts.backends.google 里填 api_key（Cloud v2）或 proxy（gtx）"
    end
  end

  if mode == "cloud" and key == "" then
    return nil, "Google 的 cloud 模式需要 api_key：请在 lua/plugins/fanyi.lua 的 opts.backends.google.api_key 填写"
  end
  if mode ~= "cloud" and mode ~= "gtx" then
    return nil, "Google mode 无效（可选 auto/cloud/gtx）：" .. tostring(mode)
  end
  return { mode = mode, key = key, proxy = proxy }
end

local function run_curl(cmd, stdin, timeout, cb)
  local opts = { text = true }
  if stdin then
    opts.stdin = stdin
  end
  vim.system(cmd, opts, function(obj)
    if obj.code ~= 0 then
      cb(nil, curl_error(obj, timeout))
      return
    end
    cb(obj.stdout or "")
  end)
end

local function request_gtx(text, target, opts, cfg, cb)
  local timeout = tonumber(opts.timeout) or 15
  local cmd = { "curl", "-sS", "-L", "-m", tostring(timeout) }
  if cfg.proxy ~= "" then
    cmd[#cmd + 1] = "--proxy"
    cmd[#cmd + 1] = cfg.proxy
  end

  local args = {
    "--get",
    GTX_URL,
    "--data-urlencode",
    "client=gtx",
    "--data-urlencode",
    "sl=auto",
    "--data-urlencode",
    "tl=" .. target,
    "--data-urlencode",
    "dt=t",
    "--data-urlencode",
    "q=" .. text,
    "-w",
    STATUS_MARK .. "%{http_code}",
  }
  for _, arg in ipairs(args) do
    cmd[#cmd + 1] = arg
  end

  run_curl(cmd, nil, timeout, function(stdout, err)
    if err then
      cb(nil, err)
      return
    end

    local body, status = split_status(stdout)
    body = body:gsub("^%)%]}'%s*\n", "")
    if vim.trim(body) == "" then
      cb(nil, "Google 返回空响应（检查代理）")
      return
    end

    local ok, data = pcall(vim.json.decode, body)
    if not ok or type(data) ~= "table" then
      if status and status ~= 200 then
        cb(nil, string.format("Google 返回 HTTP %d（检查代理/配额）", status))
      else
        cb(nil, "无法解析 Google 响应（检查代理是否可用）")
      end
      return
    end
    if status and status ~= 200 then
      cb(nil, string.format("Google 返回 HTTP %d（检查代理/配额）", status))
      return
    end

    local segments = data[1]
    if type(segments) ~= "table" then
      cb(nil, "Google 返回空结果")
      return
    end
    local parts = {}
    for _, segment in ipairs(segments) do
      if type(segment) == "table" and type(segment[1]) == "string" then
        parts[#parts + 1] = segment[1]
      end
    end

    local translated = table.concat(parts)
    if vim.trim(translated) == "" then
      cb(nil, "Google 返回空结果")
      return
    end
    cb(vim.trim(decode_entities(translated)))
  end)
end

local function request_cloud(text, target, opts, cfg, cb)
  local timeout = tonumber(opts.timeout) or 15
  local payload = vim.json.encode({
    q = { text },
    target = target,
    format = "text",
  })

  local cmd = { "curl", "-sS", "-L", "-m", tostring(timeout) }
  if cfg.proxy ~= "" then
    cmd[#cmd + 1] = "--proxy"
    cmd[#cmd + 1] = cfg.proxy
  end

  local args = {
    "-X",
    "POST",
    CLOUD_URL,
    "-H",
    "Content-Type: application/json",
    "-H",
    "X-Goog-Api-Key: " .. cfg.key,
    "--data-binary",
    "@-",
    "-w",
    STATUS_MARK .. "%{http_code}",
  }
  for _, arg in ipairs(args) do
    cmd[#cmd + 1] = arg
  end

  run_curl(cmd, payload, timeout, function(stdout, err)
    if err then
      cb(nil, err)
      return
    end

    local body, status = split_status(stdout)
    if vim.trim(body) == "" then
      cb(nil, "Google 返回空响应")
      return
    end

    local ok, data = pcall(vim.json.decode, body)
    if not ok or type(data) ~= "table" then
      if status and status ~= 200 then
        cb(nil, string.format("Google 返回 HTTP %d：%s", status, vim.trim(body:sub(1, 200))))
      else
        cb(nil, "无法解析 Google 响应")
      end
      return
    end

    if type(data.error) == "table" then
      local message = tostring(data.error.message or data.error.status or "未知错误")
      local hint = ""
      if status == 403 then
        hint = "（检查 API key、Cloud Translation API 是否启用、配额）"
      elseif status == 400 then
        if message:lower():find("api key", 1, true) then
          hint = "（API key 无效）"
        else
          hint = "（检查 target 语言代码）"
        end
      end
      cb(
        nil,
        string.format(
          "Google Cloud 错误（HTTP %s）：%s%s",
          tostring(status or data.error.code or "?"),
          message,
          hint
        )
      )
      return
    end

    if status and status ~= 200 then
      cb(nil, string.format("Google 返回 HTTP %d", status))
      return
    end

    local translations = type(data.data) == "table" and data.data.translations or nil
    local translated = type(translations) == "table" and translations[1] and translations[1].translatedText or nil
    if type(translated) ~= "string" or vim.trim(translated) == "" then
      cb(nil, "Google 返回空结果")
      return
    end
    cb(vim.trim(decode_entities(translated)))
  end)
end

local function lines_from(text)
  local lines = vim.split((text or ""):gsub("\r\n", "\n"), "\n", { plain = true })
  while #lines > 0 and vim.trim(lines[1]) == "" do
    table.remove(lines, 1)
  end
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end
  return lines
end

---@param req fanyi.Request
---@param cb fun(lines?: string[], err?: string)
function M.translate(req, cb)
  local opts = req.opts or {}
  local cfg, err = normalize_mode(opts)
  if not cfg then
    cb(nil, err)
    return
  end

  local max_bytes = tonumber(opts.max_bytes)
  if not max_bytes or max_bytes <= 0 then
    max_bytes = 4500
  end
  local chunks = lang.chunk(req.text, max_bytes)
  local results = {}
  local index = 1
  local finished = false

  local function finish(lines, error_message)
    if finished then
      return
    end
    finished = true
    cb(lines, error_message)
  end

  local function step()
    local chunk = chunks[index]
    if not chunk then
      local lines = lines_from(table.concat(results, "\n"))
      if #lines == 0 then
        finish(nil, "Google 返回空结果")
        return
      end
      finish(lines)
      return
    end

    local function done(translated, request_err)
      if request_err then
        finish(nil, request_err)
        return
      end
      results[#results + 1] = translated
      index = index + 1
      step()
    end

    if cfg.mode == "cloud" then
      request_cloud(chunk, req.target, opts, cfg, done)
    else
      request_gtx(chunk, req.target, opts, cfg, done)
    end
  end

  step()
end

return M
