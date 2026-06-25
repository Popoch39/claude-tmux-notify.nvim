-- claude-tmux-notify.nvim
-- Toasts in Neovim when a Claude Code instance in another tmux window needs
-- input (Notification) or finishes a task (Stop). Events are delivered by a
-- Claude Code hook (scripts/tmux-notify.sh) that appends JSON lines to a cache
-- file, which this module tails.

local M = {}

local uv = vim.uv or vim.loop

---@class ClaudeTmuxNotifyEventOpts
---@field level "trace"|"debug"|"info"|"warn"|"error"
---@field icon string

---@class ClaudeTmuxNotifyConfig
---@field cache_file string?            Path to the JSONL event file (defaults to $XDG_CACHE_HOME/claude-tmux-notify.jsonl)
---@field poll_interval integer         fs_poll interval in ms (default 1000)
---@field suppress_focused boolean      Skip toast if the event's tmux window is currently focused (default true)
---@field claude_settings string        Path to Claude Code settings.json (for :ClaudeTmuxNotifyInstallHook)
---@field events table<string, ClaudeTmuxNotifyEventOpts>
---@field notify fun(message:string, level:string, opts:{title:string})?  Custom notifier

local defaults = {
  cache_file = nil,
  poll_interval = 1000,
  suppress_focused = true,
  claude_settings = vim.fn.expand("~/.claude/settings.json"),
  events = {
    Notification = { level = "warn", icon = "⏳" },
    Stop = { level = "info", icon = "✅" },
  },
  notify = nil,
}

---@type ClaudeTmuxNotifyConfig
M.config = vim.deepcopy(defaults)

local state = { handle = nil, offset = 0 }

-- Absolute path to this plugin's root (…/lua/claude-tmux-notify/init.lua -> root).
local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

--- Absolute path to the bundled Claude Code hook script.
function M.hook_script()
  return plugin_root() .. "/scripts/tmux-notify.sh"
end

local function resolve_cache_file()
  if M.config.cache_file and M.config.cache_file ~= "" then
    return vim.fn.expand(M.config.cache_file)
  end
  local base = vim.env.XDG_CACHE_HOME
  if not base or base == "" then
    base = (vim.env.HOME or vim.fn.expand("~")) .. "/.cache"
  end
  return base .. "/claude-tmux-notify.jsonl"
end

-- True when the given tmux window is the active (focused) one -> suppress.
local function window_is_focused(window_id)
  if not (M.config.suppress_focused and window_id and window_id ~= "" and vim.env.TMUX) then
    return false
  end
  local out = vim.fn.system({ "tmux", "display-message", "-p", "-t", window_id, "-F", "#{window_active}" })
  if vim.v.shell_error ~= 0 then
    return false
  end
  return vim.trim(out) == "1"
end

local function default_notify(message, level, opts)
  local Snacks = rawget(_G, "Snacks")
  if Snacks and Snacks.notifier then
    Snacks.notifier.notify(message, level, opts)
    return
  end
  local lvl = vim.log.levels[level:upper()] or vim.log.levels.INFO
  vim.notify(message, lvl, opts)
end

local function emit(event)
  if window_is_focused(event.window_id) then
    return
  end

  local label = event.label
  if not label or label == "" then
    label = "Claude"
  end

  local spec = M.config.events[event.event] or M.config.events.Notification or { level = "info", icon = "🔔" }
  local message = event.message or "Claude is waiting for your input"
  local title = spec.icon .. " Claude — " .. label

  local fn = M.config.notify or default_notify
  fn(message, spec.level, { title = title })
end

local function handle_lines(chunk)
  for line in (chunk .. "\n"):gmatch("(.-)\n") do
    line = vim.trim(line)
    if line ~= "" then
      local ok, decoded = pcall(vim.json.decode, line)
      if ok and type(decoded) == "table" and M.config.events[decoded.event] ~= nil then
        pcall(emit, decoded)
      elseif ok and type(decoded) == "table" then
        -- Unknown event type still toasts via the Notification fallback spec.
        pcall(emit, decoded)
      end
    end
  end
end

local function read_new(path)
  local stat = uv.fs_stat(path)
  if not stat then
    return
  end
  if stat.size < state.offset then -- truncated/rotated
    state.offset = 0
  end
  if stat.size <= state.offset then
    return
  end
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return
  end
  local data = uv.fs_read(fd, stat.size - state.offset, state.offset)
  uv.fs_close(fd)
  if data and #data > 0 then
    state.offset = state.offset + #data
    vim.schedule(function()
      handle_lines(data)
    end)
  end
end

