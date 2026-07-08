local LineBuffer = {}
LineBuffer.__index = LineBuffer

function LineBuffer.new()
  return setmetatable({ tail = "" }, LineBuffer)
end

function LineBuffer:reset()
  self.tail = ""
end

function LineBuffer:push(chunk, on_line)
  if not chunk or chunk == "" then
    return
  end
  self.tail = self.tail .. chunk
  while true do
    local newline = self.tail:find("\n", 1, true)
    if not newline then
      break
    end
    local line = self.tail:sub(1, newline - 1)
    self.tail = self.tail:sub(newline + 1)
    if line ~= "" then
      on_line(line)
    end
  end
end

function LineBuffer:flush(on_line)
  if self.tail ~= "" then
    on_line(self.tail)
    self.tail = ""
  end
end

return LineBuffer
