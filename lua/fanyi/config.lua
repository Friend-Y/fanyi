-- 配置：默认值深合并 + 当前会话的翻译源。纯内存，不读写任何状态文件。
local M = {}

M.defaults = {
  backend = "mymemory", -- 启动时用哪个（要在 available 里）
  available = { "mymemory" }, -- 白名单 + 循环顺序；setup() 以传入的 opts.available 为准
  target = { han = "en", western = "zh-CN" },
  float = { max_height = 15, min_width = 24, width_ratio = 0.8 },
  backends = {
    mymemory = { timeout = 8, max_bytes = 450 },
    -- 下面两项只是给将来的后端预留结构，当前没有注册。
    deepseek = { timeout = 20, model = "deepseek-chat", api_key = nil },
    google = { timeout = 8, proxy = nil },
  },
}

local function is_dict(value)
  return type(value) == "table" and not vim.islist(value)
end

-- 字典递归合并；列表（例如 available）整体替换，避免把新旧元素按索引混在一起。
local function deep_merge(dst, src)
  for key, value in pairs(src) do
    if is_dict(value) and is_dict(dst[key]) then
      deep_merge(dst[key], value)
    else
      dst[key] = vim.deepcopy(value)
    end
  end
  return dst
end

local config = vim.deepcopy(M.defaults)
config.current = config.backend

--- 合并配置。可重复调用：每次都会从默认值重新开始。
---@param opts table?
---@return table
function M.setup(opts)
  local merged = vim.deepcopy(M.defaults)
  if opts then
    deep_merge(merged, opts)
  end
  merged.current = merged.backend
  config = merged
  return config
end

---@return table
function M.get()
  return config
end

return M
