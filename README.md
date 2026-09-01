# Neovim IDE with a Generic Agent Harness

A Neovim configuration based on [kickstart.nvim](https://github.com/nvim-lua/kickstart.nvim) with a switchable side-terminal and structured adapter harness for Pi, Cursor Agent, and Codex.

## Features

- Language Server Protocol support for Rust, Go, Python, C/C++, Lua, YAML, JSON, TOML, and Groovy.
- One active agent provider at a time, persisted across Neovim sessions.
- Provider-specific side terminals through ToggleTerm.
- Structured Pi RPC, Cursor `stream-json`, and Codex `exec --json` adapters.
- Pi-compatible highlighted edit suggestions with accept and discard commands.
- Standard kickstart.nvim features such as Telescope, LSP, completion, and Treesitter.

## Prerequisites

Install Git and Neovim, then install each provider CLI you intend to use according to that provider's official instructions. The executable must be on the `PATH` inherited by Neovim.

| Provider | Required executable | Verify installation | Authenticate locally |
|---|---|---|---|
| Pi | `pi` | `pi --version` | Start `pi` and use its `/login` flow, or reuse an existing Pi login. |
| Cursor Agent | `cursor-agent` | `cursor-agent --version` | `cursor-agent login` |
| Codex | `codex` | `codex --version` | `codex login` |

Authentication remains owned by each CLI. Do not put tokens, API keys, or login files in this repository or in the generic harness configuration. An unavailable executable or unauthenticated provider is reported when that provider is started; it does not prevent the other providers from being selected.

## Installation

Clone this repository to `~/.config/nvim` (or clone elsewhere and set `$MYVIMRC` accordingly):

```bash
git clone https://github.com/yourusername/nvim-pi-ide.git ~/.config/nvim
```

Start Neovim and allow the configuration to install its plugins. Pi's first-run setup can reuse the existing login from `~/.pi/agent/auth.json` (recommended) or configure a separate provider override.

## Generic agent commands

| Command | Behavior |
|---|---|
| `:AgentSelect` | Choose Pi, Cursor Agent, or Codex. If an agent is running, the manager stops it before starting the selected provider; otherwise it only persists the selection. |
| `:AgentToggle` | Open or hide the active provider's interactive side terminal. |
| `:AgentStart` | Check the active executable and start its structured adapter. Authentication or compatibility failures are shown without retry loops. |
| `:AgentStop` | Stop the active structured provider process. The provider terminal is managed separately by ToggleTerm. |

`<leader>ta` toggles the active provider terminal. `<leader>tp` remains a Pi-terminal compatibility mapping. The active provider is stored in `~/.local/share/nvim/agent_harness.json` (or `$XDG_DATA_HOME/nvim/agent_harness.json`); this mode-0600 file contains selection and enablement only, never credentials.

## Current provider capabilities

Phase A provides a common lifecycle and terminal surface, but the provider protocols are not yet feature-equivalent.

| Capability | Pi | Cursor Agent | Codex |
|---|---|---|---|
| Interactive terminal | Yes | Yes | Yes |
| Structured prompt/stream | Pi JSONL RPC | `stream-json`; terminal fallback when the installed CLI lacks compatible stream support | `exec --json` |
| Text/tool lifecycle normalization | Pi responses | Text and tool progress | Text, tool, approval, and completion events |
| Harness approval UI/forwarding | No | No | No; approval events can be normalized, but the app-server approval flow is not implemented |
| Harness structured edits | Pi-only compatibility workflow | No | No |
| Resume/session UI | No | No | No |

Codex currently runs prompts with a read-only sandbox and `on-request` approval policy through `exec --json`. Native Codex app-server support is preferred but deferred. Cursor falls back to its interactive terminal only for missing/incompatible structured-stream support or spawn failures, not for authentication or ordinary provider errors.

## Pi compatibility commands

These commands are intentionally Pi-only and select Pi when necessary:

- `:PiStart` / `:PiStop` — start or stop the manager-owned Pi RPC adapter.
- `:PiSuggest` — request a replacement for the visual range or the whole current buffer and highlight it.
- `:PiAccept` — keep all pending Pi suggestions and clear their highlights.
- `:PiDiscard` — restore the original text for all pending Pi suggestions.
- `:PiSetup` — change the Pi authentication/provider profile.

There are no generic `:AgentSuggest`, `:AgentAccept`, or `:AgentDiscard` commands in Phase A.

When **Use existing Pi login** is selected, credentials and the default model remain managed by Pi in `~/.pi/agent/auth.json` and `~/.pi/agent/settings.json`; the Neovim profile does not copy them. Use `/login` and `/model` inside Pi to change that base configuration. A Pi override profile is stored in `~/.local/share/nvim/pi_config.json` (or `$XDG_DATA_HOME/nvim/pi_config.json`) with user-only permissions.

## Validation

Task 7 validation on 2026-09-01 produced the following results:

- `lua tests/agent_harness_smoke.lua` — passed, including simulated missing-executable and unauthenticated-provider paths.
- `luac -p` over `lua/custom/**/*.lua` and `tests/agent_harness_smoke.lua` — passed.
- `pi --version` — `0.84.4`.
- `cursor-agent --version` — `2026.08.31-4057e58`.
- `codex --version` — `codex-cli 0.152.0` (with a non-fatal stale temporary-directory cleanup warning).
- `stylua --check lua/custom tests/agent_harness_smoke.lua` — failed because the existing Lua tree is not formatted to StyLua's defaults; Task 7 made no Lua changes.
- Native `nvim --headless` startup and smoke validation — not run because `nvim` is unavailable in the validation environment. No native Neovim pass is claimed.

Run the native checks when Neovim is available:

```bash
nvim --headless -c 'qa!'
nvim --headless -u NONE -l tests/agent_harness_smoke.lua
```

## Extending

Add custom plugins in `lua/custom/plugins/`; any `.lua` file there will be automatically loaded.

## License

MIT
