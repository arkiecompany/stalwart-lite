#!/usr/bin/env luajit
-- Remove Enterprise-licensed Rust code from the Stalwart codebase.
-- Usage: luajit ossify.lua [--dry-run] [--verbose] <stalwart_repository>/crates

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split_lines(value)
  value = value:gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines, start = {}, 1
  while true do
    local newline = value:find("\n", start, true)
    if not newline then
      lines[#lines + 1] = value:sub(start)
      break
    end
    lines[#lines + 1] = value:sub(start, newline - 1)
    start = newline + 1
  end
  return lines
end

local function first_comment_block(content)
  local lines = split_lines(trim(content))
  local first = trim(lines[1] or "")
  local comments = {}

  if first:sub(1, 2) == "/*" then
    for _, line in ipairs(lines) do
      comments[#comments + 1] = line
      if line:find("*/", 1, true) then break end
    end
    return table.concat(comments, "\n")
  end

  if first:sub(1, 2) == "//" then
    for _, line in ipairs(lines) do
      local stripped = trim(line)
      if stripped:sub(1, 2) == "//" or stripped == "" then
        comments[#comments + 1] = line
      else
        break
      end
    end
    return table.concat(comments, "\n")
  end
end

local function read_file(path)
  local file, err = io.open(path, "rb")
  if not file then return nil, err end
  local content, read_err = file:read("*a")
  file:close()
  if not content then return nil, read_err end
  content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
  return content
end

local function remove_proprietary_snippets(content)
  local lines, output = split_lines(content), {}
  local removed, index = 0, 1
  while index <= #lines do
    local line = lines[index]
    if line:find("// SPDX-SnippetBegin", 1, true) then
      local finish, snippet = index, {}
      while finish <= #lines do
        snippet[#snippet + 1] = lines[finish]
        if lines[finish]:find("// SPDX-SnippetEnd", 1, true) then break end
        finish = finish + 1
      end
      if table.concat(snippet, "\n"):find("SPDX-License-Identifier: LicenseRef-SEL", 1, true) then
        removed = removed + 1
        index = finish + 1
      else
        output[#output + 1] = line
        index = index + 1
      end
    else
      output[#output + 1] = line
      index = index + 1
    end
  end
  return table.concat(output, "\n"), removed
end

local function should_remove_file(path)
  local content, err = read_file(path)
  if not content then
    print("Error reading file " .. path .. ": " .. tostring(err))
    return false
  end
  local comment = first_comment_block(content)
  return comment ~= nil and comment:find("SPDX-License-Identifier: LicenseRef-SEL", 1, true) ~= nil
end

local function process_file(path, dry_run)
  if should_remove_file(path) then
    if not dry_run then
      local ok, err = os.remove(path)
      if not ok then return { error = tostring(err) } end
    end
    return { action = "file_removed" }
  end

  local content, err = read_file(path)
  if not content then return { error = tostring(err) } end
  local modified, snippets = remove_proprietary_snippets(content)
  if snippets == 0 then return { action = "none" } end

  if not dry_run then
    local file, open_err = io.open(path, "wb")
    if not file then return { error = tostring(open_err) } end
    local ok, write_err = file:write(modified)
    file:close()
    if not ok then return { error = tostring(write_err) } end
  end
  return { action = "snippets_removed", snippets_removed = snippets }
end

local function shell_quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function find_rust_files(directory)
  local find_path = directory
  local strip_dot_prefix = find_path:sub(1, 1) == "-"
  if strip_dot_prefix then find_path = "./" .. find_path end
  local command = "find " .. shell_quote(find_path) .. " -type f -name '*.rs' -print0 2>/dev/null"
  local pipe = io.popen(command, "r")
  if not pipe then return {} end
  local output = pipe:read("*a") or ""
  pipe:close()

  local files = {}
  for path in output:gmatch("([^%z]+)") do
    if strip_dot_prefix then path = path:gsub("^%./", "") end
    files[#files + 1] = path
  end
  return files
end

local function usage(stream)
  stream:write("usage: ossify.lua [-h] [--dry-run] [--verbose] directory\n")
end

local function main()
  local directory, dry_run, verbose, positional_only = nil, false, false, false
  local index = 1
  while index <= #arg do
    local option = arg[index]
    if positional_only then
      if directory then
        usage(io.stderr)
        io.stderr:write("ossify.lua: error: unrecognized arguments: " .. option .. "\n")
        return 2
      end
      directory = option
    elseif option == "--" then
      positional_only = true
    elseif option == "-h" or option == "--help" then
      usage(io.stdout)
      io.stdout:write("\nRemove Enterprise licensed code from Stalwart codebase\n\n")
      io.stdout:write("positional arguments:\n  directory   Directory containing Stalwart code to process\n\n")
      io.stdout:write("options:\n  -h, --help  show this help message and exit\n  --dry-run   Show what would be done without making changes\n  --verbose   Show detailed output for each file\n")
      return 0
    elseif option == "--dry-run" then
      dry_run = true
    elseif option == "--verbose" then
      verbose = true
    elseif option:sub(1, 1) == "-" then
      usage(io.stderr)
      io.stderr:write("ossify.lua: error: unrecognized arguments: " .. option .. "\n")
      return 2
    elseif directory then
      usage(io.stderr)
      io.stderr:write("ossify.lua: error: unrecognized arguments: " .. option .. "\n")
      return 2
    else
      directory = option
    end
    index = index + 1
  end

  if not directory then
    usage(io.stderr)
    io.stderr:write("ossify.lua: error: the following arguments are required: directory\n")
    return 2
  end

  local check = io.popen("test -d " .. shell_quote(directory) .. " && printf yes", "r")
  local valid = check and check:read("*a") == "yes"
  if check then check:close() end
  if not valid then
    print("Error: " .. directory .. " is not a valid directory")
    return 1
  end

  print("Processing Rust files in: " .. directory)
  if dry_run then print("DRY RUN MODE - No changes will be made") end
  print()

  local files = find_rust_files(directory)
  if #files == 0 then
    print("No .rs files found in the specified directory")
    return 0
  end
  print("Found " .. #files .. " Rust files\n")

  local files_removed, files_with_snippets, snippets_removed = 0, 0, 0
  local errors = {}
  for _, path in ipairs(files) do
    local result = process_file(path, dry_run)
    if result.error then
      errors[#errors + 1] = path .. ": " .. result.error
    elseif result.action == "file_removed" then
      files_removed = files_removed + 1
      if verbose or dry_run then
        print((dry_run and "Would remove" or "Removed") .. " file: " .. path)
      end
    elseif result.action == "snippets_removed" then
      files_with_snippets = files_with_snippets + 1
      snippets_removed = snippets_removed + result.snippets_removed
      if verbose or dry_run then
        print((dry_run and "Would remove" or "Removed") .. " " .. result.snippets_removed .. " snippet(s) from: " .. path)
      end
    end
  end

  print("\nSummary:")
  local action = dry_run and "would be" or "were"
  print("- " .. files_removed .. " files " .. action .. " completely removed")
  print("- " .. snippets_removed .. " proprietary snippets " .. action .. " removed from " .. files_with_snippets .. " files")
  if #errors > 0 then
    print("- " .. #errors .. " errors occurred:")
    for _, message in ipairs(errors) do print("  " .. message) end
  end
  if dry_run then print("\nRun without --dry-run to apply changes") end
  return 0
end

os.exit(main())
