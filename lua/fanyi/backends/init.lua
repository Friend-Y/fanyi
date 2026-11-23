-- 后端注册表。新增一个翻译源 = 实现下面的 Backend 表 + 调一次 register()。
--
-- 接口约定：
--
-- ---@class fanyi.Request
-- ---@field text string   -- 待翻译文本（已 trim，可能多行）
-- ---@field target string -- "zh-CN" | "en"
-- ---@field opts table    -- 该后端的配置（config.backends[name]）
--
-- ---@class fanyi.Backend
-- ---@field name string
-- ---@field label string -- 浮窗标题显示名，如 "MyMemory"
-- ---@field translate fun(req: fanyi.Request, cb: fun(lines?: string[], err?: string))
--
-- translate 必须是异步的（不要阻塞界面），完成后调用一次回调：
-- 成功 cb({ "第一行", "第二行" })，失败 cb(nil, "中文错误")。
local M = {}

local registry = {}

--- 注册（或覆盖）一个后端。
---@param name string
---@param backend fanyi.Backend
function M.register(name, backend)
  if type(name) ~= "string" or name == "" then
    error("fanyi: 后端名字不能为空")
  end
  if type(backend) ~= "table" or type(backend.translate) ~= "function" then
    error(string.format("fanyi: 后端 %s 缺少 translate 方法", name))
  end
  backend.name = backend.name or name
  registry[name] = backend
end

--- 取已注册的后端；未注册返回 nil（调用方给出中文错误）。
---@param name string
---@return fanyi.Backend?
function M.get(name)
  return registry[name]
end

--- 已注册的后端名列表，按名字排序保证稳定。
---@return string[]
function M.names()
  local names = {}
  for name in pairs(registry) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

return M
