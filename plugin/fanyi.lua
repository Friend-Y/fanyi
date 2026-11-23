-- 只定义命令，不建任何键位。键位请写在你自己的配置里。
if vim.g.loaded_fanyi then
  return
end
vim.g.loaded_fanyi = 1

local function in_visual()
  local mode = vim.fn.mode()
  return mode == "v" or mode == "V" or mode == "\22"
end

local function current_line()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return table.concat(vim.api.nvim_buf_get_lines(0, line - 1, line, false), "\n")
end

vim.api.nvim_create_user_command("Translate", function(args)
  local fanyi = require("fanyi")
  if args.range > 0 then
    local lines = vim.api.nvim_buf_get_lines(0, args.line1 - 1, args.line2, false)
    fanyi.translate(table.concat(lines, "\n"))
  elseif in_visual() then
    fanyi.translate_selection()
  else
    fanyi.translate(current_line())
  end
end, { range = true, desc = "翻译选区或当前行" })

vim.api.nvim_create_user_command("TranslateBackend", function(args)
  local fanyi = require("fanyi")
  local arg = vim.trim(args.args or "")

  if arg == "" then
    local available = fanyi.backends()
    local current = fanyi.get_backend()
    local choices = {}
    local labels = {}
    for _, name in ipairs(available) do
      local label = name .. (name == current and "（当前）" or "")
      choices[#choices + 1] = { name = name, label = label }
      labels[#labels + 1] = label
    end

    vim.ui.select(labels, { prompt = "选择翻译源" }, function(choice)
      if not choice then
        return
      end
      for _, item in ipairs(choices) do
        if item.label == choice then
          fanyi.set_backend(item.name)
          return
        end
      end
    end)
  elseif arg == "next" then
    fanyi.cycle_backend(1)
  elseif arg == "prev" then
    fanyi.cycle_backend(-1)
  else
    fanyi.set_backend(arg)
  end
end, {
  nargs = "?",
  desc = "选择/切换翻译源（仅当前会话）",
  complete = function()
    return require("fanyi").backends()
  end,
})
