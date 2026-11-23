-- fanyi.nvim：翻译入口。只提供 API，不建任何全局键位。
local backends = require("fanyi.backends")
local config_module = require("fanyi.config")
local float = require("fanyi.float")
local lang = require("fanyi.lang")

local M = {}

-- 内置后端。新增后端时在这里加一行 register() 即可。
backends.register("mymemory", require("fanyi.backends.mymemory"))
backends.register("deepseek", require("fanyi.backends.deepseek"))
backends.register("google", require("fanyi.backends.google"))

local cache = {}

local SET_HINT = "（仅当前会话；默认值请改 lua/plugins/fanyi.lua 的 opts.backend）"

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO)
end

local function join_names(names)
  return table.concat(names, "、")
end

--- 合并配置、计算生效清单、设定启动默认源。可重复调用。
---@param opts table?
---@return table
function M.setup(opts)
  opts = opts or {}
  local cfg = config_module.setup(opts)
  local registered = backends.names()

  local raw = type(opts.available) == "table" and opts.available or nil
  if raw == nil or #raw == 0 then
    raw = registered
  end

  local available = {}
  local seen = {}
  local missing = {}
  for _, name in ipairs(raw) do
    if type(name) == "string" and not seen[name] then
      seen[name] = true
      if backends.get(name) then
        available[#available + 1] = name
      else
        missing[#missing + 1] = name
      end
    end
  end

  if #missing > 0 then
    notify("以下翻译源尚未实现，已忽略：" .. join_names(missing), vim.log.levels.WARN)
  end
  if #available == 0 then
    available = registered
  end
  if #available == 0 then
    error("fanyi: 没有任何可用翻译后端")
  end
  cfg.available = available

  local current = cfg.backend
  if type(current) ~= "string" or not vim.tbl_contains(available, current) then
    if type(current) == "string" then
      notify(
        string.format("翻译后端 %s 不在 available 里，已用 %s", current, available[1]),
        vim.log.levels.WARN
      )
    end
    current = available[1]
  end
  cfg.current = current
  return cfg
end

--- 翻译文本并显示浮窗。opts: { backend?, target?, origin_win? }
--- opts.backend 只覆盖本次调用，不改变当前会话的翻译源。
---@param text string
---@param opts table?
function M.translate(text, opts)
  opts = opts or {}
  text = vim.trim(text or "")
  if text == "" then
    notify("没有可翻译的内容", vim.log.levels.WARN)
    return
  end

  local cfg = config_module.get()
  local name = opts.backend or cfg.current
  local backend = backends.get(name)
  if not backend then
    notify(
      string.format("翻译后端不可用：%s（可用：%s）", tostring(name), join_names(cfg.available)),
      vim.log.levels.WARN
    )
    return
  end

  local target = opts.target or lang.target_for(text, cfg.target)
  local key = name .. "\0" .. target .. "\0" .. text
  local position = 0
  for index, candidate in ipairs(cfg.available) do
    if candidate == name then
      position = index
      break
    end
  end

  local meta = {
    backend = name,
    label = backend.label or name,
    target = target,
    position = position,
    total = #cfg.available,
    origin_win = opts.origin_win,
    text = text,
  }

  local cached = cache[key]
  if cached then
    float.show(cached, meta)
    return
  end

  meta.loading = true
  local seq = float.show({ "正在翻译…" }, meta)

  local request = { text = text, target = target, opts = cfg.backends[name] or {} }
  local finished = false

  local function on_done(lines, err)
    vim.schedule(function()
      if finished then
        return
      end
      finished = true

      if err then
        if float.close_if(seq) then
          notify("翻译失败：" .. tostring(err), vim.log.levels.WARN)
        end
        return
      end

      if type(lines) ~= "table" or #lines == 0 then
        if float.close_if(seq) then
          notify("翻译失败：翻译结果为空", vim.log.levels.WARN)
        end
        return
      end

      cache[key] = lines
      float.update(lines, meta, seq)
    end)
  end

  local ok, call_err = pcall(backend.translate, request, on_done)
  if not ok and float.close_if(seq) then
    notify("翻译失败：" .. tostring(call_err), vim.log.levels.WARN)
  end
end

local function selection_text()
  local mode = vim.fn.mode()
  local visual = mode == "v" or mode == "V" or mode == "\22"

  local ok, region = pcall(function()
    if visual then
      -- 在 visual 模式下 '< / '> 还没有更新，必须用 v 和光标位置。
      local start = vim.fn.getpos("v")
      local finish = vim.fn.getpos(".")
      if finish[2] < start[2] or (finish[2] == start[2] and finish[3] < start[3]) then
        start, finish = finish, start
      end
      return vim.fn.getregion(start, finish, { type = mode })
    end

    local start = vim.fn.getpos("'<")
    local finish = vim.fn.getpos("'>")
    if start[2] == 0 or finish[2] == 0 then
      return nil
    end
    return vim.fn.getregion(start, finish, { type = vim.fn.visualmode() })
  end)

  if not ok or type(region) ~= "table" then
    return nil
  end
  return table.concat(region, "\n")
end

--- 翻译当前 visual 选区（normal 模式下用最近一次选区）。
function M.translate_selection()
  local text = selection_text()
  if not text or vim.trim(text) == "" then
    notify("没有选中内容", vim.log.levels.WARN)
    return
  end
  M.translate(text)
end

--- 会话内切换到 available 里的某个源。不落盘。
---@param name string
---@return boolean
function M.set_backend(name)
  local cfg = config_module.get()
  if type(name) ~= "string" or not vim.tbl_contains(cfg.available, name) then
    notify(
      string.format("翻译源 %s 不可用（可用：%s）", tostring(name), join_names(cfg.available)),
      vim.log.levels.WARN
    )
    return false
  end

  cfg.current = name
  notify(string.format("翻译源已切换：%s%s", name, SET_HINT))
  return true
end

--- 在 available 清单里循环切换，step 默认 +1。不落盘。
---@param step integer?
---@return string?
function M.cycle_backend(step)
  local cfg = config_module.get()
  local count = #cfg.available
  if count == 0 then
    return nil
  end

  step = tonumber(step) or 1
  local index = 1
  for i, name in ipairs(cfg.available) do
    if name == cfg.current then
      index = i
      break
    end
  end

  local next_index = ((index - 1 + step) % count + count) % count + 1
  local name = cfg.available[next_index]
  M.set_backend(name)
  return name
end

--- 当前生效的后端名。
---@return string?
function M.get_backend()
  return config_module.get().current
end

--- 生效清单（有序副本）。
---@return string[]
function M.backends()
  return vim.deepcopy(config_module.get().available)
end

return M
