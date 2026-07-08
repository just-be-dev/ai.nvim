local config = require("ai.config")
local fs = require("ai.client.fs")
local jsonrpc = require("ai.protocol.jsonrpc")
local LineBuffer = require("ai.protocol.line_buffer")
local permissions = require("ai.client.permissions")
local session_mod = require("ai.session")
local status = require("ai.status")
local terminal = require("ai.client.terminal")
local view = require("ai.view")

local M = {}
local Connection = {}
Connection.__index = Connection

local METHODS = {
  INITIALIZE = "initialize",
  AUTHENTICATE = "authenticate",
  SESSION_NEW = "session/new",
  SESSION_PROMPT = "session/prompt",
  SESSION_CANCEL = "session/cancel",
  SESSION_UPDATE = "session/update",
  SESSION_REQUEST_PERMISSION = "session/request_permission",
  FS_READ_TEXT_FILE = "fs/read_text_file",
  FS_WRITE_TEXT_FILE = "fs/write_text_file",
  TERMINAL_CREATE = "terminal/create",
  TERMINAL_OUTPUT = "terminal/output",
  TERMINAL_WAIT_FOR_EXIT = "terminal/wait_for_exit",
  TERMINAL_KILL = "terminal/kill",
  TERMINAL_RELEASE = "terminal/release",
}

local function notify_error(message)
  if config.get().ui.notify.errors then
    vim.notify(message, vim.log.levels.ERROR)
  end
end

local function extract_text(block)
  if type(block) ~= "table" then
    return nil
  end
  if block.type == "text" and type(block.text) == "string" then
    return block.text
  end
  if block.type == "resource" and block.resource and type(block.resource.text) == "string" then
    return block.resource.text
  end
  if block.type == "resource_link" and type(block.uri) == "string" then
    return "[resource: " .. block.uri .. "]"
  end
  return nil
end


function Connection.new(session, cfg, handlers)
  local self = setmetatable({
    cfg = cfg,
    session = session,
    handlers = handlers or {},
    process = nil,
    next_id = 0,
    pending = {},
    line_buffer = LineBuffer.new(),
    initialized = false,
    authenticated = false,
    agent_info = nil,
    prompt_id = nil,
  }, Connection)
  return self
end

function Connection:next_request_id()
  self.next_id = self.next_id + 1
  return self.next_id
end

function Connection:write_message(message)
  if not self.process then
    return false, "agent process is not running"
  end
  local ok, err = pcall(self.process.write, self.process, message)
  if not ok then
    return false, err
  end
  return true
end

function Connection:send_raw(tbl)
  return self:write_message(vim.json.encode(tbl) .. "\n")
end

function Connection:request(method, params, callback)
  local id = self:next_request_id()
  self.pending[id] = callback or true
  local ok, err = self:send_raw(jsonrpc.request(id, method, params))
  if not ok then
    self.pending[id] = nil
    if callback then
      callback(nil, err)
    end
    return nil, err
  end
  return id
end

function Connection:notification(method, params)
  return self:send_raw(jsonrpc.notification(method, params))
end

function Connection:send_result(id, result)
  return self:send_raw(jsonrpc.result(id, result))
end

function Connection:send_error(id, message, code)
  return self:send_raw(jsonrpc.error(id, message, code))
end

function Connection:start()
  local command = vim.deepcopy(self.cfg.agent.command)
  for i, part in ipairs(command) do
    command[i] = vim.fn.expand(part)
  end
  status.set({ status = "starting", agent = self.cfg.agent.name })

  local ok, process = pcall(vim.system, command, {
    text = true,
    stdin = true,
    cwd = self.cfg.agent.cwd or vim.fn.getcwd(),
    env = self.cfg.agent.env,
    stdout = vim.schedule_wrap(function(err, data)
      if err then
        self:fail(err)
        return
      end
      self.line_buffer:push(data, function(line)
        self:handle_line(line)
      end)
    end),
    stderr = vim.schedule_wrap(function(err, data)
      if err then
        session_mod.push(self.session, "error", { message = tostring(err) })
      elseif data and data ~= "" then
        session_mod.push(self.session, "message", { role = "stderr", text = data })
      end
      view.update(self.session)
    end),
  }, vim.schedule_wrap(function(result)
    self:handle_exit(result)
  end))

  if not ok then
    self:fail(process)
    return false
  end
  self.process = process
  self.session.process = process
  return true
end

function Connection:connect_then_prompt(prompt_blocks)
  if not self:start() then
    return
  end
  self:initialize(function(ok, err)
    if not ok then
      self:fail(err or "initialize failed")
      return
    end
    self:authenticate(function(auth_ok, auth_err)
      if not auth_ok then
        self:fail(auth_err or "authenticate failed")
        return
      end
      self:new_session(function(session_ok, session_err)
        if not session_ok then
          self:fail(session_err or "session/new failed")
          return
        end
        self:prompt(prompt_blocks)
      end)
    end)
  end)
