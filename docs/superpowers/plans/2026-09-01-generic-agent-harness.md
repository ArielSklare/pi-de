# Generic Neovim Agent Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Pi-only launcher with a switchable Neovim agent harness supporting Pi, Cursor Agent, and Codex, while preserving Pi's current structured suggestion workflow and establishing the path to full provider parity.

**Architecture:** A registry and manager select one active provider. A shared terminal launcher works for every provider. Provider adapters normalize lifecycle and stream events without forcing providers to share a wire protocol: Pi uses JSONL RPC, Codex uses app-server or JSONL exec, and Cursor uses stream-json or terminal mode.

**Tech Stack:** Neovim Lua, `vim.system`/libuv, ToggleTerm, native JSON decoding, provider CLIs, headless Neovim smoke tests, fake JSONL fixtures.

**Spec:** `docs/superpowers/specs/2026-09-01-generic-agent-harness-design.md`

## Global Constraints

- Preserve the existing Pi RPC behavior and `PiSuggest`, `PiAccept`, and `PiDiscard` compatibility commands.
- Never persist or copy API keys, OAuth tokens, or provider credential files into Neovim configuration.
- The terminal fallback must work independently of protocol adapters.
- Missing or unauthenticated providers must be reported without breaking Neovim startup.
- Buffer edits require response validation and a changedtick check before application.
- Provider-specific protocol differences remain inside provider adapters.
- Do not add a chat UI framework or replace ToggleTerm in this work.

---

## File map

### Create

- `lua/custom/agents/config.lua` — persistent harness configuration, defaults, migration, and provider enablement.
- `lua/custom/agents/registry.lua` — static provider metadata, executable checks, capabilities, and command builders.
- `lua/custom/agents/manager.lua` — active-provider lifecycle, switching, prompt dispatch, and normalized events.
- `lua/custom/agents/terminal.lua` — shared ToggleTerm terminal creation and toggling.
- `lua/custom/agents/adapters/pi.lua` — Pi RPC adapter extracted from the current Pi integration.
- `lua/custom/agents/adapters/codex.lua` — Codex app-server/JSONL adapter boundary.
- `lua/custom/agents/adapters/cursor.lua` — Cursor stream-json/terminal adapter boundary.
- `lua/custom/agents/events.lua` — normalized event constructors and validation.
- `tests/agent_harness_smoke.lua` — headless Neovim smoke-test entry point.
- `tests/fixtures/pi-events.jsonl` — Pi protocol fixture.
- `tests/fixtures/cursor-events.jsonl` — Cursor stream-json fixture.
- `tests/fixtures/codex-events.jsonl` — Codex exec JSONL fixture.

### Modify

- `lua/custom/plugins/pi.lua` — retain compatibility commands while delegating Pi behavior to the Pi adapter/manager.
- `lua/custom/plugins/setup.lua` — replace Pi-only setup assumptions with provider-neutral configuration while retaining Pi auth compatibility.
- `lua/custom/plugins/toggleterm.lua` — delegate terminal opening to the shared agent terminal module and preserve `<leader>tp`.
- `lua/custom/plugins/init.lua` — load agent modules in a deterministic order before plugin modules that reference them.
- `README.md` — document agent selection, commands, provider prerequisites, and capability differences.
- `migration_work_log.md` — record implementation and validation results.

---

# Phase A — Approved implementation

### Task 1: Add pure harness configuration and provider registry

**Files:**
- Create: `lua/custom/agents/config.lua`
- Create: `lua/custom/agents/registry.lua`
- Create: `lua/custom/agents/events.lua`
- Test: `tests/agent_harness_smoke.lua`

**Interfaces:**
- `config.load() -> table`
- `config.save(value) -> boolean`
- `config.active() -> string`
- `config.set_active(name) -> boolean`
- `registry.all() -> table<string, ProviderSpec>`
- `registry.get(name) -> ProviderSpec|nil`
- `registry.available(name) -> boolean, string|nil`
- `events.new(kind, payload) -> table`

- [ ] **Step 1: Write failing smoke assertions** for default active agent, provider names, missing executable handling, and event shape.
- [ ] **Step 2: Run the smoke test** with `nvim --headless -u NONE -l tests/agent_harness_smoke.lua` and verify failure before implementation.
- [ ] **Step 3: Implement configuration defaults** with `active_agent = "pi"`, enabled Pi/Cursor/Codex entries, and a mode-0600 JSON file under `vim.fn.stdpath('data')`.
- [ ] **Step 4: Implement provider metadata** with exact commands:

```lua
pi = { command = { 'pi' }, terminal_args = {}, protocol = 'rpc' }
cursor = { command = { 'cursor-agent' }, terminal_args = {}, protocol = 'stream-json' }
codex = { command = { 'codex' }, terminal_args = {}, protocol = 'app-server' }
```

