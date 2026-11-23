-- MyMemory 后端：免费、无需 API key。
-- 已知坑（详见 README）：不支持 auto 源语言；中文源语言写 zh 而不是 zh-CN；
-- 单次查询约 500 字节上限；响应可能带 <g id="..."> 对齐标记。
local lang = require("fanyi.lang")

local M = {}

M.name = "mymemory"
M.label = "MyMemory"

local ENDPOINT = "https://api.mymemory.translated.net/get"

local function source_lang(target)
  return target == "en" and "zh" or "en"
end

-- 去掉 MyMemory 的对齐标记并解码常见 HTML 实体。
local function clean_text(text)
  text = text:gsub("<%s*g[^>]*>", ""):gsub("<%s*/%s*g%s*>", "")
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

local ERROR_MARKERS = {
  "INVALID SOURCE LANGUAGE",
  "MYMEMORY WARNING",
  "QUERY LENGTH LIMIT",
  "PLEASE SELECT TWO DISTINCT LANGUAGES",
}

local function parse_body(body)
  local ok, data = pcall(vim.json.decode, body)
  if not ok or type(data) ~= "table" then
    return nil, "无法解析翻译响应"
  end

  local response = data.responseData
  local translated = type(response) == "table" and response.translatedText or nil
  if type(translated) ~= "string" or vim.trim(translated) == "" then
    return nil, "翻译服务返回空结果"
  end

  local upper = translated:upper()
  for _, marker in ipairs(ERROR_MARKERS) do
    if upper:find(marker, 1, true) then
      return nil, "翻译服务拒绝请求：" .. translated
    end
  end

  local status = tonumber(data.responseStatus)
  if status and status ~= 200 then
    return nil, string.format("翻译服务返回 HTTP %s：%s", tostring(data.responseStatus), translated)
  end

  local cleaned = clean_text(translated)
  if vim.trim(cleaned) == "" then
    return nil, "翻译服务返回空结果"
  end
  return cleaned
end

local function request(text, target, opts, cb)
  local timeout = tonumber(opts.timeout) or 8
  local cmd = {
    "curl",
    "-sL",
    "-m",
    tostring(timeout),
    "--get",
    ENDPOINT,
    "--data-urlencode",
    "q=" .. text,
    "--data-urlencode",
    "langpair=" .. source_lang(target) .. "|" .. target,
  }

  vim.system(cmd, { text = true }, function(obj)
    if obj.code ~= 0 then
      if obj.code == nil then
        cb(nil, "翻译请求被中断")
      elseif obj.code == 28 then
        cb(nil, string.format("翻译请求超时（%d 秒）", timeout))
      else
        local stderr = obj.stderr and vim.trim(obj.stderr) or ""
        cb(
          nil,
          string.format("翻译请求失败（curl 退出码 %d）%s", obj.code, stderr ~= "" and ("：" .. stderr) or "")
        )
      end
      return
    end

    local body = obj.stdout or ""
    if vim.trim(body) == "" then
      cb(nil, "翻译服务返回空响应")
      return
    end

    local translated, err = parse_body(body)
    if not translated then
      cb(nil, err)
      return
    end
    cb(translated)
  end)
end

---@param req fanyi.Request
---@param cb fun(lines?: string[], err?: string)
function M.translate(req, cb)
  local opts = req.opts or {}
  local chunks = lang.chunk(req.text, opts.max_bytes)
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
      local lines = vim.split(table.concat(results, "\n"), "\n", { plain = true })
      while #lines > 0 and vim.trim(lines[1]) == "" do
        table.remove(lines, 1)
      end
      while #lines > 0 and vim.trim(lines[#lines]) == "" do
        table.remove(lines)
      end
      if #lines == 0 then
        finish(nil, "翻译服务返回空结果")
        return
      end
      finish(lines)
      return
    end

    request(chunk, req.target, opts, function(translated, err)
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