end

function Connection:initialize(callback)
  self:request(METHODS.INITIALIZE, {
    protocolVersion = 1,
    clientCapabilities = {
      fs = {
        readTextFile = true,
        writeTextFile = true,
      },
      terminal = true,
      session = {
        configOptions = {
          boolean = {},
        },
      },
    },
    clientInfo = {
      name = "ai.nvim",
      title = "ai.nvim",
      version = "0.1.0",
    },
  }, function(result, err)
    if not result then
      callback(false, err or "initialize returned no result")
      return
    end
    self.agent_info = result
    self.initialized = true
    callback(true)
  end)
end

function Connection:authenticate(callback)
  local methods = self.agent_info and self.agent_info.authMethods or {}
  if #methods == 0 then
    self.authenticated = true
    callback(true)
    return
  end
  local selected = methods[1]
  for _, method in ipairs(methods) do
    if method.id == "agent" then
      selected = method
      break
    end
  end
  self:request(METHODS.AUTHENTICATE, { methodId = selected.id }, function(result, err)
    if result == nil and err then
      callback(false, err)
      return
    end
    self.authenticated = true
    callback(true)
  end)
end

function Connection:new_session(callback)
  self:request(METHODS.SESSION_NEW, {
    cwd = self.cfg.agent.cwd or vim.fn.getcwd(),
    mcpServers = {},
  }, function(result, err)
    if not result or not result.sessionId then
      callback(false, err or "session/new returned no sessionId")
      return
    end
    self.session.acp_session_id = result.sessionId
    self.session.status = "ready"
    status.set({ status = "ready", agent = self.cfg.agent.name })
    view.update(self.session)
    callback(true)
  end)
end

function Connection:prompt(prompt_blocks)
  self.session.status = "prompting"
  status.set({ status = "prompting", agent = self.cfg.agent.name })
  view.update(self.session)
  self.prompt_id = self:request(METHODS.SESSION_PROMPT, {
    sessionId = self.session.acp_session_id,
    prompt = prompt_blocks,
  }, function(result, err)
    self.prompt_id = nil
    if err then
      self:fail(err)
      return
    end
    local stop_reason = result and result.stopReason or "end_turn"
    self:complete(stop_reason)
  end)
end

function Connection:cancel()
  self.session.cancelled = true
  permissions.cancel_all(self.session)
  if self.session.acp_session_id then
    self:notification(METHODS.SESSION_CANCEL, { sessionId = self.session.acp_session_id })
  end
  if self.process and not self.process:is_closing() then
    pcall(self.process.kill, self.process, 15)
  end
  self.session.status = "cancelled"
  status.set({ status = "cancelled" })
  view.update(self.session)
  if self.handlers.on_finish then
    pcall(self.handlers.on_finish, self.session)
  end
end

function Connection:complete(stop_reason)
  if self.session.cancelled or stop_reason == "canceled" or stop_reason == "cancelled" then
    self.session.status = "cancelled"
    status.set({ status = "cancelled" })
  elseif stop_reason == "end_turn" or stop_reason == nil then
    self.session.status = "done"
    status.set({ status = "done" })
  else
    self.session.status = "error"
    self.session.last_error = tostring(stop_reason)
    status.set({ status = "error", last_error = self.session.last_error })
  end
  self.session.ended_at = vim.loop.hrtime()
  view.update(self.session)
  if self.handlers.on_done and self.session.status == "done" then
    pcall(self.handlers.on_done, self.session)
  end
  if self.handlers.on_finish then
    pcall(self.handlers.on_finish, self.session)
  end
end

function Connection:fail(err)
  local message = tostring(err or "unknown error")
  self.session.status = "error"
  self.session.last_error = message
  session_mod.push(self.session, "error", { message = message })
  status.set({ status = "error", last_error = message })
  notify_error("ai.nvim: " .. message)
  view.update(self.session)
  if self.handlers.on_finish then
    pcall(self.handlers.on_finish, self.session)
  end
end

function Connection:handle_exit(result)
  self.line_buffer:flush(function(line)
    self:handle_line(line)
  end)
  if self.session.cancelled then
    return
  end
  if self.session.status ~= "done" and self.session.status ~= "error" and self.session.status ~= "cancelled" then
    local code = result and result.code or 0
    if code ~= 0 then
      self:fail("agent exited with code " .. tostring(code))
    end
  end
end

function Connection:handle_line(line)
  local message = jsonrpc.decode(line)
  if not message then
    session_mod.push(self.session, "message", { role = "stdout", text = line })
    view.update(self.session)
    return
  end

  if message.id ~= nil and not message.method then
    local callback = self.pending[message.id]
    self.pending[message.id] = nil
    if type(callback) == "function" then
      if message.error then
        callback(nil, message.error.message or "request failed")
      else
        callback(message.result, nil)
      end
    end
    return
  end

  if message.method then
    self:handle_method(message)
  end
end

