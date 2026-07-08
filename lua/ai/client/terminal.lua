local session_mod = require("ai.session")

local M = {}

local next_id = 0
local terminals = {}

local function append_output(term, chunk)
  if not chunk or chunk == "" then
    return
  end
  term.output = (term.output or "") .. chunk
  local limit = term.output_byte_limit or 1024 * 1024
  if #term.output > limit then
    term.output = term.output:sub(#term.output - limit + 1)
    term.truncated = true
  end
end

local function env_list_to_map(env)
  if type(env) ~= "table" then
    return env
  end
  local out = {}
  local is_list = false
  for key, value in pairs(env) do
    if type(key) == "number" and type(value) == "table" and value.name then
      is_list = true
      out[value.name] = value.value
    else
      out[key] = value
    end
  end
  if is_list then
    return out
  end
  return env
end

local function finish(term, code, signal)
  if term.exit_status then
    return
  end
  term.exit_status = {
    exitCode = code,
    signal = signal,
  }
  for _, waiter in ipairs(term.waiters or {}) do
    waiter(term.exit_status)
  end
  term.waiters = {}
end

function M.create(session, params, cfg)
  if type(params) ~= "table" or type(params.command) ~= "string" then
    return nil, "invalid params"
  end
  next_id = next_id + 1
  local id = "ai-term-" .. next_id
  local command = { params.command }
  for _, arg in ipairs(params.args or {}) do
    command[#command + 1] = tostring(arg)
  end

  local term = {
    id = id,
    command = command,
    cwd = params.cwd,
    output = "",
    truncated = false,
    exit_status = nil,
    waiters = {},
    released = false,
    output_byte_limit = params.outputByteLimit or (cfg and cfg.output_byte_limit) or 1024 * 1024,
  }
  terminals[id] = term
  if session then
    session.terminals[id] = term
    session_mod.push(session, "terminal", { terminal_id = id, output = "" })
  end

  local ok, handle = pcall(vim.system, command, {
    text = true,
    cwd = params.cwd,
    env = env_list_to_map(params.env),
    stdout = vim.schedule_wrap(function(err, data)
      if err then
        append_output(term, tostring(err))
      else
        append_output(term, data)
      end
    end),
    stderr = vim.schedule_wrap(function(err, data)
      if err then
        append_output(term, tostring(err))
      else
        append_output(term, data)
      end
    end),
  }, vim.schedule_wrap(function(result)
    finish(term, result and result.code or nil, result and result.signal or nil)
  end))

  if not ok then
    terminals[id] = nil
    if session then
      session.terminals[id] = nil
    end
    return nil, handle
  end
  term.handle = handle
  return { terminalId = id }
end

function M.output(params)
  local id = params and params.terminalId
  local term = id and terminals[id]
  if not term then
    return nil, "unknown terminal"
  end
  return {
    output = term.output or "",
    truncated = term.truncated == true,
    exitStatus = term.exit_status,
  }
end

function M.wait_for_exit(params, callback)
  local id = params and params.terminalId
  local term = id and terminals[id]
  if not term then
    return nil, "unknown terminal"
  end
  if term.exit_status then
    return term.exit_status
  end
  term.waiters[#term.waiters + 1] = callback
  return nil, nil, true
end

function M.kill(params)
  local id = params and params.terminalId
  local term = id and terminals[id]
  if not term then
    return nil, "unknown terminal"
  end
  if term.handle and not term.exit_status then
    pcall(term.handle.kill, term.handle, 15)
  end
  return vim.NIL
end

function M.release(params)
  local id = params and params.terminalId
  local term = id and terminals[id]
  if not term then
    return nil, "unknown terminal"
  end
  if term.handle and not term.exit_status then
    pcall(term.handle.kill, term.handle, 15)
  end
  term.released = true
  terminals[id] = nil
  return vim.NIL
end

function M._get(id)
  return terminals[id]
end

function M._reset()
  terminals = {}
  next_id = 0
end

return M
