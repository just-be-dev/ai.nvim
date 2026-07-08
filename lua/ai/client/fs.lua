local M = {}

local function normalize(path)
  return vim.fn.fnamemodify(path, ":p")
end

local function find_loaded_buffer(path)
  local normalized = normalize(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and normalize(name) == normalized then
        return bufnr
      end
    end
  end
  return nil
end

local function slice_lines(lines, line, limit)
  local start_idx = math.max(1, tonumber(line) or 1)
  local end_idx = #lines
  if limit then
    end_idx = math.min(end_idx, start_idx + tonumber(limit) - 1)
  end
  local out = {}
  for i = start_idx, end_idx do
    out[#out + 1] = lines[i]
  end
  return out
end

function M.read_text_file(params)
  if type(params) ~= "table" or type(params.path) ~= "string" then
    return nil, "invalid params"
  end

  local path = normalize(params.path)
  local bufnr = find_loaded_buffer(path)
  local lines
  if bufnr then
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  elseif vim.fn.filereadable(path) == 1 then
    lines = vim.fn.readfile(path)
  else
    return { content = "" }
  end

  lines = slice_lines(lines, params.line, params.limit)
  return { content = table.concat(lines, "\n") }
end

function M.write_text_file(params)
  if type(params) ~= "table" or type(params.path) ~= "string" or type(params.content) ~= "string" then
    return nil, "invalid params"
  end

  local path = normalize(params.path)
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    local ok_mkdir, mkdir_err = pcall(vim.fn.mkdir, dir, "p")
    if not ok_mkdir then
      return nil, mkdir_err
    end
  end

  local lines = vim.split(params.content, "\n", { plain = true })
  if params.content:sub(-1) == "\n" then
    table.remove(lines, #lines)
  end

  local ok_write, write_err = pcall(vim.fn.writefile, lines, path)
  if not ok_write then
    return nil, write_err
  end

  local bufnr = find_loaded_buffer(path)
  if bufnr then
    local view = nil
    local current = vim.api.nvim_get_current_buf()
    if current == bufnr then
      view = vim.fn.winsaveview()
    end
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modified = false
    if view then
      pcall(vim.fn.winrestview, view)
    end
  end

  return vim.NIL
end

M._find_loaded_buffer = find_loaded_buffer

return M
