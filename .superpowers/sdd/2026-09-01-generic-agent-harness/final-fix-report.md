# Final Review Fix Wave — Implementation Report

## Scope

Addressed every Critical and Important finding in `final-review.md`, plus both feasible Minor findings.

## Implemented fixes

### Credential ownership and isolation

- `lua/custom/plugins/setup.lua` now sanitizes every `pi_config.json` write to non-secret `auth_source`, `provider`, and `model` fields.
- Loading a legacy profile removes its `api_key` field and rewrites the mode-0600 file without the key.
- `:PiSetup` no longer asks for or stores an API key. Authentication remains owned by Pi (`pi` login/auth storage).
- Removed the `uv.os_setenv()` credential path. Pi provider/model overrides only add non-secret command arguments.
- Pi, Cursor, and Codex structured child spawns do not receive a harness-created credential environment.

### Asynchronous provider lifecycle

- Pi, Cursor, and Codex adapters now implement `stop(callback)` and complete the callback only after process exit and relevant pipe cleanup.
- Manager shutdown now has an explicit `stopping` state and waiter queue.
- Provider switching retains the old active provider until shutdown completion, then persists and starts the replacement.
- Existing synchronous return behavior is retained where shutdown completes immediately; an asynchronous switch returns accepted status and may optionally report final status through a callback.
- Pi reports persistent RPC process exits to the manager. Manager also checks adapter liveness before treating `AgentStart` as an already-running no-op, allowing recovery after unexpected exits.

### Diagnostics and notification ownership

- Codex distinguishes authentication output from status-command failures and preserves timeout/system/unsupported diagnostics.
- The manager owns provider-selection failure notifications; `:AgentSelect` no longer emits a duplicate notification.

### Documentation

- README now documents Pi-owned authentication, legacy key removal, non-secret overrides, credential isolation, asynchronous stop/switch semantics, and crash recovery.

## Regression coverage

Added coverage for:

- migration/removal of a legacy `pi_config.json` `api_key`;
- rejection of newly supplied API keys by `save_config()`;
- no global environment mutation and no Pi-specific child environment passed to Cursor/Codex;
- Pi stop waiting for process exit and pipe cleanup;
- Cursor/Codex stop waiting for delayed exit plus stdout/stderr EOF cleanup;
- manager delayed-exit switching order;
- manager `AgentStart` recovery after an unexpected adapter exit;
- non-authentication Codex status diagnostics;
- no duplicate `AgentSelect` notification.

## Validation

Passed:

- `lua tests/agent_harness_smoke.lua`
- `luac -p` for every `lua/custom/**/*.lua` file
- `luac -p tests/agent_harness_smoke.lua`
- `git diff --check`

Environment limitations / known baseline:

- Native Neovim checks were not run because `nvim` is unavailable on `PATH`.
- `stylua --check` remains non-zero because the existing Lua tree and smoke test do not conform to StyLua defaults; this is the same repository-wide formatting limitation documented by the original plan, not a syntax failure.

## Final re-review fix — coalesced pending transition

Addressed the new Important lifecycle race from `final-rereview.md`.

- The manager now owns one pending provider transition while asynchronous shutdown is in progress.
- A newer `select()` replaces the pending target instead of adding another post-stop transition waiter; a superseded callback receives an explicit failure.
- Shutdown completion persists and starts only the latest requested provider, preserving the no-overlap guarantee.
- Added a delayed-shutdown regression that selects Cursor and then Codex before Pi exits, verifies Pi is stopped once, verifies no replacement starts early, and verifies only Codex starts after cleanup.

Validation passed:

- `lua tests/agent_harness_smoke.lua`
- `luac -p` for every `lua/custom/**/*.lua` file
- `luac -p tests/agent_harness_smoke.lua`
- `git diff --check`

Native Neovim validation remains unavailable because `nvim` is not on `PATH`.
