# ai.nvim

A small Neovim ACP client for code agents. It defaults to [Oh My Pi](https://omp.sh/) via `omp acp`, but the protocol seam is ACP, so any local agent that speaks the Agent Client Protocol over stdio can be wired in.

## Features

- **ACP-first**: Talks JSON-RPC ACP over stdio instead of a tool-specific private UI stream.
- **Single command namespace**: Use `:Ai ...`; no `:Pi...` or convenience command aliases.
- **Statusline-friendly**: Agent progress is exposed through `require("ai").statusline()` for your footer/statusline.
- **On-demand transcript**: Open a bottom/right split only when you want to watch the agent work.
- **Editor-aware files**: ACP filesystem reads see unsaved Neovim buffers; ACP writes update loaded buffers.
- **Client-side terminal bridge**: ACP terminal requests run through Neovim and can be rendered in the transcript.
- **Selection and diagnostics context**: Prompts can include the current buffer, visual selection, nearby lines, and optional diagnostics.

## Requirements

- Neovim 0.10+
- An ACP agent. Default: `omp` with ACP support:

```sh
omp acp
```

## Installation

Use your plugin manager of choice and point it at this repository.

### lazy.nvim

```lua
{
  "your-name/ai.nvim",
  config = function()
    require("ai").setup()
  end,
}
```

## Configuration

All config is optional:

```lua
require("ai").setup()
```

Default configuration:

```lua
require("ai").setup({
  transport = "acp",
  agent = {
    name = "omp",
    command = { "omp", "acp" },
    cwd = nil, -- defaults to vim.fn.getcwd()
    env = nil,
  },
  context = {
    max_bytes = 24000,
    ask = {
      surrounding_lines = 80,
    },
    selection = {
      surrounding_lines = 40,
    },
    diagnostics = {
      enabled = false,
    },
  },
  ui = {
    window = {
      position = "bottom", -- "bottom" or "right"
      height = 15,
      auto_open = false,
    },
    notify = {
      errors = true,
      progress = false,
    },
  },
  permissions = {
    auto_approve = false,
  },
  terminal = {
    output_byte_limit = 1024 * 1024,
  },
})
```

### Using another ACP agent

```lua
require("ai").setup({
  agent = {
    name = "my-agent",
    command = { "my-agent", "acp" },
  },
})
```

## Commands

`ai.nvim` registers exactly one user command: `:Ai`.

| Command | Description |
|---|---|
| `:Ai ask` | Prompt using the current file-backed buffer as context. |
| `:Ai selection` | Prompt using the current visual selection and nearby context. |
| `:Ai cancel` | Cancel the active ACP prompt. |
| `:Ai status` | Echo current agent status. |
| `:Ai open` | Open the agent transcript split. |
| `:Ai close` | Close the transcript split without cancelling the agent. |
| `:Ai toggle` | Toggle the transcript split. |

Neovim user commands must start with an uppercase letter, so `:ai` cannot be implemented as a normal command. Use `:Ai`.

## Keymaps

No keymaps are created by default.

```lua
vim.keymap.set("n", "<leader>ai", "<cmd>Ai ask<CR>", { desc = "Ask AI" })
vim.keymap.set("v", "<leader>ai", "<cmd>Ai selection<CR>", { desc = "Ask AI about selection" })
```

## Statusline/footer

`ai.nvim` does not mutate your statusline. Add the exported component where you want it.

Plain statusline example:

```lua
vim.o.statusline = vim.o.statusline .. "%{%v:lua.require'ai'.statusline()%}"
```

lualine example:

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      require("ai").statusline,
    },
  },
})
```

## Behavior

- `:Ai ask` and `:Ai selection` prompt with `vim.ui.input`.
- The default agent process is `omp acp`.
- ACP initialization advertises filesystem and terminal client capabilities.
- `fs/read_text_file` reads loaded Neovim buffers before disk, so unsaved edits are visible to the agent.
- `fs/write_text_file` writes to disk and updates matching loaded buffers.
- `terminal/create` starts commands with `vim.system`; output is retained for `terminal/output` and the transcript view.
- Permission requests use `vim.ui.select` unless `permissions.auto_approve = true`.
- Progress is passive by default: statusline state changes, no modal/floating progress window opens.

## Public API

```lua
require("ai").setup(opts)
require("ai").run({ message = "..." })
require("ai").cancel()
require("ai").statusline()
require("ai").open()
require("ai").close()
require("ai").toggle()
require("ai").get_cmd()
```

## Testing

```sh
mise run test
```

## License

MIT
