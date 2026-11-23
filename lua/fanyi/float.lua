-- 翻译浮窗：圆角边框、贴近光标、限制在发起窗口内（参考 core/lspsaga_peek.lua 的夹取思路）。
local api = vim.api

local M = {}

local state = {
  win = nil,
  buf = nil,
  origin = nil,
  seq = 0,
  lines = nil,
  loading = false,
  last_request = nil, -- { text, target }
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO)
end

local function valid_win(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf ~= nil and api.nvim_buf_is_valid(buf)
end

local function target_label(target)
  if target == "en" then
    return "英文"
  end
  if target == "zh-CN" or target == "zh" then
    return "中文"
  end
  return target or "?"
end

local function make_title(meta)
  local label = meta.label or meta.backend or "翻译"
  local place = ""
  if meta.position and meta.total and meta.total > 0 then
    place = string.format(" %d/%d", meta.position, meta.total)
  end
  return string.format(" 翻译 · %s%s → %s ", label, place, target_label(meta.target))
end

-- 宽度按内容与窗口比例取；高度按软换行后的显示行数估算，保证长文本能滚动。
local function measure(lines, meta)
  local cfg = require("fanyi.config").get()
  local fcfg = cfg.float or {}
  local origin = meta.origin_win
  local info = valid_win(origin) and vim.fn.getwininfo(origin)[1] or nil
  local win_width = info and info.width or math.max(1, vim.o.columns)
  local win_height = info and info.height or math.max(1, vim.o.lines - 2)
  local winbar = info and (info.winbar or 0) or 0

  local max_line = 1
  for _, line in ipairs(lines) do
    max_line = math.max(max_line, vim.fn.strdisplaywidth(line))
  end
  -- 标题不能比内容还宽，否则会被截断
  max_line = math.max(max_line, vim.fn.strdisplaywidth(make_title(meta)) - 2)

  local min_width = math.max(1, fcfg.min_width or 24)
  local ratio = fcfg.width_ratio or 0.8
  local width = math.max(min_width, math.min(max_line, math.floor(win_width * ratio)))
  width = math.max(1, math.min(width, win_width - 2))

  local total_rows = 0
  for _, line in ipairs(lines) do
    local display = vim.fn.strdisplaywidth(line)
    total_rows = total_rows + math.max(1, math.ceil(display / width))
  end
  local max_height = math.max(1, fcfg.max_height or 15)
  local available = math.max(1, win_height - winbar - 2)
  local height = math.max(1, math.min(total_rows, max_height, available))
  return width, height
end

-- 屏幕坐标 → 相对发起窗口的坐标，并夹在窗口文本区内（边框留 2 列）。
local function place(origin, width, height)
  local info = vim.fn.getwininfo(origin)[1]
  local tpos = vim.fn.win_screenpos(origin)
  if not info or not tpos or tpos[1] <= 0 then
    return 1, 0
  end

  local cursor = api.nvim_win_get_cursor(origin)
  local cpos = vim.fn.screenpos(origin, cursor[1], cursor[2] + 1)
  local row, col = 1, 0
  if type(cpos) == "table" and cpos.row and cpos.row > 0 then
    row = cpos.row - tpos[1] + 1 -- 光标下一行
    col = cpos.col - tpos[2]
  end

  local winbar = info.winbar or 0
  local pad = 2
  local row_min = winbar
  local row_max = math.max(row_min, winbar + info.height - height - pad)
  local col_max = math.max(0, info.width - width - pad)
  row = math.min(math.max(row, row_min), row_max)
  col = math.min(math.max(col, 0), col_max)
  return row, col
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function close()
  local win = state.win
  state.win = nil
  state.buf = nil
  state.lines = nil
  state.loading = false
  state.last_request = nil
  if valid_win(win) then
    pcall(api.nvim_win_close, win, true)
  end
end

M.close = close

local function copy()
  if state.loading or not state.lines then
    notify("翻译尚未完成", vim.log.levels.WARN)
    return
  end
  vim.fn.setreg("+", table.concat(state.lines, "\n"))
  notify("已复制译文")
end

local function retranslate(step)
  local request = state.last_request
  if not request or not request.text then
    return
  end
  local origin = state.origin
  require("fanyi").cycle_backend(step)
  require("fanyi").translate(request.text, { target = request.target, origin_win = origin })
end

local function setup_maps(buf)
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map("q", close, "关闭翻译")
  map("<Esc>", close, "关闭翻译")
  map("y", copy, "复制译文")
  map("b", function()
    retranslate(1)
  end, "切换到下一个翻译源")
  map("B", function()
    retranslate(-1)
  end, "切换到上一个翻译源")
  map("j", "gj", "下一显示行")
  map("k", "gk", "上一显示行")
end

local function ensure_buf()
  if valid_buf(state.buf) then
    return state.buf
  end

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = false
  set_lines(buf, { "" })
  vim.bo[buf].filetype = "markdown"
  setup_maps(buf)
  state.buf = buf
  return buf
end

local function resolve_origin(meta)
  if valid_win(meta.origin_win) then
    return meta.origin_win
  end
  local current = api.nvim_get_current_win()
  if state.win == current and valid_win(state.origin) then
    return state.origin
  end
  return current
end

local function win_config(origin, row, col, width, height, title)
  return {
    relative = "win",
    win = origin,
    row = row,
    col = col,
    width = width,
    height = height,
    border = "rounded",
    style = "minimal",
    title = title,
    title_pos = "center",
    zindex = 60,
  }
end

local function update_win(win, origin, row, col, width, height, title)
  api.nvim_win_set_config(win, {
    relative = "win",
    win = origin,
    row = row,
    col = col,
    width = width,
    height = height,
    title = title,
    title_pos = "center",
  })
end

local function watch_close(win)
  api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if state.win == win then
        state.win = nil
        state.buf = nil
        state.lines = nil
        state.loading = false
        state.last_request = nil
      end
    end,
  })
