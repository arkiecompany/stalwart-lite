#!/usr/bin/env luajit
-- Extract and group IMAP transactions from Stalwart log files.

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local json = dofile(script_dir .. "/vendor/json.lua")

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function python_io_error(path, err)
  local message = tostring(err)
  local errors = {
    { "No such file or directory", 2 },
    { "Permission denied", 13 },
    { "Is a directory", 21 },
    { "Not a directory", 20 },
  }
  for _, known in ipairs(errors) do
    if message:sub(-#known[1]) == known[1] then
      return "[Errno " .. known[2] .. "] " .. known[1] .. ": '" .. path .. "'"
    end
  end
  return message
end

local function split_file_lines(value)
  local lines, start = {}, 1
  while start <= #value do
    local newline = value:find("\n", start, true)
    if newline then
      lines[#lines + 1] = value:sub(start, newline - 1)
      start = newline + 1
    else
      lines[#lines + 1] = value:sub(start)
      break
    end
  end
  return lines
end

local function unescape_content(content)
  if content:sub(1, 1) == '"' and content:sub(-1) == '"' then
    content = content:sub(2, -2)
  end
  content = content:gsub("\\r\\n", "\r\n")
  content = content:gsub("\\n", "\n")
  content = content:gsub("\\r", "\r")
  content = content:gsub("\\t", "\t")
  content = content:gsub("\\\"", '"')
  content = content:gsub("\\\\", "\\")
  return content
end

local function parse_line(line)
  local prefix = "(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ)%s+TRACE%s+Raw IMAP%s+"
  for _, direction in ipairs({ "input received", "output sent" }) do
    local pattern = prefix .. direction .. "%s+.-remoteIp%s*=%s*([^,]+),%s*remotePort%s*=%s*(%d+).-contents%s*=%s*(.+)$"
    local timestamp, remote_ip, remote_port, contents = line:match(pattern)
    if timestamp then
      return {
        timestamp = timestamp,
        direction = direction,
        remote_ip = trim(remote_ip),
        remote_port = tonumber(remote_port),
        contents = unescape_content(trim(contents)),
        raw_line = trim(line),
      }
    end
  end
end

local function group_entries(entries)
  local connections, order = {}, {}
  for sequence, entry in ipairs(entries) do
    local key = entry.remote_ip .. ":" .. string.format("%.0f", entry.remote_port)
    if not connections[key] then
      connections[key] = {}
      order[#order + 1] = key
    end
    entry.sequence = sequence
    connections[key][#connections[key] + 1] = entry
  end

  for _, key in ipairs(order) do
    table.sort(connections[key], function(left, right)
      if left.timestamp == right.timestamp then return left.sequence < right.sequence end
      return left.timestamp < right.timestamp
    end)
  end
  return connections, order
end

local function trim_line_end(content)
  if content:sub(-4) == "\\r\\n" or content:sub(-2) == "\r\n" then
    while #content > 0 do
      local last = content:sub(-1)
      if last == "\\" or last == "r" or last == "n" or last == "\r" or last == "\n" then
        content = content:sub(1, -2)
      else
        break
      end
    end
  end
  return content
end

local function write_text(connections, order, output_path)
  local file, err = io.open(output_path, "wb")
  if not file then return nil, err end
  local function write(value)
    local ok, write_err = file:write(value)
    if not ok then error(write_err) end
  end
  local written, write_err = pcall(function()
    write("IMAP Transaction Log Analysis\n" .. string.rep("=", 50) .. "\n\n")
    for _, key in ipairs(order) do
      local entries = connections[key]
      write("Connection: " .. key .. "\n" .. string.rep("-", 30) .. "\n")
      write("Total messages: " .. #entries .. "\n")
      write("Duration: " .. entries[1].timestamp .. " to " .. entries[#entries].timestamp .. "\n\n")
      for _, entry in ipairs(entries) do
        local symbol = entry.direction:find("input received", 1, true) and "C: " or "S: "
        write("[" .. entry.timestamp .. "] " .. symbol .. trim_line_end(entry.contents) .. "\n")
      end
      write("\n" .. string.rep("=", 50) .. "\n\n")
    end
  end)
  local closed, close_err = file:close()
  if not written then return nil, write_err end
  if not closed then return nil, close_err end
  return true
end

local function json_string(value)
  return json.encode(value)
end

local function encode_pretty_json(connections, order)
  if #order == 0 then return "{}" end
  local lines = { "{" }
  local fields = { "timestamp", "direction", "remote_ip", "remote_port", "contents", "raw_line" }
  for connection_index, key in ipairs(order) do
    lines[#lines + 1] = "  " .. json_string(key) .. ": ["
    local entries = connections[key]
    for entry_index, entry in ipairs(entries) do
      lines[#lines + 1] = "    {"
      for field_index, name in ipairs(fields) do
        local value = name == "remote_port" and string.format("%.0f", entry[name]) or json_string(entry[name])
        local comma = field_index < #fields and "," or ""
        lines[#lines + 1] = "      " .. json_string(name) .. ": " .. value .. comma
      end
      lines[#lines + 1] = "    }" .. (entry_index < #entries and "," or "")
    end
    lines[#lines + 1] = "  ]" .. (connection_index < #order and "," or "")
  end
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n")
end

local function parse_args()
  local input_path, output_path, want_json, verbose = nil, "imap_transactions.txt", false, false
  local index, positional_only = 1, false
  while index <= #arg do
    local option = arg[index]
    if positional_only then
      if input_path then return nil, "unrecognized arguments: " .. option end
      input_path = option
    elseif option == "--" then
      positional_only = true
    elseif option == "-h" or option == "--help" then
      io.write("usage: imap-log-parser.lua [-h] [-o OUTPUT] [-j] [-v] input_file\n\n")
      io.write("Parse IMAP log files and group transactions by connection\n\n")
      io.write("positional arguments:\n  input_file\n\noptions:\n  -h, --help\n  -o OUTPUT, --output OUTPUT\n  -j, --json\n  -v, --verbose\n")
      return false
    elseif option == "-j" or option == "--json" then
      want_json = true
    elseif option == "-v" or option == "--verbose" then
      verbose = true
    elseif option == "-o" or option == "--output" then
      index = index + 1
      if not arg[index] then return nil, "argument " .. option .. ": expected one argument" end
      output_path = arg[index]
    elseif option:match("^%-%-output=") then
      output_path = option:sub(#"--output=" + 1)
    elseif option:sub(1, 1) == "-" then
      return nil, "unrecognized arguments: " .. option
    elseif input_path then
      return nil, "unrecognized arguments: " .. option
    else
      input_path = option
    end
    index = index + 1
  end
  if not input_path then return nil, "the following arguments are required: input_file" end
  return { input_path = input_path, output_path = output_path, want_json = want_json, verbose = verbose }
end

local function main()
  local options, parse_error = parse_args()
  if options == false then return 0 end
  if not options then
    io.stderr:write("usage: imap-log-parser.lua [-h] [-o OUTPUT] [-j] [-v] input_file\n")
    io.stderr:write("imap-log-parser.lua: error: " .. parse_error .. "\n")
    return 2
  end

  if options.verbose then print("Reading log file: " .. options.input_path) end
  local file, open_err = io.open(options.input_path, "rb")
  if not file then
    if tostring(open_err):find("No such file", 1, true) or tostring(open_err):find("not found", 1, true) then
      print("Error: File '" .. options.input_path .. "' not found")
    else
      print("Error reading file: " .. tostring(open_err))
    end
    return 1
  end
  local contents, read_err = file:read("*a")
  file:close()
  if not contents then
    print("Error reading file: " .. tostring(read_err))
    return 1
  end
  contents = contents:gsub("\r\n", "\n"):gsub("\r", "\n")

  local entries, raw_count = {}, 0
  for line_number, line in ipairs(split_file_lines(contents)) do
    if line:find("Raw IMAP", 1, true) then
      raw_count = raw_count + 1
      local entry = parse_line(line)
      if entry then
        entries[#entries + 1] = entry
      elseif options.verbose then
        print("Warning: Could not parse line " .. line_number .. ": " .. trim(line))
      end
    end
  end

  if options.verbose then
    print("Found " .. raw_count .. " Raw IMAP lines")
    print("Successfully parsed " .. #entries .. " entries")
  end
  local connections, order = group_entries(entries)
  if options.verbose then
    print("Found " .. #order .. " unique connections:")
    for _, key in ipairs(order) do print("  " .. key .. ": " .. #connections[key] .. " messages") end
  end

  local ok, write_err = write_text(connections, order, options.output_path)
  if not ok then
    print("Error writing output: " .. python_io_error(options.output_path, write_err))
    return 1
  end
  print("IMAP transactions written to: " .. options.output_path)

  if options.want_json then
    local json_path = options.output_path:gsub("%.[^%.]*$", "") .. ".json"
    local json_file, json_open_err = io.open(json_path, "wb")
    if not json_file then
      print("Error writing output: " .. python_io_error(json_path, json_open_err))
      return 1
    end
    local json_ok, json_write_err = json_file:write(encode_pretty_json(connections, order))
    local close_ok, close_err = json_file:close()
    if not json_ok or close_ok == nil then
      print("Error writing output: " .. tostring(json_write_err or close_err))
      return 1
    end
    print("Raw data written to: " .. json_path)
  end
  return 0
end

os.exit(main())
