local config = require("ai.config")

local M = {}

local bufnr = nil
local winnr = nil
local attached_session = nil
local terminal_session_id = nil
local pending_open = false

local function valid_buf()
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win()
  return winnr and vim.api.nvim_win_is_valid(winnr)
end

local function close_buffer()
  if valid_buf() then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  bufnr = nil
  terminal_session_id = nil
end

local function close_window()
  if valid_win() then
    pcall(vim.api.nvim_win_close, winnr, true)
  end
  winnr = nil
end

local function open_window()
  local cfg = config.get().ui.window
  if valid_win() then
    vim.api.nvim_set_current_win(winnr)
    return
  end

  if cfg.position == "right" then
    vim.cmd("botright vertical new")
    winnr = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(winnr, math.max(40, math.floor(vim.o.columns * 0.33)))
  else
    vim.cmd("botright new")
    winnr = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_height(winnr, cfg.height)
  end
end

local function resume_command(session_id)
  local cmd = vim.deepcopy(config.get().agent.resume_command or { "omp", "--resume" })
  cmd[#cmd + 1] = session_id
  return cmd
end

local function terminal_env()
  local env = config.get().agent.env
  if not env then
    return nil
  end

  local out = {}
  for key, value in pairs(env) do
    out[tostring(key)] = tostring(value)
  end
  return out
end

local function open_terminal(session)
  local session_id = session and session.acp_session_id
  if not session_id then
    pending_open = true
    return false
  end

  if valid_win() and valid_buf() and terminal_session_id == session_id then
    vim.api.nvim_set_current_win(winnr)
    return true
  end

  M.close()
  open_window()

  bufnr = vim.api.nvim_create_buf(false, true)
  terminal_session_id = session_id
  vim.api.nvim_buf_set_name(bufnr, "ai-session://omp-resume/" .. session_id)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "ai-agent-terminal"
  vim.api.nvim_win_set_buf(winnr, bufnr)

  local cfg = config.get()
  vim.api.nvim_buf_call(bufnr, function()
    local job_id = vim.fn.termopen(resume_command(session_id), {
      cwd = cfg.agent.cwd or vim.fn.getcwd(),
      env = terminal_env(),
    })
    if job_id <= 0 then
      vim.notify("Failed to open AI terminal", vim.log.levels.ERROR)
    end
  end)

  vim.cmd("startinsert")
  return true
end

function M.update(session)
  attached_session = session or attached_session
  if pending_open and attached_session and attached_session.acp_session_id then
    pending_open = false
    open_terminal(attached_session)
  end
end

function M.open(session)
  attached_session = session or attached_session
  if not attached_session then
    vim.notify("No AI session to open", vim.log.levels.INFO)
    return
  end
  if not open_terminal(attached_session) then
    vim.notify("AI session is starting; terminal will open when ready", vim.log.levels.INFO)
  end
end

function M.close()
  pending_open = false
  close_window()
  close_buffer()
end

function M.toggle(session)
  if valid_win() then
    M.close()
  else
    M.open(session)
  end
end

function M.is_open()
  return valid_win()
end

return M
