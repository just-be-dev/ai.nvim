-- ai.nvim - Neovim ACP client for code agents
-- License: MIT

if vim.g.loaded_ai_nvim then
  return
end
vim.g.loaded_ai_nvim = true

vim.api.nvim_create_user_command("Ai", function(opts)
  require("ai").command(opts)
end, {
  nargs = "*",
  range = true,
  desc = "Interact with an ACP code agent",
  complete = function(arglead, cmdline, cursorpos)
    return require("ai").complete(arglead, cmdline, cursorpos)
  end,
})
