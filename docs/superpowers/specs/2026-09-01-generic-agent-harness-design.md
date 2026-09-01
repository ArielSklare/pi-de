# Generic Neovim Agent Harness Design

## Status

Approved direction: implement **A**, with a documented path to complete **B**.

## Goal

Turn the current Pi-specific Neovim integration into a generic agent harness that can switch between Pi, Cursor Agent, and Codex while preserving Pi's existing structured suggestion workflow.

## Scope A: First implementation

The first implementation will provide:

- A registry of configured agents.
- A persisted active-agent selection.
- One shared ToggleTerm entry point for the active agent.
- Terminal-mode support for Pi, Cursor Agent, and Codex.
- A common internal agent lifecycle interface.
- A native Pi adapter using the existing JSONL RPC protocol.
- A native Codex adapter using `codex app-server` where practical, with `codex exec --json` as a fallback.
- Cursor Agent support through its CLI terminal and `stream-json` output where practical.
- Existing Pi commands preserved as compatibility aliases.
- No credential copying into Neovim configuration.

The first implementation will not require complete structured-edit parity for Cursor Agent.

## Scope B: Full parity target

Full parity means every provider can support the same user-facing operations:

- Start and stop a session.
- Send a prompt from Neovim.
- Stream assistant text and tool progress.
- Receive and display approval requests.
- Approve or deny commands and file changes.
- Request a suggested edit for a buffer or visual range.
- Apply edits as reviewable pending changes.
- Accept or discard pending changes.
- Resume and identify sessions.
- Report provider errors and authentication failures consistently.

Provider-specific protocols remain isolated behind adapters; the common interface must not assume that Pi, Cursor Agent, and Codex emit identical events.

## Architecture

```text
Neovim commands/keymaps
        |
Agent manager and active-agent registry
        |
Common adapter contract + normalized events
        |
+-------+----------------+----------------+
|       |                |
Pi      Cursor Agent     Codex
JSONL   stream-json/CLI  app-server/exec --json
RPC
```

The terminal is the universal fallback. Protocol adapters are optional enhancements and must fail gracefully when a CLI is missing, unauthenticated, or does not support a requested capability.

## Configuration

Use a user-only JSON configuration under Neovim's data directory, separate from provider credential stores:

```json
{
  "active_agent": "pi",
  "agents": {
    "pi": { "enabled": true },
    "cursor": { "enabled": true },
    "codex": { "enabled": true }
  }
}
```

Commands, authentication stores, and model selection remain provider-owned. The harness may pass non-secret flags such as model, sandbox, workspace, and output mode, but it must not persist API keys or OAuth tokens.

## Provider capabilities discovered

- Pi 0.84.4: `pi --mode rpc`, `pi --print --mode json`, persistent agent auth under Pi's own agent directory.
- Cursor Agent 2026.08.25: `cursor-agent --print --output-format json|stream-json`, interactive CLI, model/workspace/sandbox/approval flags.
- Codex CLI 0.152.0: `codex exec --json`, `codex app-server`, sandbox and approval controls, generated app-server JSON schemas, local session management. Codex was installed but not authenticated during probing.

## Safety and failure behavior

- Missing executables appear as unavailable providers, not startup errors.
- Authentication is reported with an actionable provider-specific message.
- A running process is stopped before switching agents.
- The harness never injects one provider's credentials into another provider's environment.
- Buffer edits are only applied after response validation and changedtick checks.
- Unsupported capabilities produce a clear notification and leave the buffer unchanged.

## Testing strategy

- Unit-test pure command construction, config migration, event normalization, and capability checks.
- Use headless Neovim smoke tests for command registration and module loading.
- Use fake stdin/stdout fixtures for Pi, Cursor, and Codex protocol parsers.
- Run CLI availability checks without requiring credentials.
- Run authenticated provider smoke tests only when the user has logged in locally.

## Non-goals

- Implementing a new model or credential service.
- Copying provider sessions or tokens into Neovim state.
- Making provider-specific protocols identical.
- Replacing ToggleTerm or the existing LSP/editor setup.
- Adding a large UI framework for agent chat in the first implementation.
