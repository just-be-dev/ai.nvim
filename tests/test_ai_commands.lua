local MiniTest = require("mini.test")

local child = MiniTest.new_child_neovim()

local function flush()
  child.lua([[vim.wait(50, function() return false end, 10)]])
end

local function setup_test_env(setup_code)
  child.restart({ "-u", "tests/minimal_init.lua" })
  child.lua([[
    _G.__ai_test_notifications = {}
    _G.__ai_force_notify_backend = true
    vim.notify = function(msg, level)
      table.insert(_G.__ai_test_notifications, { msg = msg, level = level })
    end
  ]])
  child.lua(setup_code or 'require("ai").setup({})')
end

local function setup_buffer(lines, filename)
  child.lua(
    [[
      local lines, filename = ...
      vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
      if filename then
        vim.api.nvim_buf_set_name(0, filename)
      end
    ]],
    { lines, filename }
  )
end

local function setup_terminal_resume_env(auto_open)
  setup_test_env(string.format([[
    local args_file = vim.fn.tempname()
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({
      "#!/bin/sh",
      "args_file=$1",
      "shift",
      "printf '%%s\\n' \"$@\" > \"$args_file\"",
      "printf 'resume command started\\n'",
      "sleep 60",
    }, script)
    _G.__ai_resume_args_file = args_file
    _G.__ai_resume_script = script
    require("ai").setup({
      agent = {
        resume_command = { "sh", script, args_file, "--resume" },
      },
      ui = {
        window = { auto_open = %s },
      },
    })
  ]], tostring(auto_open == true)))
end

local function ai_view_state()
  return child.lua([[
    local state = {
      terminals = {},
      terminal_buffers = {},
      transcript_windows = 0,
    }
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local bufnr = vim.api.nvim_win_get_buf(win)
      local name = vim.api.nvim_buf_get_name(bufnr)
      if vim.bo[bufnr].buftype == "terminal" then
        table.insert(state.terminals, {
          win = win,
          bufnr = bufnr,
          name = name,
          job_id = vim.b[bufnr].terminal_job_id,
        })
      elseif name:match("ai%-session://transcript$") then
        state.transcript_windows = state.transcript_windows + 1
      end
    end
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "terminal" then
        table.insert(state.terminal_buffers, {
          bufnr = bufnr,
          name = vim.api.nvim_buf_get_name(bufnr),
          job_id = vim.b[bufnr].terminal_job_id,
        })
      end
    end
    return state
  ]])
end

local function wait_for_terminal_view()
  local ok = child.lua([[
    return vim.wait(1000, function()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local bufnr = vim.api.nvim_win_get_buf(win)
        if vim.bo[bufnr].buftype == "terminal" then
          return true
        end
      end
      return false
    end, 10)
  ]])
  MiniTest.expect.equality(ok, true)
  return ai_view_state()
end

local function wait_for_resume_args(expected)
  local ok = child.lua([[
    local expected = ...
    return vim.wait(1000, function()
      if vim.fn.filereadable(_G.__ai_resume_args_file) ~= 1 then
        return false
      end
      local actual = vim.fn.readfile(_G.__ai_resume_args_file)
      if #actual ~= #expected then
        return false
      end
      for i, value in ipairs(expected) do
        if actual[i] ~= value then
          return false
        end
      end
      return true
    end, 10)
  ]], { expected })
  MiniTest.expect.equality(ok, true)
  return child.lua_get([[vim.fn.readfile(_G.__ai_resume_args_file)]])
end

local function resume_args_file_exists()
  return child.lua_get([[vim.fn.filereadable(_G.__ai_resume_args_file) == 1]])
end

local function set_visual_marks(start_line, end_line)
  child.api.nvim_buf_set_mark(0, "<", start_line, 0, {})
  child.api.nvim_buf_set_mark(0, ">", end_line, 999, {})
end

local function write_file(path, lines)
  child.lua(
    [[
      local path, lines = ...
      vim.fn.writefile(lines, path)
    ]],
    { path, lines }
  )
end

local function read_file(path)
  return child.lua_get([[vim.fn.readfile(...)]], { path })
end

local function notifications()
  return child.lua_get([[_G.__ai_test_notifications]])
end