- [ ] **Step 5: Implement executable checks** using `vim.fn.executable` and return an actionable reason without throwing.
- [ ] **Step 6: Implement normalized event constructors** for `started`, `text_delta`, `tool_started`, `tool_output`, `approval_required`, `completed`, and `error`.
- [ ] **Step 7: Re-run the focused smoke test** and confirm PASS.
- [ ] **Step 8: Commit** with `feat: add generic agent registry and configuration`.

### Task 2: Add shared active-agent manager

**Files:**
- Create: `lua/custom/agents/manager.lua`
- Modify: `lua/custom/agents/config.lua`
- Test: `tests/agent_harness_smoke.lua`

**Interfaces:**
- `manager.current() -> string`
- `manager.select(name) -> boolean, string|nil`
- `manager.start() -> boolean, string|nil`
- `manager.stop()`
- `manager.toggle_terminal()`
- `manager.prompt(text, callback)`
- `manager.capabilities() -> table`

- [ ] **Step 1: Add failing assertions** that selecting an unknown provider fails, selecting a known provider persists, and switching stops the old provider before starting the new one.
- [ ] **Step 2: Implement manager state** with one active adapter/process and explicit stopped/starting/running states.
- [ ] **Step 3: Implement selection persistence** through `config.set_active`.
- [ ] **Step 4: Implement lifecycle delegation** so the manager calls adapter methods rather than embedding provider logic.
- [ ] **Step 5: Implement unavailable-provider notifications** that include the executable name and installation/authentication remedy.
- [ ] **Step 6: Re-run the focused smoke test** and confirm PASS.
- [ ] **Step 7: Commit** with `feat: add active agent manager`.

### Task 3: Extract and preserve the Pi adapter

**Files:**
- Create: `lua/custom/agents/adapters/pi.lua`
- Modify: `lua/custom/plugins/pi.lua`
- Modify: `lua/custom/plugins/setup.lua`
- Test: `tests/fixtures/pi-events.jsonl`, `tests/agent_harness_smoke.lua`

**Interfaces:**
- `PiAdapter.new(options) -> Adapter`
- `Adapter:start() -> boolean, string|nil`
- `Adapter:stop()`
- `Adapter:prompt(text, callback)`
- `Adapter:suggest_edits(bufnr, start_line, end_line, callback)`
- `Adapter:accept_suggestions()`
- `Adapter:discard_suggestions()`
- `Adapter:capabilities() -> table`

- [ ] **Step 1: Add fixture-driven assertions** for response correlation, `agent_settled`, invalid JSON, and valid replacement decoding.
- [ ] **Step 2: Move the current Pi process/RPC code** into the adapter without changing the wire format or request IDs.
- [ ] **Step 3: Preserve changedtick protection** before applying suggestions.
- [ ] **Step 4: Preserve suggestion highlighting and restoration** under the adapter.
- [ ] **Step 5: Turn `lua/custom/plugins/pi.lua` into a compatibility facade** exposing the existing commands and delegating to the active Pi adapter.
- [ ] **Step 6: Keep `setup.lua` able to reuse `~/.pi/agent/auth.json`** and keep override credentials out of the harness config.
- [ ] **Step 7: Run the Pi fixture smoke test** and a headless Neovim module-load test.
- [ ] **Step 8: Commit** with `refactor: isolate Pi behind agent adapter`.

### Task 4: Add shared ToggleTerm launcher and agent selection commands

**Files:**
- Create: `lua/custom/agents/terminal.lua`
- Modify: `lua/custom/plugins/toggleterm.lua`
- Modify: `lua/custom/plugins/init.lua`
- Test: `tests/agent_harness_smoke.lua`

**Interfaces:**
- `terminal.open(name) -> boolean, string|nil`
- `terminal.toggle_active()`

- [ ] **Step 1: Add failing assertions** for terminal command construction, display names, and active-provider routing.
- [ ] **Step 2: Implement one ToggleTerm instance per provider** with provider command arrays built without shell interpolation where possible.
- [ ] **Step 3: Add `:AgentSelect`** using `vim.ui.select` and persist the selected provider.
- [ ] **Step 4: Add `:AgentStart`, `:AgentStop`, and `:AgentToggle`**.
- [ ] **Step 5: Preserve `<leader>tp` as an alias** for the Pi terminal and add `<leader>ta` for the active agent.
- [ ] **Step 6: Re-run headless command-registration and terminal-construction smoke tests** and confirm PASS.
- [ ] **Step 7: Commit** with `feat: add switchable agent terminals`.

### Task 5: Add Codex adapter with protocol fallback

