local M = {}

local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local active = {
  starting = true,
  ready = true,
  prompting = true,
  thinking = true,
  running_tool = true,
  waiting_permission = true,
}

local state = {
  status = "idle",
  agent = "agent",
  active_tool = nil,
  last_error = nil,
  spinner_idx = 0,
}
local timer = nil

local function redraw()
  pcall(vim.cmd, "redrawstatus")
end

local function stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

local function ensure_timer()
  if timer or not active[state.status] then
    return
  end
  timer = vim.loop.new_timer()
  timer:start(120, 120, vim.schedule_wrap(function()
    if not active[state.status] then
      stop_timer()
      redraw()
      return
    end
    state.spinner_idx = (state.spinner_idx % #spinner) + 1
    redraw()
  end))
end

function M.set(next_state)
  state = vim.tbl_extend("force", state, next_state or {})
  if active[state.status] then
    ensure_timer()
  else
    stop_timer()
  end
  redraw()
end

function M.get()
  return vim.deepcopy(state)
end

function M.is_running()
  return active[state.status] == true
end

function M.line()
  if state.status == "idle" then
    return ""
  end

  local prefix = "AI"
  if active[state.status] then
    state.spinner_idx = state.spinner_idx == 0 and 1 or state.spinner_idx
    prefix = spinner[state.spinner_idx] .. " " .. prefix
  end

  if state.status == "starting" then
    return prefix .. " starting " .. (state.agent or "agent")
  end
  if state.status == "ready" then
    return prefix .. " ready"
  end
  if state.status == "prompting" then
    return prefix .. " prompting"
  end
  if state.status == "thinking" then
    return prefix .. " thinking"
  end
  if state.status == "running_tool" then
    local tool = state.active_tool
    local title = tool and (tool.title or tool.toolName or tool.id) or "tool"
    return prefix .. " " .. title
  end
  if state.status == "waiting_permission" then
    return prefix .. " waiting permission"
  end
  if state.status == "done" then
    return "AI done"
  end
  if state.status == "cancelled" then
    return "AI cancelled"
  end
  if state.status == "error" then
    return "AI failed: " .. tostring(state.last_error or "unknown error")
  end
  return "AI " .. tostring(state.status)
end

function M.reset()
  stop_timer()
  state = {
    status = "idle",
    agent = "agent",
    active_tool = nil,
    last_error = nil,
    spinner_idx = 0,
  }
  redraw()
end

return M