--- Start tailing the cache file. Idempotent.
function M.start()
  if state.handle then
    return
  end
  local path = resolve_cache_file()
  pcall(vim.fn.writefile, {}, path, "a") -- ensure file exists (no-op append)

  -- Begin at EOF: ignore any backlog written while nvim was closed.
  local st = uv.fs_stat(path)
  state.offset = st and st.size or 0

  local poll = uv.new_fs_poll()
  state.handle = poll
  poll:start(path, M.config.poll_interval, function(err)
    if not err then
      read_new(path)
    end
  end)
end

--- Stop tailing.
function M.stop()
  if state.handle then
    state.handle:stop()
    state.handle = nil
  end
end

-- ── settings.json hook installation ─────────────────────────────────────────

-- Minimal 2-space JSON pretty-printer (no external deps).
local function encode_pretty(value, indent)
  indent = indent or ""
  local nl = "\n"
  local step = "  "
  local t = type(value)
  if t == "table" then
    if vim.tbl_isempty(value) then
      return "{}"
    end
    local is_list = vim.islist and vim.islist(value) or vim.tbl_islist(value)
    local parts = {}
    local inner = indent .. step
    if is_list then
      for _, v in ipairs(value) do
        parts[#parts + 1] = inner .. encode_pretty(v, inner)
      end
      return "[" .. nl .. table.concat(parts, "," .. nl) .. nl .. indent .. "]"
    else
      local keys = vim.tbl_keys(value)
      table.sort(keys)
      for _, k in ipairs(keys) do
        parts[#parts + 1] = inner .. vim.json.encode(tostring(k)) .. ": " .. encode_pretty(value[k], inner)
      end
      return "{" .. nl .. table.concat(parts, "," .. nl) .. nl .. indent .. "}"
    end
  end
  return vim.json.encode(value)
end

local function has_hook(list, command)
  for _, matcher in ipairs(list or {}) do
    for _, h in ipairs(matcher.hooks or {}) do
      if h.command == command then
        return true
      end
    end
  end
  return false
end

--- Install the Claude Code hook into settings.json (Notification + Stop).
function M.install_hook()
  local script = M.hook_script()
  pcall(function()
    uv.fs_chmod(script, 493) -- 0755
  end)

  local settings_path = vim.fn.expand(M.config.claude_settings)
  local data = {}
  if vim.fn.filereadable(settings_path) == 1 then
    local content = table.concat(vim.fn.readfile(settings_path), "\n")
    local ok, decoded = pcall(vim.json.decode, content)
    if ok and type(decoded) == "table" then
      data = decoded
    else
      vim.notify("[claude-tmux-notify] could not parse " .. settings_path .. " — aborting", vim.log.levels.ERROR)
      return
    end
    -- backup
    vim.fn.writefile(vim.fn.readfile(settings_path), settings_path .. ".bak")
  else
    vim.fn.mkdir(vim.fn.fnamemodify(settings_path, ":h"), "p")
  end

  data.hooks = data.hooks or {}
  local entry = { matcher = "", hooks = { { type = "command", command = script } } }
  local added = {}
  for _, ev in ipairs({ "Notification", "Stop" }) do
    data.hooks[ev] = data.hooks[ev] or {}
    if not has_hook(data.hooks[ev], script) then
      table.insert(data.hooks[ev], vim.deepcopy(entry))
      added[#added + 1] = ev
    end
  end

  vim.fn.writefile(vim.split(encode_pretty(data, ""), "\n"), settings_path)

  if #added > 0 then
    vim.notify(
      "[claude-tmux-notify] hook installed for: " .. table.concat(added, ", ") .. "\nRestart Claude Code to load it.",
      vim.log.levels.INFO
    )
  else
    vim.notify("[claude-tmux-notify] hook already installed.", vim.log.levels.INFO)
  end
end

--- Fire a fake event end-to-end (writes to the cache file).
function M.test()
  local path = resolve_cache_file()
  local line = vim.json.encode({
    event = "Notification",
    window_id = "",
    label = "test:demo",
    session = "test",
    message = "claude-tmux-notify is working 🎉",
  })
  vim.fn.writefile({ line }, path, "a")
  vim.notify("[claude-tmux-notify] test event written; toast should appear within "
    .. M.config.poll_interval .. "ms", vim.log.levels.INFO)
end

---@param opts ClaudeTmuxNotifyConfig?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  M.start()

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("ClaudeTmuxNotify", { clear = true }),
    callback = M.stop,
  })

  vim.api.nvim_create_user_command("ClaudeTmuxNotifyInstallHook", M.install_hook, {
    desc = "Install the Claude Code hook into settings.json",
  })
  vim.api.nvim_create_user_command("ClaudeTmuxNotifyTest", M.test, {
    desc = "Fire a test claude-tmux-notify toast",
  })
  vim.api.nvim_create_user_command("ClaudeTmuxNotifyHookPath", function()
    vim.notify(M.hook_script(), vim.log.levels.INFO)
  end, { desc = "Print the bundled hook script path" })
end

return M
