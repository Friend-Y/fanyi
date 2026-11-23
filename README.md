# fanyi.nvim

Neovim 翻译插件：选中文本 → 悬浮窗看译文。

- 已实现三个翻译源：**MyMemory**（免费）、**DeepSeek**（API key）、**Google**（官方 Cloud v2 或 gtx 免费接口）
- 翻译源在配置里声明清单，运行时可在清单内切换（**只影响当前会话**，不写状态文件）
- 插件不建任何全局键位；命令和 Lua API 由你的配置自行接入

## 要求

- Neovim 0.12+
- `curl` 在 `PATH` 中
- 至少一个翻译源可用：
  - MyMemory：能访问 `api.mymemory.translated.net`
  - DeepSeek：`opts.backends.deepseek.api_key`
  - Google：`opts.backends.google.api_key`（Cloud v2），或 `proxy`（gtx 免费接口）

## 安装（lazy.nvim）

本地开发用显式 `dir`（不会 fetch，也不写 `lazy-lock.json`）：

```lua
return {
  dir = vim.fn.expand("~/Projects/fanyi"),
  name = "fanyi.nvim",
  cmd = { "Translate", "TranslateBackend" },
  keys = {
    { "<leader>tl", mode = { "n", "v" }, "<Cmd>Translate<CR>", desc = "翻译选中文本/当前行" },
    { "<leader>tc", mode = { "n", "v" }, "<Cmd>TranslateBackend<CR>", desc = "选择翻译源" },
    { "<leader>tn", mode = { "n", "v" }, "<Cmd>TranslateBackend next<CR>", desc = "切换下一个翻译源" },
  },
  opts = {
    available = { "mymemory", "deepseek", "google" },
    backend = "mymemory",
    backends = {
      deepseek = {
        -- 推荐读环境变量；也可以直接写 "sk-..."。本文件受 git 跟踪，注意别提交密钥。
        api_key = vim.env.PI_DEEPSEEK_API_KEY or "",
        model = "deepseek-chat",
        base_url = "https://api.deepseek.com",
        timeout = 30,
        max_bytes = 4000,
      },
      google = {
        -- auto: 有 api_key 走 Cloud v2，否则用 proxy 走 gtx 免费接口
        mode = "auto",
        api_key = vim.env.GOOGLE_API_KEY or "",
        proxy = "http://127.0.0.1:7897", -- 改成你的代理；没有代理且没有 key 时 Google 不可用
        timeout = 15,
        max_bytes = 4500,
      },
    },
  },
  config = function(_, opts)
    require("fanyi").setup(opts)
  end,
}
```

远端可用后把 `dir` 换成 `"Friend-Y/fanyi"`（或加 `dev = true`）。

## 配置字段

```lua
require("fanyi").setup({
  backend = "mymemory", -- 启动默认源，必须在 available 里
  available = { "mymemory", "deepseek", "google" }, -- 白名单 + 循环顺序；nil/空表 = 全部已注册后端
  target = { han = "en", western = "zh-CN" }, -- 含汉字 → 英文，否则 → 中文
  float = { max_height = 15, min_width = 24, width_ratio = 0.8 },
  backends = {
    mymemory = { timeout = 8, max_bytes = 450 },
    deepseek = {
      api_key = nil,
      base_url = "https://api.deepseek.com",
      model = "deepseek-chat",
      timeout = 30,
      max_bytes = 4000,
      -- temperature = 1.0,          -- 可选，不填用 API 默认
      -- system_prompt = "...",      -- 可选，自定义翻译提示词
      -- proxy = "http://127.0.0.1:7897", -- 可选，DeepSeek 需要代理时填
    },
    google = {
      mode = "auto", -- auto | cloud | gtx
      api_key = nil, -- Cloud Translation v2 的 API key
      proxy = nil, -- gtx（或 Cloud）需要代理时填
      timeout = 15,
      max_bytes = 4500,
    },
  },
})
```

