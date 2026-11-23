-- 本地语言检测 + 长文本分块。MyMemory 不支持 auto 源语言，所以检测必须在这里做。
local M = {}

--- 文本里是否含汉字（CJK 统一表意文字）。
---@param text string
---@return boolean
function M.has_han(text)
  return vim.fn.match(text, "[一-鿿]") ~= -1
end

--- 根据文本内容决定目标语言：含汉字 → 英文，否则 → 中文。
---@param text string
---@param target table -- { han = "en", western = "zh-CN" }
---@return string
function M.target_for(text, target)
  return M.has_han(text) and target.han or target.western
end

-- 在句末标点（含换行）之后切分，\zs 让标点留在上一段的末尾。
local SENTENCE_PATTERN = "\\m[。！？!?.\n]\\zs"

local function split_sentences(text)
  return vim.fn.split(text, SENTENCE_PATTERN)
end

-- 按字节硬切，但只切在 UTF-8 字符边界上。
local function hard_split(text, max_bytes)
  local pieces = {}
  local pos = 1
  local total = #text

  while total - pos + 1 > max_bytes do
    local cut = pos + max_bytes
    local byte = text:byte(cut)
    while cut > pos and byte and byte >= 0x80 and byte < 0xC0 do
      cut = cut - 1
      byte = text:byte(cut)
    end
    if cut == pos then
      -- 单个字符就超过 max_bytes（极端配置）：至少把这个字符完整取走
      local lead = text:byte(pos) or 0
      local len = lead < 0x80 and 1 or lead < 0xE0 and 2 or lead < 0xF0 and 3 or 4
      cut = math.min(pos + len, total + 1)
    end
    pieces[#pieces + 1] = text:sub(pos, cut - 1)
    pos = cut
  end

  if pos <= total then
    pieces[#pieces + 1] = text:sub(pos)
  end
  return pieces
end

--- 把文本切成不超过 max_bytes 字节的块，保持顺序。
--- 先按句切，再按字节硬切；返回的块按顺序拼回去就是原文。
---@param text string
---@param max_bytes integer?
---@return string[]
function M.chunk(text, max_bytes)
  max_bytes = math.max(1, max_bytes or 450)
  if #text <= max_bytes then
    return { text }
  end

  local chunks = {}
  local current = {}
  local current_len = 0

  local function flush()
    if #current > 0 then
      chunks[#chunks + 1] = table.concat(current)
      current = {}
      current_len = 0
    end
  end

  for _, sentence in ipairs(split_sentences(text)) do
    if #sentence > max_bytes then
      flush()
      for _, piece in ipairs(hard_split(sentence, max_bytes)) do
        chunks[#chunks + 1] = piece
      end
    elseif current_len + #sentence > max_bytes then
      flush()
      current[1] = sentence
      current_len = #sentence
    else
      current[#current + 1] = sentence
      current_len = current_len + #sentence
    end
  end
  flush()

  if #chunks == 0 then
    chunks[1] = text
  end
  return chunks
end

return M
