local config = require("ai.config")

local M = {}

local bufnr = nil
local winnr = nil
local attached_session = nil

local function valid_buf()
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win()
  return winnr and vim.api.nvim_win_is_valid(winnr)
end

local function ensure_buffer()
  if valid_buf() then
    return bufnr
  end
  bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = "ai-agent"
  vim.api.nvim_buf_set_name(bufnr, "ai-session://transcript")
  return bufnr
end

local function open_window()
  local cfg = config.get().ui.window
  local buf = ensure_buffer()
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
  vim.api.nvim_win_set_buf(winnr, buf)
  vim.wo[winnr].wrap = true
  vim.wo[winnr].linebreak = true
end

local function append_wrapped(lines, prefix, text)
  text = tostring(text or "")
  if text == "" then
    return
  end
  local first = true
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if first then
      lines[#lines + 1] = prefix .. line
      first = false
    else
      lines[#lines + 1] = string.rep(" ", #prefix) .. line
    end
  end
end

local function render_tool(lines, item)
  local status = item.status or "pending"
  local title = item.title or item.toolName or item.id or "tool"
  lines[#lines + 1] = string.format("  [%s] %s", status, title)
  if item.kind then
    lines[#lines + 1] = "      kind: " .. item.kind
  end
  if item.content then
    for _, content in ipairs(item.content) do
      if content.type == "content" and content.content and content.content.text then
        append_wrapped(lines, "      ", content.content.text)
      elseif content.type == "terminal" and content.terminalId and attached_session then
        local terminal = attached_session.terminals[content.terminalId]
        if terminal then
          append_wrapped(lines, "      ", terminal.output or "")
        else
          lines[#lines + 1] = "      terminal: " .. content.terminalId
        end
      elseif content.type == "diff" and content.path then
        lines[#lines + 1] = "      diff: " .. content.path
      end
    end
  end
end

local function render(session)
  local lines = {}
  lines[#lines + 1] = string.format("AI · %s · %s", session and session.agent or "agent", session and (session.acp_session_id or "no-session") or "idle")
  lines[#lines + 1] = string.rep("─", 72)

  if not session then
    lines[#lines + 1] = "Idle"
    return lines
  end

  lines[#lines + 1] = "Status: " .. tostring(session.status)
  if session.last_error then
    lines[#lines + 1] = "Error: " .. tostring(session.last_error)
  end
  lines[#lines + 1] = ""

  for _, item in ipairs(session.transcript or {}) do
    if item.kind == "message" then
      local role = item.role == "user" and "User" or "Agent"
      lines[#lines + 1] = role
      append_wrapped(lines, "  ", item.text)
      lines[#lines + 1] = ""
    elseif item.kind == "plan" then
      lines[#lines + 1] = "Plan"
      for _, entry in ipairs(item.entries or {}) do
        local status = entry.status or "pending"
        local content = entry.content or entry.title or tostring(entry)
        lines[#lines + 1] = string.format("  [%s] %s", status, content)
      end
      lines[#lines + 1] = ""
    elseif item.kind == "tool" then
      lines[#lines + 1] = "Tool"
      render_tool(lines, item)
      lines[#lines + 1] = ""
    elseif item.kind == "terminal" then
      lines[#lines + 1] = "Terminal " .. tostring(item.terminal_id)
      append_wrapped(lines, "  ", item.output or "")
      lines[#lines + 1] = ""
    elseif item.kind == "permission" then
      lines[#lines + 1] = "Permission requested"
      if item.tool_call and item.tool_call.title then
        lines[#lines + 1] = "  " .. item.tool_call.title
      end
      lines[#lines + 1] = ""
    elseif item.kind == "error" then
      lines[#lines + 1] = "Error"
      append_wrapped(lines, "  ", item.message)
      lines[#lines + 1] = ""
    end
  end
  return lines
end

function M.update(session)
  attached_session = session or attached_session
  if not valid_buf() then
    return
  end
  local lines = render(attached_session)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  if valid_win() then
    pcall(vim.api.nvim_win_set_cursor, winnr, { math.max(1, #lines), 0 })
  end
end

function M.open(session)
  attached_session = session or attached_session
  open_window()
  M.update(attached_session)
end

function M.close()
  if valid_win() then
    pcall(vim.api.nvim_win_close, winnr, true)
  end
  winnr = nil
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
