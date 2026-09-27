# Tazuna with Cursor

Tazuna works with Cursor on a machine without Claude Code. Install it the same way:

```powershell
git clone https://github.com/AlfredoNeeto/tazuna.git "$HOME\tazuna"; & "$HOME\tazuna\bin\tazuna.cmd" setup
```

Open Cursor once before running `setup`, so `%USERPROFILE%\.cursor` exists: that directory is how
`setup`, `harness-toolkit` and `agent-skills` know Cursor is installed.

## What `setup` does for Cursor

| Piece | Where it lands |
|---|---|
| the `tlc-*` and `harness-eval` skills | `~/.cursor/skills`, by `agent-skills -a cursor` |
| `review-change` and `humanizer` skills, the `reviewer` agent | `~/.cursor/skills`, `~/.cursor/agents` |
| the engineering instructions (`user/CLAUDE.md`) | `~/.cursor/rules/tazuna.mdc`, a global rule applied in every project |
| the `harness-toolkit` hooks | `~/.cursor/hooks.json`, by `tlc harness install` |
| the user MCP servers (`context7`, `playwright`, `agent-skills`) | added to `~/.cursor/mcp.json`; servers already there are kept |

Claude Code steps (`~/.claude`, plugins, `claude mcp`) are skipped when `claude` is not on PATH.
With both installed, `setup` equips both.

## What `init` does for Cursor

`tazuna init` writes the same `AGENTS.md` and `.claude\` as for Claude Code, which Cursor reads, plus:

| File | For |
|---|---|
| `.cursor/hooks.json` | runs the three project hooks: the baseline at `sessionStart`, the secret check at `beforeShellExecution`, the verification gate at `stop` |
| `.cursor/rules/*.mdc` | the stack rules of `.claude/rules/`, converted to Cursor's format |

The gate works as in Claude Code: when a turn changed code and `.\.claude\scripts\verify.ps1` has
not passed on it, Cursor receives a follow-up message asking for the verification, once per turn.

## Not available in Cursor

| Missing | Why |
|---|---|
| the `deny` and `ask` permission rules | Cursor has no settings-file permission model; the `harness-toolkit` shell floor still applies |
| the `ponytail` plugin | a Claude Code plugin |
| `tazuna mcp add` | it writes `.mcp.json` for Claude Code; add a project server to `.cursor/mcp.json` by hand |

Cursor also imports Claude Code hooks from `.claude/settings.json` ("Third-Party Imports").
The project hooks detect a Cursor payload and step aside there, so the gate runs once, from
`.cursor/hooks.json`.