local function last_notification()
  local items = notifications()
  return items[#items]
end

local function floating_windows_matching(pattern)
  return child.lua([[
    local pattern = ...
    local matches = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local config = vim.api.nvim_win_get_config(win)
      if config.relative ~= "" then
        local bufnr = vim.api.nvim_win_get_buf(win)
        local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
        if text:match(pattern) then
          table.insert(matches, {
            win = win,
            text = text,
            relative = config.relative,
            anchor = config.anchor,
            focusable = config.focusable,
            height = config.height,
          })
        end
      end
    end
    return matches
  ]], { pattern })
end

local function install_system_mock()
  child.lua([[
    _G.__ai_test_system = {
      calls = {},
      agent = nil,
      terminals = {},
    }

    local function make_process(call)
      return {
        write = function(_, data)
          if data == nil then
            call.stdin_closed = true
            call.closing = true
          else
            table.insert(call.writes, data)
          end
        end,
        kill = function(_, signal)
          call.killed = signal
          call.closing = true
        end,
        is_closing = function()
          return call.closing
        end,
      }
    end

    vim.system = function(cmd, opts, on_exit)
      local call = {
        cmd = vim.deepcopy(cmd),
        opts = opts or {},
        on_exit = on_exit,
        writes = {},
        killed = nil,
        closing = false,
        stdin_closed = false,
      }
      call.process = make_process(call)
      table.insert(_G.__ai_test_system.calls, call)

      if _G.__ai_test_system.agent == nil then
        call.kind = "agent"
        _G.__ai_test_system.agent = call
      else
        call.kind = "terminal"
        table.insert(_G.__ai_test_system.terminals, call)
      end

      return call.process
    end
  ]])

  local system = {}


  function system.agent_stdin_closed()
    return child.lua_get([[_G.__ai_test_system.agent and _G.__ai_test_system.agent.stdin_closed or false]])
  end

  function system.agent_killed()
    return child.lua_get([[_G.__ai_test_system.agent and _G.__ai_test_system.agent.killed or nil]])
  end

  function system.agent_stdout(data)
    child.lua([[
      local data = ...
      _G.__ai_test_system.agent.opts.stdout(nil, data)
    ]], { data })
    flush()
  end

  function system.agent_exit(code, signal)
    child.lua([[
      local code, signal = ...
      _G.__ai_test_system.agent.on_exit({ code = code, signal = signal })
    ]], { code, signal or 0 })
    flush()
  end

  function system.terminal_cmd(index)
    return child.lua_get([[_G.__ai_test_system.terminals[...].cmd]], { index })
  end

  function system.terminal_killed(index)
    return child.lua_get([[_G.__ai_test_system.terminals[...].killed]], { index })
  end

  function system.terminal_stdout(index, data)
    child.lua([[
      local index, data = ...
      local term = _G.__ai_test_system.terminals[index]
      term.opts.stdout(nil, data)
    ]], { index, data })
    flush()
  end

  function system.terminal_stderr(index, data)
    child.lua([[
      local index, data = ...
      local term = _G.__ai_test_system.terminals[index]
      term.opts.stderr(nil, data)
    ]], { index, data })
    flush()
  end

  function system.terminal_exit(index, code, signal)
    child.lua([[
      local index, code, signal = ...
      local term = _G.__ai_test_system.terminals[index]
      term.closing = true
      term.on_exit({ code = code, signal = signal })
    ]], { index, code, signal })
    flush()
  end

  return system
end

local function outbound_messages()
  return child.lua([[
    local agent = _G.__ai_test_system.agent
    if not agent then
      return {}
    end
    local raw = table.concat(agent.writes, "")
    local messages = {}
    for line in raw:gmatch("([^\n]+)") do
      table.insert(messages, vim.json.decode(line))
    end
    return messages
  ]])
end

local function wait_for_outbound_count(count)
  local ok = child.lua([[
    local count = ...
    return vim.wait(1000, function()
      local agent = _G.__ai_test_system.agent
      if not agent then
        return false
      end
      local raw = table.concat(agent.writes, "")
      local seen = 0
      for _ in raw:gmatch("([^\n]+)") do
        seen = seen + 1
      end
      return seen >= count
    end, 10)
  ]], { count })
  MiniTest.expect.equality(ok, true)
end

local function find_response(id)
  return child.lua([[
    local id = ...
    local agent = _G.__ai_test_system.agent
    if not agent then
      return nil
    end
    local raw = table.concat(agent.writes, "")
    local found = nil
    for line in raw:gmatch("([^\n]+)") do
      local msg = vim.json.decode(line)
      if msg.id == id and msg.method == nil then
        found = msg
      end
    end
    return found
  ]], { id })
end

local function wait_for_response(id)
  local ok = child.lua([[
    local id = ...
    return vim.wait(1000, function()
      local agent = _G.__ai_test_system.agent
      if not agent then
        return false
      end
      local raw = table.concat(agent.writes, "")
      for line in raw:gmatch("([^\n]+)") do
        local msg = vim.json.decode(line)
        if msg.id == id and msg.method == nil then
          return true
        end
      end
      return false
    end, 10)
  ]], { id })
  MiniTest.expect.equality(ok, true)
  return find_response(id)
end

local function agent_response(system, id, result)
  system.agent_stdout(vim.json.encode({ jsonrpc = "2.0", id = id, result = result }) .. "\n")
end

local function agent_request(system, id, method, params)
  system.agent_stdout(vim.json.encode({ jsonrpc = "2.0", id = id, method = method, params = params or {} }) .. "\n")
end

local function agent_notification(system, method, params)
  system.agent_stdout(vim.json.encode({ jsonrpc = "2.0", method = method, params = params or {} }) .. "\n")
end

local function prompt_via_ai(input_text)
  child.lua([[
    local input_text = ...
    vim.ui.input = function(_, callback)
      callback(input_text)
    end
  ]], { input_text })
  child.cmd("Ai ask")
  flush()
end

local function start_prompt(input_text)
  local system = install_system_mock()
  prompt_via_ai(input_text)
  wait_for_outbound_count(1)
  return system
end

local function establish_session(system, session_id)
  session_id = session_id or "sess-test"

  local messages = outbound_messages()
  local initialize = messages[1]
  MiniTest.expect.equality(initialize.method, "initialize")
  MiniTest.expect.equality(initialize.params.protocolVersion, 1)
  MiniTest.expect.equality(initialize.params.clientCapabilities.fs.readTextFile, true)
  MiniTest.expect.equality(initialize.params.clientCapabilities.fs.writeTextFile, true)
  MiniTest.expect.equality(initialize.params.clientCapabilities.terminal, true)

  agent_response(system, initialize.id, {
    protocolVersion = 1,
    agentCapabilities = {
      promptCapabilities = { embeddedContext = true },
    },
    agentInfo = { name = "test-agent", version = "1.0.0" },
    authMethods = {},
  })

  wait_for_outbound_count(2)
  messages = outbound_messages()
  local new_session = messages[2]
  MiniTest.expect.equality(new_session.method, "session/new")
  MiniTest.expect.equality(type(new_session.params.cwd), "string")
  MiniTest.expect.no_equality(new_session.params.cwd, "")

  agent_response(system, new_session.id, { sessionId = session_id })

  wait_for_outbound_count(3)
  messages = outbound_messages()
  local prompt = messages[3]
  MiniTest.expect.equality(prompt.method, "session/prompt")
  MiniTest.expect.equality(prompt.params.sessionId, session_id)
  return prompt
end

local function finish_prompt(system, prompt_request, stop_reason)
  agent_response(system, prompt_request.id, { stopReason = stop_reason or "end_turn" })
end

local function test_ai_dispatcher_replaces_legacy_commands()
  setup_test_env()

  local commands = child.lua([[
    return {
      Ai = vim.fn.exists(":Ai"),
      AiAsk = vim.fn.exists(":AiAsk"),
      PiAsk = vim.fn.exists(":PiAsk"),
      PiAskSelection = vim.fn.exists(":PiAskSelection"),
      PiCancel = vim.fn.exists(":PiCancel"),
    }
  ]])

  MiniTest.expect.equality(commands.Ai, 2)
  MiniTest.expect.equality(commands.AiAsk, 0)
  MiniTest.expect.equality(commands.PiAsk, 0)
  MiniTest.expect.equality(commands.PiAskSelection, 0)
  MiniTest.expect.equality(commands.PiCancel, 0)

  child.cmd("Ai transcript")
  MiniTest.expect.no_equality(last_notification().msg:match("Unknown :Ai subcommand"), nil)
end

local function test_ai_ask_runs_acp_initialize_session_prompt_lifecycle()
  setup_test_env()
  setup_buffer({ "local value = 1" }, "/test/lifecycle.lua")

  local system = start_prompt("explain this buffer")
  local prompt = establish_session(system, "sess-lifecycle")

  MiniTest.expect.equality(prompt.params.prompt[1].type, "text")
  MiniTest.expect.no_equality(prompt.params.prompt[1].text:match("explain this buffer"), nil)
  MiniTest.expect.no_equality(prompt.params.prompt[2].text:match("local value = 1"), nil)

  finish_prompt(system, prompt)
  MiniTest.expect.equality(child.lua_get([[require("ai").is_running()]]), false)
end

local function test_ai_selection_dispatches_selected_context()
  setup_test_env('require("ai").setup({ context = { selection = { surrounding_lines = 1 }, max_bytes = 1000 } })')
  setup_buffer({ "line1", "line2", "line3", "line4", "line5" }, "/test/selection.lua")
  set_visual_marks(2, 3)

  local system = install_system_mock()
  child.lua([[
    vim.ui.input = function(_, callback)
      callback("focus selection")
    end
  ]])
  child.cmd("Ai selection")
  flush()
  wait_for_outbound_count(1)

  local prompt = establish_session(system, "sess-selection")
  MiniTest.expect.no_equality(prompt.params.prompt[1].text:match("focus selection"), nil)
  MiniTest.expect.no_equality(prompt.params.prompt[2].text:match("Selected lines: 2%-3"), nil)
  MiniTest.expect.no_equality(prompt.params.prompt[2].text:match("line2"), nil)
  MiniTest.expect.no_equality(prompt.params.prompt[2].text:match("line3"), nil)
  MiniTest.expect.equality(prompt.params.prompt[2].text:match("line5"), nil)
end

local function test_running_agent_progress_uses_transient_floating_indicator()
  setup_test_env()
  setup_buffer({ "print('status')" }, "/test/status.lua")

  local system = start_prompt("work with status")
  local prompt = establish_session(system, "sess-status")

  agent_notification(system, "session/update", {
    sessionId = "sess-status",
    update = {
      sessionUpdate = "tool_call",
      toolCallId = "tool-1",
      title = "Editing status.lua",
      kind = "edit",
      status = "in_progress",
    },
  })

  local active_indicators = floating_windows_matching("Editing status%.lua")
  MiniTest.expect.equality(#active_indicators, 1)
  MiniTest.expect.equality(active_indicators[1].relative, "win")
  MiniTest.expect.equality(active_indicators[1].anchor, "SE")
  MiniTest.expect.equality(active_indicators[1].focusable, false)
  MiniTest.expect.equality(active_indicators[1].height, 1)

  finish_prompt(system, prompt)
  MiniTest.expect.equality(#floating_windows_matching("Editing status%.lua"), 0)
  MiniTest.expect.equality(child.lua_get([[require("ai").statusline()]]), "AI done")
end

local function test_open_close_toggle_manage_terminal_resume_window()
  setup_terminal_resume_env(false)
  setup_buffer({ "print('terminal')" }, "/test/terminal.lua")

  local system = start_prompt("open terminal")
  local prompt = establish_session(system, "sess-terminal")

  child.cmd("Ai open")
  local open_state = wait_for_terminal_view()
  MiniTest.expect.equality(#open_state.terminals, 1)
  MiniTest.expect.equality(#open_state.terminal_buffers, 1)
  MiniTest.expect.equality(open_state.transcript_windows, 0)
  MiniTest.expect.equality(wait_for_resume_args({ "--resume", "sess-terminal" }), { "--resume", "sess-terminal" })

  child.cmd("Ai close")
  local closed_state = ai_view_state()
  MiniTest.expect.equality(#closed_state.terminals, 0)
  MiniTest.expect.equality(#closed_state.terminal_buffers, 0)

  child.cmd("Ai toggle")
  local toggled_state = wait_for_terminal_view()
  MiniTest.expect.equality(#toggled_state.terminals, 1)
  MiniTest.expect.equality(#toggled_state.terminal_buffers, 1)
  MiniTest.expect.equality(toggled_state.transcript_windows, 0)

  child.cmd("Ai close")
  finish_prompt(system, prompt)
end

local function test_auto_open_defers_terminal_resume_until_acp_session_exists()
  setup_terminal_resume_env(true)
  setup_buffer({ "print('auto open')" }, "/test/auto_open.lua")

  local system = start_prompt("auto open terminal")
  MiniTest.expect.equality(#ai_view_state().terminals, 0)
  MiniTest.expect.equality(#ai_view_state().terminal_buffers, 0)
  MiniTest.expect.equality(resume_args_file_exists(), false)

  local prompt = establish_session(system, "sess-auto-open")
  local open_state = wait_for_terminal_view()
  MiniTest.expect.equality(#open_state.terminals, 1)
  MiniTest.expect.equality(#open_state.terminal_buffers, 1)
  MiniTest.expect.equality(open_state.transcript_windows, 0)
  MiniTest.expect.equality(wait_for_resume_args({ "--resume", "sess-auto-open" }), { "--resume", "sess-auto-open" })

  child.cmd("Ai close")
  local closed_state = ai_view_state()
  MiniTest.expect.equality(#closed_state.terminals, 0)
  MiniTest.expect.equality(#closed_state.terminal_buffers, 0)
  finish_prompt(system, prompt)
end

local function test_fs_bridge_reads_unsaved_buffer_slices_and_updates_loaded_buffer_on_write()
  setup_test_env()
  local file = child.lua_get([[vim.fn.tempname() .. ".lua"]])
  write_file(file, { "disk one", "disk two", "disk three" })
  setup_buffer({ "buffer one", "buffer two", "buffer three" }, file)
  child.lua([[vim.bo.modified = true]])
  file = child.lua_get([[vim.api.nvim_buf_get_name(0)]])

  local system = start_prompt("use fs bridge")
  establish_session(system, "sess-fs")

  agent_request(system, 20, "fs/read_text_file", {
    sessionId = "sess-fs",
    path = file,
    line = 2,
    limit = 1,
  })
  local read_response = wait_for_response(20)
  MiniTest.expect.equality(read_response.result.content, "buffer two")

  agent_request(system, 21, "fs/write_text_file", {
    sessionId = "sess-fs",
    path = file,
    content = "agent one\nagent two\n",
  })
  local write_response = wait_for_response(21)
  MiniTest.expect.equality(write_response.result, vim.NIL)

  local disk = read_file(file)
  local buffer = child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]])
  MiniTest.expect.equality(disk[1], "agent one")
  MiniTest.expect.equality(disk[2], "agent two")
  MiniTest.expect.equality(buffer[1], "agent one")
  MiniTest.expect.equality(buffer[2], "agent two")
  MiniTest.expect.equality(child.lua_get([[vim.bo.modified]]), false)
end

local function test_terminal_bridge_create_output_wait_kill_and_release()
  setup_test_env()
  setup_buffer({ "print('terminal')" }, "/test/terminal.lua")

  local system = start_prompt("run terminal")
  establish_session(system, "sess-terminal")

  agent_request(system, 30, "terminal/create", {
    sessionId = "sess-terminal",
    command = "node",
    args = { "--version" },
    cwd = child.lua_get([[vim.loop.cwd()]]),
    outputByteLimit = 64,
  })
  local create_response = wait_for_response(30)
  local terminal_id = create_response.result.terminalId
  MiniTest.expect.equality(type(terminal_id), "string")
  MiniTest.expect.no_equality(terminal_id, "")

  local terminal_cmd = system.terminal_cmd(1)
  MiniTest.expect.equality(terminal_cmd[1], "node")
  MiniTest.expect.equality(terminal_cmd[2], "--version")

  system.terminal_stdout(1, "v22.0")
  system.terminal_stderr(1, ".0\n")

  agent_request(system, 31, "terminal/output", {
    sessionId = "sess-terminal",
    terminalId = terminal_id,
  })
  local output_response = wait_for_response(31)
  MiniTest.expect.equality(output_response.result.output, "v22.0.0\n")
  MiniTest.expect.equality(output_response.result.truncated, false)
  MiniTest.expect.equality(output_response.result.exitStatus, nil)

  agent_request(system, 32, "terminal/wait_for_exit", {
    sessionId = "sess-terminal",
    terminalId = terminal_id,
  })
  flush()
  MiniTest.expect.equality(find_response(32), vim.NIL)

  agent_request(system, 33, "terminal/kill", {
    sessionId = "sess-terminal",
    terminalId = terminal_id,
  })
  local kill_response = wait_for_response(33)
  MiniTest.expect.equality(kill_response.result, vim.NIL)
  MiniTest.expect.equality(system.terminal_killed(1), 15)

  system.terminal_exit(1, vim.NIL, 15)
  local wait_response = wait_for_response(32)
  MiniTest.expect.equality(wait_response.result.exitCode, vim.NIL)
  MiniTest.expect.equality(wait_response.result.signal, 15)

  agent_request(system, 34, "terminal/release", {
    sessionId = "sess-terminal",
    terminalId = terminal_id,
  })
  local release_response = wait_for_response(34)
  MiniTest.expect.equality(release_response.result, vim.NIL)

  agent_request(system, 35, "terminal/output", {
    sessionId = "sess-terminal",
    terminalId = terminal_id,
  })
  local released_output = wait_for_response(35)
  MiniTest.expect.no_equality(released_output.error.message:match("terminal"), nil)
end

local function test_permission_request_returns_selected_user_option()
  setup_test_env()
  setup_buffer({ "print('permission')" }, "/test/permission.lua")

  local system = start_prompt("ask permission")
  establish_session(system, "sess-permission")

  child.lua([[
    vim.ui.select = function(items, opts, callback)
      _G.__ai_permission_prompt = {
        prompt = opts and opts.prompt or nil,
        first = items[1] and items[1].name or nil,
        second = items[2] and items[2].name or nil,
      }
      callback(items[2])
    end
  ]])

  agent_request(system, 40, "session/request_permission", {
    sessionId = "sess-permission",
    toolCall = {
      toolCallId = "call-permission",
      title = "Edit protected file",
      kind = "edit",
      status = "pending",
    },
    options = {
      { optionId = "allow-once", name = "Allow once", kind = "allow_once" },
      { optionId = "reject-once", name = "Reject", kind = "reject_once" },
    },
  })

  local response = wait_for_response(40)
  MiniTest.expect.equality(response.result.outcome.outcome, "selected")
  MiniTest.expect.equality(response.result.outcome.optionId, "reject-once")

  local prompt = child.lua_get([[_G.__ai_permission_prompt]])
  MiniTest.expect.equality(prompt.first, "Allow once")
  MiniTest.expect.equality(prompt.second, "Reject")
end

local function test_cancel_notifies_agent_and_clears_pending_permission()
  setup_test_env()
  setup_buffer({ "print('cancel')" }, "/test/cancel.lua")

  local system = start_prompt("cancel while waiting")
  establish_session(system, "sess-cancel")

  child.lua([[
    vim.ui.select = function(items, opts, callback)
      _G.__ai_pending_permission_callback = callback
    end
  ]])

  agent_request(system, 50, "session/request_permission", {
    sessionId = "sess-cancel",
    toolCall = { toolCallId = "call-cancel", title = "Dangerous edit" },
    options = {
      { optionId = "allow-once", name = "Allow once", kind = "allow_once" },
      { optionId = "reject-once", name = "Reject", kind = "reject_once" },
    },
  })
  flush()

  child.cmd("Ai cancel")
  flush()

  local messages = outbound_messages()
  local cancel_notification = messages[#messages]
  MiniTest.expect.equality(cancel_notification.method, "session/cancel")
  MiniTest.expect.equality(cancel_notification.params.sessionId, "sess-cancel")

  local permission_response = wait_for_response(50)
  MiniTest.expect.equality(permission_response.result.outcome.outcome, "cancelled")
  MiniTest.expect.equality(child.lua_get([[require("ai").is_running()]]), false)
end

local T = MiniTest.new_set()

T["commands"] = MiniTest.new_set()
T["commands"]["single :Ai dispatcher replaces legacy convenience commands"] = test_ai_dispatcher_replaces_legacy_commands
T["commands"][":Ai selection sends selected buffer context"] = test_ai_selection_dispatches_selected_context

T["acp"] = MiniTest.new_set()
T["acp"][":Ai ask performs initialize/session/prompt lifecycle"] = test_ai_ask_runs_acp_initialize_session_prompt_lifecycle
T["acp"]["running agent progress uses transient floating indicator"] = test_running_agent_progress_uses_transient_floating_indicator
T["acp"]["open close toggle manage terminal resume window"] = test_open_close_toggle_manage_terminal_resume_window
T["acp"]["auto open defers terminal resume until ACP session exists"] = test_auto_open_defers_terminal_resume_until_acp_session_exists
T["acp"]["filesystem bridge reads unsaved buffers and writes loaded buffers"] = test_fs_bridge_reads_unsaved_buffer_slices_and_updates_loaded_buffer_on_write
T["acp"]["terminal bridge create output wait kill release"] = test_terminal_bridge_create_output_wait_kill_and_release
T["acp"]["permission request returns selected option"] = test_permission_request_returns_selected_user_option
T["acp"]["cancel notifies agent and cancels pending permission"] = test_cancel_notifies_agent_and_clears_pending_permission

return T
