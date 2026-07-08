local acp = require("ai.protocol.acp")
local config = require("ai.config")
local context = require("ai.context")
local session_mod = require("ai.session")
local status = require("ai.status")
local view = require("ai.view")

local M = {}

local active_session = nil
local active_connection = nil
local last_session = nil

local function assert_supported_version()
  if vim.fn.has("nvim-0.10") == 0 then
    error("ai.nvim requires Neovim 0.10+")
  end
end

local function ensure_file_backed_buffer(command_name)
  local bufnr = vim.api.nvim_get_current_buf()
  if not context.buffer_is_file_backed(bufnr) then
    vim.notify(string.format("%s requires a file", command_name), vim.log.levels.ERROR)
    return nil
  end
  return bufnr
end

local function normalize_path(path)
  return vim.fn.fnamemodify(path, ":p")
end

local function file_signature(path)
  local stat = vim.loop.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end
  return {
    size = stat.size,
    mtime_sec = stat.mtime and stat.mtime.sec or 0,
    mtime_nsec = stat.mtime and stat.mtime.nsec or 0,
  }
end

local function signatures_equal(a, b)
  if not a or not b then
    return a == b
  end
  return a.size == b.size and a.mtime_sec == b.mtime_sec and a.mtime_nsec == b.mtime_nsec
end

local function snapshot_loaded_file_buffers()
  local snapshots = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and context.buffer_is_file_backed(bufnr) then
      local path = normalize_path(vim.api.nvim_buf_get_name(bufnr))
      snapshots[path] = file_signature(path)
    end
  end
  return snapshots
end

local function reload_buffer_from_disk(bufnr, path)
  if vim.fn.filereadable(path) ~= 1 then
    return false
  end
  local ok = pcall(function()
    vim.api.nvim_buf_call(bufnr, function()
      local view_state = vim.api.nvim_get_current_buf() == bufnr and vim.fn.winsaveview() or nil
      vim.cmd("silent edit!")
      if view_state then
        vim.fn.winrestview(view_state)
      end
    end)
  end)
  return ok
end

local function reload_changed_file_buffers(session)
  local before_snapshots = session.file_snapshots or {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and context.buffer_is_file_backed(bufnr) then
      local path = normalize_path(vim.api.nvim_buf_get_name(bufnr))
      local before = before_snapshots[path]
      local after = file_signature(path)
      if not signatures_equal(before, after) and not vim.bo[bufnr].modified then
        reload_buffer_from_disk(bufnr, path)
      end
    end
  end
end

local function finish_if_done(session)
  if not session then
    return
  end
  if session.status == "done" and not session.skip_reload then
    reload_changed_file_buffers(session)
  end
  if active_session == session and (session.status == "done" or session.status == "error" or session.status == "cancelled") then
    active_session = nil
    active_connection = nil
  end
  last_session = session
end

local function prompt_blocks(message, built_context)
  return {
    { type = "text", text = message },
    { type = "text", text = "Context:\n" .. built_context },
  }
end

function M.get_cmd()
  return vim.deepcopy(config.get().agent.command)
end

function M.run(opts)
  opts = vim.deepcopy(opts or {})
  local cfg = config.get()
  local message = opts.message
  local build_context_fn = opts.build_context
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()

  if active_session then
    vim.notify("AI agent is already running, please wait", vim.log.levels.WARN)
    return
  end
  if not message or message == "" then
    vim.notify("No message provided", vim.log.levels.ERROR)
    return
  end
  if not build_context_fn then
    build_context_fn = function()
      return context.get_buffer_context(bufnr, cfg)
    end
  end

  local session = session_mod.new(bufnr, { agent = cfg.agent.name })
  session.file_snapshots = snapshot_loaded_file_buffers()
  session.skip_reload = opts.skip_reload == true
  session.on_done = opts.on_done
  active_session = session
  last_session = session

  session_mod.add_text(session, "user", message)
  if cfg.ui.window.auto_open then
    view.open(session)
  else
    view.update(session)
  end

  local ok, built_context = pcall(build_context_fn)
  if not ok then
    session.status = "error"
    session.last_error = tostring(built_context)
    status.set({ status = "error", last_error = session.last_error })
    view.update(session)
    active_session = nil
    return
  end

  local connection = acp.new(session, cfg, {
    on_done = function(done_session)
      if opts.on_done then
        pcall(opts.on_done, done_session)
      end
    end,
    on_finish = finish_if_done,
  })
  active_connection = connection
  connection:connect_then_prompt(prompt_blocks(message, built_context))
end

function M.setup(opts)
  assert_supported_version()
  config.setup(opts)
  status.reset()
end

function M.prompt_with_buffer()
  assert_supported_version()
  local bufnr = ensure_file_backed_buffer("Ai ask")
  if not bufnr then
    return
  end
  vim.ui.input({ prompt = context.format_prompt_label(bufnr, nil) }, function(input)
    if input then
      M.run({
        message = input,
        bufnr = bufnr,
        build_context = function()
          return context.get_buffer_context(bufnr, config.get())
        end,
      })
    end
  end)
end

function M.prompt_with_selection()
  assert_supported_version()
  local bufnr = ensure_file_backed_buffer("Ai selection")
  if not bufnr then
    return
  end
  local range = context.get_visual_selection_range()
  vim.ui.input({ prompt = context.format_prompt_label(bufnr, range) }, function(input)
    if input then
      M.run({
        message = input,
        bufnr = bufnr,
        build_context = function()
          return context.get_visual_context(bufnr, config.get())
        end,
      })
    end
  end)
end

function M.cancel()
  if not active_connection then
    return
  end
  active_connection:cancel()
  finish_if_done(active_session)
end

function M.statusline()
  return status.line()
end

function M.open()
  view.open(active_session or last_session)
end

function M.close()
  view.close()
end

function M.toggle()
  view.toggle(active_session or last_session)
end

function M.is_running()
  return active_session ~= nil
end

function M._get_active_session()
  return active_session
end

function M._get_last_session()
  return last_session
end

function M._get_active_connection()
  return active_connection
end

local subcommands = {
  ask = true,
  selection = true,
  cancel = true,
  status = true,
  open = true,
  close = true,
  toggle = true,
}

function M.complete(arglead)
  local out = {}
  for command in pairs(subcommands) do
    if command:sub(1, #arglead) == arglead then
      out[#out + 1] = command
    end
  end
  table.sort(out)
  return out
end

function M.command(opts)
  opts = opts or {}
  local args = opts.fargs or {}
  local subcommand = string.lower(args[1] or "ask")
  if subcommand == "ask" then
    M.prompt_with_buffer()
  elseif subcommand == "selection" then
    M.prompt_with_selection()
  elseif subcommand == "cancel" then
    M.cancel()
  elseif subcommand == "status" then
    vim.notify(status.line() ~= "" and status.line() or "AI idle", vim.log.levels.INFO)
  elseif subcommand == "open" then
    M.open()
  elseif subcommand == "close" then
    M.close()
  elseif subcommand == "toggle" then
    M.toggle()
  else
    vim.notify("Unknown :Ai subcommand: " .. tostring(subcommand), vim.log.levels.ERROR)
  end
end

return M