function Connection:handle_method(message)
  local method = message.method
  local params = message.params or {}
  if method == METHODS.SESSION_UPDATE then
    self:handle_session_update(params)
    return
  end
  if method == METHODS.SESSION_REQUEST_PERMISSION then
    permissions.request(self.session, message.id, params, function(outcome)
      self:send_result(message.id, { outcome = outcome })
    end, self.cfg.permissions)
    view.update(self.session)
    return
  end
  if method == METHODS.FS_READ_TEXT_FILE then
    local result, err = fs.read_text_file(params)
    if result then
      self:send_result(message.id, result)
    else
      self:send_error(message.id, "fs/read_text_file failed: " .. tostring(err), jsonrpc.errors.INVALID_PARAMS)
    end
    return
  end
  if method == METHODS.FS_WRITE_TEXT_FILE then
    local result, err = fs.write_text_file(params)
    if result ~= nil then
      self:send_result(message.id, result)
      session_mod.push(self.session, "tool", { id = "fs/write", title = "Wrote " .. params.path, status = "completed", kind = "edit" })
      view.update(self.session)
    else
      self:send_error(message.id, "fs/write_text_file failed: " .. tostring(err), jsonrpc.errors.INTERNAL)
    end
    return
  end
  if method == METHODS.TERMINAL_CREATE then
    local result, err = terminal.create(self.session, params, self.cfg.terminal)
    if result then
      self:send_result(message.id, result)
      view.update(self.session)
    else
      self:send_error(message.id, "terminal/create failed: " .. tostring(err), jsonrpc.errors.INVALID_PARAMS)
    end
    return
  end
  if method == METHODS.TERMINAL_OUTPUT then
    local result, err = terminal.output(params)
    if result then
      self:send_result(message.id, result)
    else
      self:send_error(message.id, "terminal/output failed: " .. tostring(err), jsonrpc.errors.INVALID_PARAMS)
    end
    return
  end
  if method == METHODS.TERMINAL_WAIT_FOR_EXIT then
    local result, err, pending = terminal.wait_for_exit(params, function(exit_status)
      self:send_result(message.id, exit_status)
      view.update(self.session)
    end)
    if pending then
      return
    end
    if result then
      self:send_result(message.id, result)
    else
      self:send_error(message.id, "terminal/wait_for_exit failed: " .. tostring(err), jsonrpc.errors.INVALID_PARAMS)
    end
    return
  end
  if method == METHODS.TERMINAL_KILL then
    local result, err = terminal.kill(params)
    if result ~= nil then
      self:send_result(message.id, result)
    else
      self:send_error(message.id, "terminal/kill failed: " .. tostring(err), jsonrpc.errors.INVALID_PARAMS)
    end
    return
  end
  if method == METHODS.TERMINAL_RELEASE then
    local result, err = terminal.release(params)
    if result ~= nil then
      self:send_result(message.id, result)
    else
      self:send_error(message.id, "terminal/release failed: " .. tostring(err), jsonrpc.errors.INVALID_PARAMS)
    end
    return
  end
  if message.id ~= nil then
    self:send_error(message.id, "method not found: " .. tostring(method), jsonrpc.errors.METHOD_NOT_FOUND)
  end
end

function Connection:handle_session_update(params)
  if params.sessionId and self.session.acp_session_id and params.sessionId ~= self.session.acp_session_id then
    return
  end
  local update = params.update or {}
  local kind = update.sessionUpdate
  if kind == "agent_message_chunk" then
    local text = extract_text(update.content)
    session_mod.add_text(self.session, "agent", text)
    self.session.status = "thinking"
    status.set({ status = "thinking", agent = self.cfg.agent.name })
  elseif kind == "agent_thought_chunk" then
    local text = extract_text(update.content)
    session_mod.add_text(self.session, "thought", text)
    self.session.status = "thinking"
    status.set({ status = "thinking", agent = self.cfg.agent.name })
  elseif kind == "plan" then
    session_mod.add_plan(self.session, update.entries or {})
    self.session.status = "thinking"
    status.set({ status = "thinking", agent = self.cfg.agent.name })
  elseif kind == "tool_call" or kind == "tool_call_update" then
    session_mod.upsert_tool(self.session, update)
    if self.session.active_tool then
      self.session.status = "running_tool"
      status.set({ status = "running_tool", agent = self.cfg.agent.name, active_tool = self.session.active_tool })
    else
      self.session.status = "thinking"
      status.set({ status = "thinking", agent = self.cfg.agent.name, active_tool = nil })
    end
  elseif kind == "usage_update" then
    self.session.usage = update
  elseif kind == "available_commands_update" then
    self.session.available_commands = update.availableCommands or update.commands
  elseif kind == "config_option_update" then
    self.session.config_options = update.configOptions or {}
  end
  view.update(self.session)
end

function M.new(session, cfg, handlers)
  return Connection.new(session, cfg, handlers)
end

M.METHODS = METHODS

return M
