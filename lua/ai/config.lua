--- Configuration helpers for ai.nvim.
local M = {}

local VALID_TRANSPORTS = {
  acp = true,
}

M.defaults = {
  transport = "acp",
  agent = {
    name = "omp",
    command = { "omp", "acp" },
    cwd = nil,
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
      position = "bottom",
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
}

local values = vim.deepcopy(M.defaults)

local function validate_number(name, value)
  if type(value) ~= "number" or value < 1 then
    error(string.format("ai.nvim: %s must be a positive number", name))
  end
end

local function validate_string_list(name, value)
  if type(value) ~= "table" then
    error(string.format("ai.nvim: %s must be a list of strings", name))
  end
  for i, part in ipairs(value) do
    if type(part) ~= "string" then
      error(string.format("ai.nvim: %s[%d] must be a string", name, i))
    end
  end
end

function M.validate(opts)
  opts = opts or {}

  if opts.transport ~= nil then
    if type(opts.transport) ~= "string" or not VALID_TRANSPORTS[opts.transport] then
      error("ai.nvim: transport must be one of: acp")
    end
  end

  if opts.agent ~= nil then
    if type(opts.agent) ~= "table" then
      error("ai.nvim: agent must be a table")
    end
    if opts.agent.name ~= nil and type(opts.agent.name) ~= "string" then
      error("ai.nvim: agent.name must be a string")
    end
    if opts.agent.command ~= nil then
      validate_string_list("agent.command", opts.agent.command)
      if #opts.agent.command == 0 then
        error("ai.nvim: agent.command must not be empty")
      end
    end
    if opts.agent.cwd ~= nil and type(opts.agent.cwd) ~= "string" then
      error("ai.nvim: agent.cwd must be a string")
    end
    if opts.agent.env ~= nil and type(opts.agent.env) ~= "table" then
      error("ai.nvim: agent.env must be a table")
    end
  end

  local context = opts.context
  if context ~= nil then
    if type(context) ~= "table" then
      error("ai.nvim: context must be a table")
    end
    if context.max_bytes ~= nil then
      validate_number("context.max_bytes", context.max_bytes)
    end
    if context.ask ~= nil then
      if type(context.ask) ~= "table" then
        error("ai.nvim: context.ask must be a table")
      end
      if context.ask.surrounding_lines ~= nil then
        validate_number("context.ask.surrounding_lines", context.ask.surrounding_lines)
      end
    end
    if context.selection ~= nil then
      if type(context.selection) ~= "table" then
        error("ai.nvim: context.selection must be a table")
      end
      if context.selection.surrounding_lines ~= nil then
        validate_number("context.selection.surrounding_lines", context.selection.surrounding_lines)
      end
    end
    if context.diagnostics ~= nil then
      if type(context.diagnostics) ~= "table" then
        error("ai.nvim: context.diagnostics must be a table")
      end
      if context.diagnostics.enabled ~= nil and type(context.diagnostics.enabled) ~= "boolean" then
        error("ai.nvim: context.diagnostics.enabled must be a boolean")
      end
    end
  end

  if opts.ui ~= nil then
    if type(opts.ui) ~= "table" then
      error("ai.nvim: ui must be a table")
    end
    if opts.ui.window ~= nil then
      if type(opts.ui.window) ~= "table" then
        error("ai.nvim: ui.window must be a table")
      end
      if opts.ui.window.height ~= nil then
        validate_number("ui.window.height", opts.ui.window.height)
      end
      if opts.ui.window.position ~= nil then
        local pos = opts.ui.window.position
        if pos ~= "bottom" and pos ~= "right" then
          error("ai.nvim: ui.window.position must be 'bottom' or 'right'")
        end
      end
      if opts.ui.window.auto_open ~= nil and type(opts.ui.window.auto_open) ~= "boolean" then
        error("ai.nvim: ui.window.auto_open must be a boolean")
      end
    end
    if opts.ui.notify ~= nil then
      if type(opts.ui.notify) ~= "table" then
        error("ai.nvim: ui.notify must be a table")
      end
      if opts.ui.notify.errors ~= nil and type(opts.ui.notify.errors) ~= "boolean" then
        error("ai.nvim: ui.notify.errors must be a boolean")
      end
      if opts.ui.notify.progress ~= nil and type(opts.ui.notify.progress) ~= "boolean" then
        error("ai.nvim: ui.notify.progress must be a boolean")
      end
    end
  end

  if opts.permissions ~= nil then
    if type(opts.permissions) ~= "table" then
      error("ai.nvim: permissions must be a table")
    end
    if opts.permissions.auto_approve ~= nil and type(opts.permissions.auto_approve) ~= "boolean" then
      error("ai.nvim: permissions.auto_approve must be a boolean")
    end
  end

  if opts.terminal ~= nil then
    if type(opts.terminal) ~= "table" then
      error("ai.nvim: terminal must be a table")
    end
    if opts.terminal.output_byte_limit ~= nil then
      validate_number("terminal.output_byte_limit", opts.terminal.output_byte_limit)
    end
  end
end

function M.setup(opts)
  opts = opts or {}
  M.validate(opts)
  values = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  return values
end

function M.get()
  return values
end

return M