- `available` 是**唯一白名单和循环顺序**；名字未注册会被过滤掉并一次性 WARN“尚未实现，已忽略”。
- `backend` 是启动默认；不在清单里时回退到清单第一个并 WARN。
- `setup()` 可重复调用：会重算清单，并把当前源重置为 `backend`。注意：`:Lazy reload fanyi.nvim` 只重载插件代码，**不会重新读取** `lua/plugins/fanyi.lua` 里的 opts；改配置后请重启 Neovim。
- **API key / model / 代理都写在配置 lua 里**（例如 `lua/plugins/fanyi.lua` 的 `opts.backends`）。如果该文件受 git 跟踪，优先用 `vim.env.*` 读取环境变量；直接写死 key 会进入 git 历史。

### DeepSeek

- 调 OpenAI 兼容的 `POST {base_url}/chat/completions`，默认 `base_url = "https://api.deepseek.com"`、`model = "deepseek-chat"`。
- `api_key` 必填；支持 `proxy`、`temperature`、`system_prompt`。
- 文本按句/UTF-8 安全分块（默认 `max_bytes = 4000`），顺序请求后拼接；请求异步，不阻塞界面。
- 默认提示词要求只输出译文、保留换行和格式。

### Google

- `mode = "auto"`（默认）：有 `api_key` 走 **Cloud Translation v2**；否则有 `proxy` 走 **gtx 免费接口**；两者都没有则报中文错误。
- `mode = "cloud"`：官方 API，需要 `api_key`；代理可选（本机直连超时，需代理）。
- `mode = "gtx"`：免费网页接口，不需要 key；直连通常超时，需要 `proxy`。
- 源语言由 Google 自动检测（gtx 用 `sl=auto`），目标语言仍由插件按“含汉字 → 英文，否则 → 中文”决定。
- Cloud v2 返回的 HTML 实体（`&#39;`、`&quot;` 等）会解码；长文本按 `max_bytes`（默认 4500）分块。
- Cloud v2 还需要在 Google Cloud 控制台启用 Translation API 并确认配额/账单。

## 命令

| 命令 | 说明 |
| --- | --- |
| `:Translate` | 翻译 visual 选区 / 当前行；带 range 时翻译 range（`:'<,'>Translate`） |
| `:TranslateBackend` | `vim.ui.select` 选择翻译源 |
| `:TranslateBackend next` / `prev` | 在清单里循环切换 |
| `:TranslateBackend <name>` | 切到指定源（不在清单则 WARN 并列出可用项） |

`:Translate` / `:TranslateBackend` 在启动时就可用（配置里用 lazy 的 `cmd` 占位，首次调用或按 `<leader>tl` 时才真正加载插件）。补全候选 = 当前生效清单。所有切换**只改内存**，提示会带“仅当前会话”。

## 建议键位（写在配置侧）

```lua
keys = {
  { "<leader>tl", mode = { "n", "v" }, "<Cmd>Translate<CR>", desc = "翻译选中文本/当前行" },
  { "<leader>tc", mode = { "n", "v" }, "<Cmd>TranslateBackend<CR>", desc = "选择翻译源" },
  { "<leader>tn", mode = { "n", "v" }, "<Cmd>TranslateBackend next<CR>", desc = "切换下一个翻译源" },
}
```

插件本身不建任何键位，方便和其他配置解耦。

## API

```lua
local fanyi = require("fanyi")

fanyi.setup(opts)            -- 合并配置、计算生效清单、设定启动默认源
fanyi.translate(text, opts?) -- 翻译并显示；opts.backend 只覆盖本次调用
fanyi.translate_selection()  -- 翻译当前 visual 选区（或最近一次选区）
fanyi.set_backend(name)      -- 会话内切换（不落盘）
fanyi.cycle_backend(step?)   -- 会话内轮换，step 默认 +1
fanyi.get_backend()          -- 当前生效源名
fanyi.backends()             -- 生效清单（有序副本）
```

`translate` 的 `opts` 支持 `backend`、`target`、`origin_win`（内部/高级用法）。请求异步执行，不阻塞界面。

## 浮窗

- 圆角边框、贴近光标、限制在发起窗口内（不会盖住右侧 sidekick 等分屏）
- `q` / `<Esc>` 关闭
- `y` 把译文复制到 `+`，提示“已复制译文”
- `b` / `B` 原地切到下一个/上一个翻译源并重译（标题里的 `1/3` 会变）
- `j` / `k` / `<C-d>` / `<C-u>` / `gg` / `G` 浏览长译文（`j`/`k` 走显示行，长段落会软换行）
- `filetype=markdown`，render-markdown / MarkView 等可以正常渲染译文

