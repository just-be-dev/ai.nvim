local session_mod = require("ai.session")
local status = require("ai.status")

local M = {}

local pending = {}

local function option_label(option)
  return option.name or option.optionId or "option"
end

function M.request(session, id, params, respond, cfg)
  if not id then
    return
  end
  local request = {
    id = id,
    params = params,
    respond = respond,
  }
  pending[id] = request
  if session then
    session.pending_permissions[id] = request
    session_mod.push(session, "permission", { tool_call = params and params.toolCall, options = params and params.options or {} })
  end
  status.set({ status = "waiting_permission" })

  local options = params and params.options or {}
  if cfg and cfg.auto_approve then
    for _, option in ipairs(options) do
      if option.kind == "allow_always" or option.kind == "allow_once" then
        pending[id] = nil
        if session then
          session.pending_permissions[id] = nil
        end
        respond({ outcome = "selected", optionId = option.optionId })
        return
      end
    end
  end

  vim.ui.select(options, {
    prompt = "AI agent requests permission",
    format_item = option_label,
  }, function(choice)
    pending[id] = nil
    if session then
      session.pending_permissions[id] = nil
    end
    if not choice then
      respond({ outcome = "cancelled" })
      return
    end
    respond({ outcome = "selected", optionId = choice.optionId })
  end)
end

function M.cancel_all(session)
  for id, request in pairs(pending) do
    pcall(request.respond, { outcome = "cancelled" })
    pending[id] = nil
    if session then
      session.pending_permissions[id] = nil
    end
  end
end

function M._pending()
  return pending
end

return M
