local M = {}

local next_id = 0

function M.new(source_bufnr, opts)
  opts = opts or {}
  next_id = next_id + 1
  return {
    id = next_id,
    acp_session_id = nil,
    status = "idle",
    agent = opts.agent or "agent",
    process = nil,
    source_bufnr = source_bufnr,
    source_path = source_bufnr and vim.api.nvim_buf_get_name(source_bufnr) or nil,
    started_at = vim.loop.hrtime(),
    ended_at = nil,
    active_tool = nil,
    tools = {},
    tool_order = {},
    terminals = {},
    pending_permissions = {},
    last_error = nil,
    last_message = nil,
    cancelled = false,
    transcript = {},
    file_snapshots = {},
    skip_reload = false,
    on_done = nil,
  }
end

function M.push(session, kind, payload)
  if not session then
    return
  end
  session.transcript[#session.transcript + 1] = vim.tbl_extend("force", {
    kind = kind,
    at = vim.loop.hrtime(),
  }, payload or {})
end

function M.add_text(session, role, text)
  if not text or text == "" then
    return
  end
  M.push(session, "message", { role = role, text = text })
  session.last_message = text
end

function M.upsert_tool(session, update)
  if not update or not update.toolCallId then
    return
  end
  local id = update.toolCallId
  local existing = session.tools[id]
  if not existing then
    existing = { id = id }
    session.tools[id] = existing
    session.tool_order[#session.tool_order + 1] = id
  end
  for k, v in pairs(update) do
    existing[k] = v
  end
  if existing.status == "completed" or existing.status == "failed" then
    session.active_tool = nil
  else
    session.active_tool = existing
  end
  M.push(session, "tool", vim.deepcopy(existing))
end

function M.add_plan(session, entries)
  session.plan = entries or {}
  M.push(session, "plan", { entries = session.plan })
end

return M