**Files:**
- Create: `lua/custom/agents/adapters/codex.lua`
- Create: `tests/fixtures/codex-events.jsonl`
- Modify: `lua/custom/agents/registry.lua`
- Modify: `lua/custom/agents/manager.lua`
- Test: `tests/agent_harness_smoke.lua`

**Interfaces:**
- `CodexAdapter.new(options) -> Adapter`
- `Adapter:start() -> boolean, string|nil`
- `Adapter:stop()`
- `Adapter:prompt(text, callback)`
- `Adapter:capabilities() -> table`
- `Adapter:parse_event(value) -> normalized_event|nil`

- [ ] **Step 1: Add fixture assertions** for `thread.started`, `turn.started`, text/message deltas, tool events, approval requests, completion, and errors.
- [ ] **Step 2: Implement protocol selection**: prefer `codex app-server` when the executable is available; retain `codex exec --json` as the noninteractive fallback.
- [ ] **Step 3: Implement JSONL event parsing** for `codex exec --json` into the common event model.
- [ ] **Step 4: Expose Codex sandbox and approval settings** as explicit non-secret config values, defaulting to a safe read-only or approval-required mode.
- [ ] **Step 5: Detect unauthenticated Codex startup** and show `codex login` without retry loops.
- [ ] **Step 6: Run fixture tests and an unauthenticated local smoke test**; the latter must fail quickly with a clear message rather than hanging.
- [ ] **Step 7: Commit** with `feat: add Codex agent adapter`.

### Task 6: Add Cursor adapter with terminal fallback

**Files:**
- Create: `lua/custom/agents/adapters/cursor.lua`
- Create: `tests/fixtures/cursor-events.jsonl`
- Modify: `lua/custom/agents/registry.lua`
- Modify: `lua/custom/agents/manager.lua`
- Test: `tests/agent_harness_smoke.lua`

**Interfaces:**
- `CursorAdapter.new(options) -> Adapter`
- `Adapter:start() -> boolean, string|nil`
- `Adapter:stop()`
- `Adapter:prompt(text, callback)`
- `Adapter:capabilities() -> table`
- `Adapter:parse_event(value) -> normalized_event|nil`

- [ ] **Step 1: Capture a real authenticated `stream-json` sample** without modifying a repository.
- [ ] **Step 2: Add fixture assertions** for text deltas, tool progress, completion, and authentication/error events.
- [ ] **Step 3: Implement `cursor-agent --print --output-format stream-json`** as the protocol command.
- [ ] **Step 4: Fall back to interactive `cursor-agent`** in ToggleTerm when stream-json is unavailable or incompatible.
- [ ] **Step 5: Detect unauthenticated Cursor startup** and show `cursor-agent login` without retry loops.
- [ ] **Step 6: Run fixture tests and a local CLI availability smoke test**.
- [ ] **Step 7: Commit** with `feat: add Cursor agent adapter`.

### Task 7: Documentation and end-to-end verification for A

**Files:**
- Modify: `README.md`
- Modify: `migration_work_log.md`
- Test: `tests/agent_harness_smoke.lua`

- [ ] **Step 1: Document installation prerequisites** for Pi, Cursor Agent, and Codex without documenting secrets.
- [ ] **Step 2: Document `:AgentSelect`, `:AgentToggle`, `:AgentStart`, and `:AgentStop`.
- [ ] **Step 3: Document Pi-only compatibility commands and current Cursor/Codex capability differences.
- [ ] **Step 4: Run headless Neovim startup** and confirm no startup errors with each CLI present, absent, or unauthenticated.
- [ ] **Step 5: Run provider command probes**: `pi --version`, `cursor-agent --version`, `codex --version`.
- [ ] **Step 6: Run the full smoke test** with `nvim --headless -u NONE -l tests/agent_harness_smoke.lua`.
- [ ] **Step 7: Review `git diff`, record outcomes in `migration_work_log.md`, and commit** with `docs: document generic agent harness`.

---

# Phase B — Full parity completion roadmap

Phase B begins only after Phase A has been verified. Each task below is independently testable and may be implemented as a follow-up plan if provider protocols change.

### Task B1: Formalize the common protocol and capability model

**Files:**
- Modify: `lua/custom/agents/events.lua`
- Modify: `lua/custom/agents/manager.lua`
- Create: `tests/fixtures/normalized-events.lua`

- [ ] Define versioned normalized event fields for provider, session ID, turn ID, timestamp, text, tool metadata, approval metadata, and error metadata.
- [ ] Define capability flags: `prompt`, `stream`, `approvals`, `file_changes`, `suggest_edits`, `accept_discard`, `resume`, and `cancel`.
- [ ] Add contract tests requiring every adapter to declare capabilities and reject unsupported operations explicitly.
- [ ] Add cancellation and process-timeout handling to the manager.