end

--- 打开或原地更新浮窗。返回本次请求的序号，用于丢弃过期回调。
---@param lines string[]
---@param meta table
---@return integer
function M.show(lines, meta)
  meta = meta or {}
  lines = lines or { "" }
  if #lines == 0 then
    lines = { "" }
  end

  state.seq = state.seq + 1
  local seq = state.seq
  state.loading = meta.loading == true
  state.lines = lines
  if meta.text then
    state.last_request = { text = meta.text, target = meta.target }
  end

  local origin = resolve_origin(meta)
  if not valid_win(origin) then
    notify("找不到发起翻译的窗口", vim.log.levels.WARN)
    return seq
  end
  state.origin = origin
  meta.origin_win = origin

  local width, height = measure(lines, meta)
  local title = make_title(meta)
  local row, col = place(origin, width, height)

  if valid_win(state.win) then
    local buf = valid_buf(state.buf) and state.buf or ensure_buf()
    set_lines(buf, lines)
    update_win(state.win, origin, row, col, width, height, title)
    return seq
  end

  local buf = ensure_buf()
  set_lines(buf, lines)
  local win = api.nvim_open_win(buf, true, win_config(origin, row, col, width, height, title))
  state.win = win
  state.buf = buf
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  watch_close(win)
  return seq
end

--- 用结果替换浮窗内容；seq 不匹配（过期请求）或浮窗已关闭时忽略。
---@param lines string[]
---@param meta table
---@param seq integer?
---@return boolean
function M.update(lines, meta, seq)
  if seq and seq ~= state.seq then
    return false
  end
  if not valid_win(state.win) then
    return false
  end

  meta = meta or {}
  lines = lines or { "" }
  if #lines == 0 then
    lines = { "" }
  end

  local origin = state.origin
  if not valid_win(origin) then
    close()
    return false
  end

  state.loading = false
  state.lines = lines
  meta.origin_win = origin
  local width, height = measure(lines, meta)
  local title = make_title(meta)
  local row, col = place(origin, width, height)
  local buf = valid_buf(state.buf) and state.buf or ensure_buf()
  set_lines(buf, lines)
  update_win(state.win, origin, row, col, width, height, title)
  return true
end

--- 只在 seq 仍是当前请求且浮窗还开着时关闭。
---@param seq integer
---@return boolean
function M.close_if(seq)
  if seq ~= state.seq or not valid_win(state.win) then
    return false
  end
  close()
  return true
end

--- 内部状态（测试/调试用）。
---@return table
function M._state()
  return state
end

return M
