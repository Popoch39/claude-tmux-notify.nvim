# claude-tmux-notify.nvim

Get a Neovim toast when a [Claude Code](https://claude.com/claude-code) session
running in **another tmux window** needs your attention — either because it's
waiting for input (a permission prompt / idle) or because it just finished a
task.

If you run several Claude sessions across tmux windows and work in Neovim, you
no longer have to keep switching windows to check whether one is blocked on you.

```
Claude — 2:api-server
Claude needs your permission to run a command
```

## How it works

```
Claude Code  ──Notification/Stop hook──▶  tmux-notify.sh  ──appends JSON line──▶  ~/.cache/claude-tmux-notify.jsonl
                                                                                          │
Neovim  ◀──toast (snacks/vim.notify)──  claude-tmux-notify.nvim  ◀──fs_poll tail──────────┘
```

- A Claude Code **hook** fires the moment Claude needs input (`Notification`) or
  finishes (`Stop`) — no screen scraping, it's the official signal.
- The hook records the tmux window it ran in and appends one JSON line to a
  cache file.
- This plugin tails that file and raises a toast — **unless** the waiting
  Claude is in the tmux window you're currently looking at (no noise for
  sessions you can already see).

## Requirements

- Neovim ≥ 0.10 (`vim.uv`)
- [tmux](https://github.com/tmux/tmux) (for window labels + focus suppression;
  works without it, but with no location info and no suppression)
- A notifier: [folke/snacks.nvim](https://github.com/folke/snacks.nvim) (used
  automatically if present) or any `vim.notify` backend
  ([nvim-notify](https://github.com/rcarriga/nvim-notify), fidget, …)
- `jq` recommended (the hook falls back to a pure-bash parser without it)

## Install

### lazy.nvim

```lua
{
  "Popoch39/claude-tmux-notify.nvim",
  event = "VeryLazy",
  opts = {},
}
```

### packer.nvim

```lua
use({
  "Popoch39/claude-tmux-notify.nvim",
  config = function()
    require("claude-tmux-notify").setup()
  end,
})
```

## Wire up the Claude Code hook

The plugin handles the Neovim side. The Claude Code side lives in
`~/.claude/settings.json` and points at the bundled `scripts/tmux-notify.sh`.

### Automatic (recommended)

After installing the plugin, run once inside Neovim:

```vim
:ClaudeTmuxNotifyInstallHook
```

This merges the `Notification` and `Stop` hooks into `~/.claude/settings.json`
(backing it up to `settings.json.bak` first) pointing at the bundled script.
**Restart any running Claude Code session** afterward so it picks up the hooks.

### Manual

Find the script path with `:ClaudeTmuxNotifyHookPath`, then add to
`~/.claude/settings.json`:

```jsonc
{
  "hooks": {
    "Notification": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "/abs/path/to/scripts/tmux-notify.sh" }] }
    ],
    "Stop": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "/abs/path/to/scripts/tmux-notify.sh" }] }
    ]
  }
}
```

## Test

```vim
:ClaudeTmuxNotifyTest
```

A toast should appear within `poll_interval` ms (default 1s).

## Configuration

Defaults shown:

```lua
require("claude-tmux-notify").setup({
  -- Path to the JSONL event file. Must match the hook's CLAUDE_TMUX_NOTIFY_FILE
  -- (or its default). nil = $XDG_CACHE_HOME/claude-tmux-notify.jsonl
  cache_file = nil,

  -- How often (ms) to poll the cache file for new events.
  poll_interval = 1000,

  -- The cache file is append-only. At startup, if it exceeds this many bytes,
  -- it is truncated (safe — the backlog is ignored anyway). 0 disables.
  max_cache_size = 1024 * 1024, -- 1 MiB

  -- Skip the toast if the waiting Claude is in the tmux window you're focused on.
  suppress_focused = true,

  -- Where :ClaudeTmuxNotifyInstallHook writes the hook.
  claude_settings = vim.fn.expand("~/.claude/settings.json"),

  -- Per-event toast style. Keys are Claude Code hook event names.
  events = {
    Notification = { level = "warn", icon = "⏳" },
    Stop         = { level = "info", icon = "✅" },
  },

  -- Optional custom notifier: function(message, level, opts) where
  -- opts = { title = "⏳ Claude — 2:api-server" }.
  -- Default: Snacks.notifier if available, else vim.notify.
  notify = nil,
})
```

### Only notify on "waiting for input" (skip task-done)

```lua
opts = { events = { Stop = nil } }
```

## Commands

| Command | Description |
|---|---|
| `:ClaudeTmuxNotifyInstallHook` | Merge the hook into `~/.claude/settings.json` |
| `:ClaudeTmuxNotifyTest` | Fire a test toast |
| `:ClaudeTmuxNotifyHookPath` | Print the bundled hook script path |

## Notes & caveats

- Focus suppression assumes a single attached tmux client (the common case).
- There's up to a `poll_interval` delay (default 1s) — a deliberate trade for
  reliable append-tailing across terminals.
- On startup the plugin seeks to the end of the cache file, so you never get a
  backlog of stale toasts.

## License

MIT