### Task B2: Complete Codex native app-server support

**Files:**
- Modify: `lua/custom/agents/adapters/codex.lua`
- Create: `tests/fixtures/codex-app-server/`

- [ ] Implement app-server initialization and capability negotiation over stdio.
- [ ] Map Codex thread/turn lifecycle to normalized session events.
- [ ] Map command execution, file-change approval, permissions, and user-input requests to Neovim UI prompts.
- [ ] Implement cancellation and graceful shutdown using the app-server protocol.
- [ ] Implement resume by Codex thread ID.
- [ ] Run authenticated tests after `codex login` and verify no credentials enter Neovim state.

### Task B3: Complete Cursor structured stream integration

**Files:**
- Modify: `lua/custom/agents/adapters/cursor.lua`
- Create: `tests/fixtures/cursor-stream/`

- [ ] Capture and version representative Cursor `stream-json` events for assistant text, tool calls, file changes, approvals, errors, and completion.
- [ ] Normalize events into the common model.
- [ ] Implement Cursor session ID/resume support where exposed by the CLI.
- [ ] Implement approval forwarding using Cursor's supported flags or interactive fallback.
- [ ] Mark unavailable operations explicitly when Cursor does not expose an equivalent protocol operation.

### Task B4: Implement provider-neutral approval UI

**Files:**
- Create: `lua/custom/agents/approval.lua`
- Modify: `lua/custom/agents/manager.lua`
- Modify: `lua/custom/agents/adapters/pi.lua`
- Modify: `lua/custom/agents/adapters/codex.lua`
- Modify: `lua/custom/agents/adapters/cursor.lua`

- [ ] Render command/file-change approval details in `vim.ui.select` or a small floating window.
- [ ] Provide approve, deny, approve-once, and cancel actions where the provider supports them.
- [ ] Preserve provider-specific approval semantics instead of translating unsafe options into broader permissions.
- [ ] Test denial, timeout, process exit during approval, and stale approval IDs.

### Task B5: Implement provider-neutral structured edit workflow

**Files:**
- Create: `lua/custom/agents/edits.lua`
- Modify: `lua/custom/agents/manager.lua`
- Modify: `lua/custom/agents/adapters/pi.lua`
- Modify: `lua/custom/agents/adapters/codex.lua`
- Modify: `lua/custom/agents/adapters/cursor.lua`

- [ ] Define a normalized edit representation with URI, start/end positions, replacement text, provider, session ID, and request ID.
- [ ] Convert provider file-change events into buffer-local pending edits.
- [ ] Reject edits for changed buffers using changedtick and file identity checks.
- [ ] Apply multiple non-overlapping edits in reverse position order.
- [ ] Highlight pending edits per buffer and retain exact original text for discard.
- [ ] Add generic commands `:AgentSuggest`, `:AgentAccept`, and `:AgentDiscard`.
- [ ] Keep `:PiSuggest`, `:PiAccept`, and `:PiDiscard` as aliases.
- [ ] Test insertions, deletions, multi-line replacements, multiple edits, overlapping edits, external buffer changes, and invalid provider payloads.

### Task B6: Add sessions, resume, and status UI

**Files:**
- Create: `lua/custom/agents/sessions.lua`
- Modify: `lua/custom/agents/manager.lua`
- Modify: `lua/custom/agents/terminal.lua`
- Modify: `README.md`

- [ ] Represent sessions with provider, session ID, workspace, model, state, and last activity.
- [ ] Add `:AgentSessions` to select resumable sessions.
- [ ] Add `:AgentResume` and provider-specific resume argument construction.
- [ ] Display active provider/session state in the statusline or a small status notification.
- [ ] Test switching providers while sessions remain resumable.

### Task B7: Full authenticated acceptance matrix

**Files:**
- Modify: `README.md`
- Modify: `migration_work_log.md`
- Create: `tests/acceptance/agent-matrix.md`

- [ ] Authenticate Pi, Cursor Agent, and Codex locally without recording credentials.
- [ ] Verify prompt, stream, tool progress, approval, cancellation, session resume, structured edits, accept, and discard for each provider.
- [ ] Record unsupported operations separately from failures.
- [ ] Verify startup behavior with each executable absent.
- [ ] Verify switching while a provider process is running.
- [ ] Verify all temporary processes and pipes are cleaned up after stop, error, and Neovim exit.
- [ ] Update capability documentation to reflect observed behavior and mark B complete only when all required operations pass or are explicitly documented as provider limitations.

## Validation commands

```bash
nvim --headless -u NONE -l tests/agent_harness_smoke.lua
nvim --headless -c 'qa!'
pi --version
cursor-agent --version
codex --version
```

Authenticated commands are intentionally not embedded in the plan because login state belongs to the local user and must not be written into repository files.
