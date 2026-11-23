-- DeepSeek 后端：OpenAI 兼容的 /chat/completions。
-- key/model/base_url 等全部来自 config.backends.deepseek（在 lua 配置里填写）。
local lang = require("fanyi.lang")

local M = {}

M.name = "deepseek"
M.label = "DeepSeek"

local DEFAULT_BASE_URL = "https://api.deepseek.com"
local STATUS_MARK = "\n__FANYI_HTTP_STATUS__:"

local TARGET_NAMES = {
  ["zh-CN"] = "Simplified Chinese",
  ["zh"] = "Simplified Chinese",
  en = "English",
}

local function target_name(target)
  return TARGET_NAMES[target] or target or "the target language"
end

local function default_prompt(target)
  return string.format(
    "You are a translation engine. Translate the user's text into %s. "
      .. "Preserve the original line breaks, punctuation, and formatting. "
      .. "Output only the translated text, with no explanations, quotes, or Markdown fences.",
    target_name(target)
  )
end

local function normalize_key(opts)
  local key = vim.trim(opts.api_key or "")
  return key:gsub("^%s*[Bb][Ee][Aa][Rr][Ee][Rr]%s+", "")
end

local function join_url(base, path)
  base = vim.trim(base or "")
  if base == "" then
    base = DEFAULT_BASE_URL
  end
  return base:gsub("/+$", "") .. path
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
    return "DeepSeek 请求被中断"
  end
  if obj.code == 28 then
    return string.format("DeepSeek 请求超时（%d 秒）", timeout)
  end
  local stderr = obj.stderr and vim.trim(obj.stderr) or ""
  return string.format("DeepSeek 请求失败（curl 退出码 %d）%s", obj.code, stderr ~= "" and ("：" .. stderr) or "")
end

local function api_error(status, body)
  local message
  local ok, data = pcall(vim.json.decode, body)
  if ok and type(data) == "table" and type(data.error) == "table" then
    message = data.error.message or data.error.type
  end
  message = message and tostring(message) or vim.trim(body:sub(1, 300))
  if message == "" then
    message = "未知错误"
  end

  local prefix
  if status == 401 then
    prefix = "DeepSeek 鉴权失败（检查 api_key）"
  elseif status == 402 then
    prefix = "DeepSeek 余额不足"
  elseif status == 429 then
    prefix = "DeepSeek 请求过于频繁，请稍后再试"
  elseif status and status >= 500 then
    prefix = "DeepSeek 服务暂时不可用"
  else
    prefix = "DeepSeek 返回错误"
  end
  return string.format("%s（HTTP %s）：%s", prefix, tostring(status or "?"), message)
end

local function request(text, req, opts, cb)
  local timeout = tonumber(opts.timeout) or 30
  local model = vim.trim(opts.model or "")
  if model == "" then
    model = "deepseek-chat"
  end

  local system_prompt = opts.system_prompt
  if type(system_prompt) ~= "string" or vim.trim(system_prompt) == "" then
    system_prompt = default_prompt(req.target)
  end

  local payload = {
    model = model,
    messages = {
      { role = "system", content = system_prompt },
      { role = "user", content = text },
    },
    stream = false,
  }
  local temperature = tonumber(opts.temperature)
  if temperature then
    payload.temperature = temperature
  end

  local cmd = { "curl", "-sS", "-L", "-m", tostring(timeout) }
  if vim.trim(opts.proxy or "") ~= "" then
    cmd[#cmd + 1] = "--proxy"
    cmd[#cmd + 1] = vim.trim(opts.proxy)
  end

  local args = {
    "-X",
    "POST",
    join_url(opts.base_url, "/chat/completions"),
    "-H",
    "Content-Type: application/json",
    "-H",
    "Authorization: Bearer " .. normalize_key(opts),
    "--data-binary",
    "@-",
    "-w",
    STATUS_MARK .. "%{http_code}",
  }
  for _, arg in ipairs(args) do
    cmd[#cmd + 1] = arg
  end

  vim.system(cmd, { stdin = vim.json.encode(payload), text = true }, function(obj)
    if obj.code ~= 0 then
      cb(nil, curl_error(obj, timeout))
      return
    end

    local body, status = split_status(obj.stdout or "")
    if vim.trim(body) == "" then
      cb(nil, "DeepSeek 返回空响应")
      return
    end

    local ok, data = pcall(vim.json.decode, body)
    if not ok or type(data) ~= "table" then
      if status and status ~= 200 then
        cb(nil, api_error(status, body))
      else
        cb(nil, "无法解析 DeepSeek 响应")
      end
      return
    end

    if type(data.error) == "table" or (status and status ~= 200) then
      cb(nil, api_error(status, body))
      return
    end

    local choices = data.choices
    local choice = type(choices) == "table" and choices[1] or nil
    local message = choice and type(choice.message) == "table" and choice.message or nil
    local content = message and message.content or nil
    if type(content) ~= "string" or vim.trim(content) == "" then
      cb(nil, "DeepSeek 返回空结果")
      return
    end
    cb(vim.trim(content))
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
  if normalize_key(opts) == "" then
    cb(nil, "未配置 DeepSeek API key：请在 lua/plugins/fanyi.lua 的 opts.backends.deepseek.api_key 填写")
    return
  end

  local max_bytes = tonumber(opts.max_bytes)
  if not max_bytes or max_bytes <= 0 then
    max_bytes = 4000
  end
  local chunks = lang.chunk(req.text, max_bytes)
  local results = {}
  local index = 1
  local finished = false

  local function finish(lines, err)
    if finished then
      return
    end
    finished = true
    cb(lines, err)
  end

  local function step()
    local chunk = chunks[index]
    if not chunk then
      local lines = lines_from(table.concat(results, "\n"))
      if #lines == 0 then
        finish(nil, "DeepSeek 返回空结果")
        return
      end
      finish(lines)
      return
    end

    request(chunk, req, opts, function(translated, err)
      if err then
        finish(nil, err)
        return
      end
      results[#results + 1] = translated
      index = index + 1
      step()
    end)
  end

  step()
end

return M
