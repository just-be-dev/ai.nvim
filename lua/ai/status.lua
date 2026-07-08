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
local indicator_buf = nil
local indicator_win = nil
local indicator_augroup = nil

local function valid_indicator_win()
  return indicator_win and vim.api.nvim_win_is_valid(indicator_win)
end

local function valid_indicator_buf()
  return indicator_buf and vim.api.nvim_buf_is_valid(indicator_buf)
end

local function close_indicator()
  if valid_indicator_win() then
    pcall(vim.api.nvim_win_close, indicator_win, true)
  end
  indicator_win = nil
end

local function format_line()
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

local function ensure_indicator_buffer()
  if valid_indicator_buf() then
    return indicator_buf
  end
  indicator_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[indicator_buf].buftype = "nofile"
  vim.bo[indicator_buf].bufhidden = "hide"
  vim.bo[indicator_buf].swapfile = false
  vim.bo[indicator_buf].modifiable = false
  vim.api.nvim_buf_set_name(indicator_buf, "ai-status://indicator")
  return indicator_buf
end

local function normal_target_win()
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(current) and vim.api.nvim_win_get_config(current).relative == "" then
    return current
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
  return nil
end

local function set_indicator_text(buf, text)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.bo[buf].modifiable = false
end

local function indicator_config(win, width)
  local win_width = math.max(1, vim.api.nvim_win_get_width(win))
  local win_height = math.max(1, vim.api.nvim_win_get_height(win))
  return {
    relative = "win",
    win = win,
    anchor = "SE",
    row = win_height,
    col = win_width,
    width = math.min(width, win_width),
    height = 1,
    focusable = false,
    style = "minimal",
    zindex = 50,
  }
end

local function refresh_indicator()
  if not active[state.status] then
    close_indicator()
    return
  end

  local target = normal_target_win()
  if not target then
    close_indicator()
    return
  end

  local text = " " .. format_line() .. " "
  local width = math.max(1, vim.fn.strdisplaywidth(text))
  local buf = ensure_indicator_buffer()
  set_indicator_text(buf, text)

  pcall(vim.api.nvim_set_hl, 0, "AiIndicator", { link = "StatusLine", default = true })

  local cfg = indicator_config(target, width)
  if valid_indicator_win() then
    local ok = pcall(vim.api.nvim_win_set_config, indicator_win, cfg)
    if not ok then
      close_indicator()
    end
  end
  if not valid_indicator_win() then
    local ok, win = pcall(vim.api.nvim_open_win, buf, false, cfg)
    if not ok then
      return
    end
    indicator_win = win
    vim.wo[indicator_win].wrap = false
    vim.wo[indicator_win].winhighlight = "Normal:AiIndicator"
  end
end

local function ensure_indicator_autocmds()
  if indicator_augroup then
    return
  end
  indicator_augroup = vim.api.nvim_create_augroup("AiStatusIndicator", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "TabEnter", "VimResized", "WinEnter", "WinScrolled", "WinResized" }, {
    group = indicator_augroup,
    callback = function()
      refresh_indicator()
    end,
  })
end

local function redraw()
  refresh_indicator()
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
  ensure_indicator_autocmds()
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
  return format_line()
end

function M.reset()
  stop_timer()
  close_indicator()
  ensure_indicator_autocmds()
  state = {
    status = "idle",
    agent = "agent",
    active_tool = nil,
    last_error = nil,
    spinner_idx = 0,
  }
  redraw()
end

function M._indicator_win()
  return valid_indicator_win() and indicator_win or nil
end

return M
