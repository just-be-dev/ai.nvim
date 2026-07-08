local M = {}

M.errors = {
  PARSE_ERROR = -32700,
  INVALID_REQUEST = -32600,
  METHOD_NOT_FOUND = -32601,
  INVALID_PARAMS = -32602,
  INTERNAL = -32603,
}

function M.request(id, method, params)
  return {
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or {},
  }
end

function M.notification(method, params)
  return {
    jsonrpc = "2.0",
    method = method,
    params = params or {},
  }
end

function M.result(id, result)
  return {
    jsonrpc = "2.0",
    id = id,
    result = result == nil and vim.NIL or result,
  }
end

function M.error(id, message, code, data)
  return {
    jsonrpc = "2.0",
    id = id,
    error = {
      code = code or M.errors.INTERNAL,
      message = tostring(message or "internal error"),
      data = data,
    },
  }
end

function M.decode(line)
  local ok, decoded = pcall(vim.json.decode, line)
  if not ok or type(decoded) ~= "table" then
    return nil, decoded
  end
  return decoded, nil
end

return M