请求期间浮窗先显示“正在翻译…”，结果回来再填；失败会关窗并给出中文提示。

## 翻译源清单与切换（无状态文件）

`opts.available` 写在你的配置 lua 里，跟配置仓库一起进 git：

- 换清单（加/删/调顺序）：编辑配置里的 `opts.available` → **重启 Neovim**（`:Lazy reload fanyi.nvim` 不会重新读取 spec 文件里的 opts）
- 日常换源：`:TranslateBackend` / 浮窗 `b`、`B`（配置侧还可以绑 `<leader>tn`）
- 重启 nvim 会回到 `opts.backend`

插件不写任何状态文件，所以没有“上次切到哪儿了”的隐式状态，也不需要清缓存/清目录。

## 后端探测结论（2026-11-23 实测）

| 端点 | 结果 |
| --- | --- |
| `api.mymemory.translated.net/get` | ✅ 可用（必须 `-L`） |
| `api.deepseek.com/chat/completions` | ✅ 可用（本机 `PI_DEEPSEEK_API_KEY`，返回 `deepseek-chat` 译文） |
| `translate.googleapis.com/translate_a/single`（gtx） | ✅ 走本机代理 `127.0.0.1:7897` 可用；❌ 直连超时 |
| `translation.googleapis.com/language/translate/v2`（Cloud） | ✅ 经代理可达（无 key 时 403，需要 API key + 启用 API） |
| `fanyi.youdao.com/translate` 老免费接口 | ❌ 返回 HTML，已失效 |

### MyMemory 的坑

- **不支持 `auto` 源语言**：`langpair=auto|zh-CN` 会返回 HTTP 200，但正文是 `'AUTO' IS AN INVALID SOURCE LANGUAGE`。所以 MyMemory 的语言检测在本地做。
- 源语言写 **`zh`**，不要写 `zh-CN`（`zh-CN|en` 返回空，`zh|en` 正常）。
- 单次查询长度有限（匿名约 500 字节），超长会挂住/空返回；插件按句切分，每块默认不超过 `max_bytes = 450` 字节，顺序请求后拼接。
- 偶发限速/超时：请求带 `curl -m <timeout>`，失败给出中文提示，不静默。
- 中文译英时响应可能带 `<g id="...">...</g>` 对齐标记，插件会剥掉；HTML 实体（`&quot;`、`&#39;` 等）也会解码。

## 新增后端

1. 写 `lua/fanyi/backends/<name>.lua`：

```lua
---@class fanyi.Request
---@field text string   -- 已 trim 的待翻译文本
---@field target string -- "zh-CN" | "en"
---@field opts table    -- config.backends[name]

---@class fanyi.Backend
---@field name string
---@field label string -- 浮窗标题里的显示名
---@field translate fun(req: fanyi.Request, cb: fun(lines?: string[], err?: string))

return {
  name = "foo",
  label = "Foo",
  translate = function(req, cb)
    -- 异步完成后调用 cb({ "第一行", "第二行" }) 或 cb(nil, "中文错误")
  end,
}
```

2. 在 `lua/fanyi/init.lua` 的后端注册处加一行
   `backends.register("foo", require("fanyi.backends.foo"))`。
3. 把 `foo` 写进配置的 `opts.available`，并在 `opts.backends.foo` 里放它需要的配置。

## 文件结构

```
lua/fanyi/init.lua           -- setup / 公共 API
lua/fanyi/config.lua         -- 默认配置合并（纯内存）
lua/fanyi/lang.lua           -- 语言检测 + 按句/字节分块
lua/fanyi/float.lua          -- 浮窗与键位
lua/fanyi/backends/init.lua  -- 后端注册表
lua/fanyi/backends/mymemory.lua
lua/fanyi/backends/deepseek.lua
lua/fanyi/backends/google.lua
plugin/fanyi.lua             -- :Translate / :TranslateBackend
```

本仓库是最小版：没有 `doc/`、`:checkhealth` 和自动化测试；验证方式是 headless 命令和真机手工验收。
