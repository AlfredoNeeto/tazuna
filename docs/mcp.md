# MCP servers

Two lists, two scopes. A server at user scope loads its tools into **every** session on the
machine, so only what is useful everywhere goes there. Everything else is added to the project
that needs it, with one command.

## User scope - `mcp/servers.json`, registered by `tazuna setup`

| Server | What it does | Permissions |
|---|---|---|
| `context7` | current library documentation | `resolve-library-id` allow; `query-docs` ask - the query is free text and could carry an internal name outward |
| `playwright` | the browser as a sensor: open the app, click, look | every tool ask; `--isolated` keeps no cookies between sessions |
| `agent-skills` | search and load any Tech Leads Club skill on demand | default (ask) |

## Project scope - `mcp/catalog.json`, added by `tazuna mcp add <name>`

| Name | What it does | Needs | Trust boundary |
|---|---|---|---|
| `azure-devops` | on-premises Azure DevOps Server: PRs, work items, wiki, search | the project URL and a PAT, asked for on every `add` and verified before anything is registered | community server `@tiberriver256/mcp-server-azure-devops`; holds a PAT; API pinned to 7.0; 7.1 returned 400 on the server it was tested against |
| `serena` | symbol navigation: callers, implementations, declarations | `uvx` | runs a language server locally; nothing leaves the machine |
| `drawio` | open and edit diagrams in the draw.io editor | `node` | official `@drawio/mcp` from jgraph |
| `plantuml` | render PlantUML | `node` | **the diagram source is sent to `PLANTUML_SERVER_URL`**, `https://www.plantuml.com/plantuml` unless you set that variable to an internal server |
| `mermaid` | render Mermaid to SVG/PNG | `node` | renders locally |

`add` merges the entry into the project's `.mcp.json`, enables it in `.claude/settings.json`,
and never removes what is already there. Claude Code asks you to approve a project server the
first time it starts in that project.

`azure-devops` is the exception, because each project may talk to a different collection with a
different token. `tazuna mcp add azure-devops` asks for the project URL as the browser shows it
(`http://server/Collection/Project`), splits it into collection and project, checks both and the
PAT against the server, and registers the server with `claude mcp add -s local`: the values live in
`~/.claude.json` under that project's path, outside the repository, and nothing is written to
`.mcp.json`. Run it again in the project to change the URL or rotate the PAT. Why not
`${ADO_PAT}` in `.mcp.json`: Claude Code expands placeholders only from its own process
environment, so that is one value per machine, and a missing variable reaches the server as the
literal text. Versions before 1.2.0 stored `ADO_COLLECTION_URL` and `ADO_PAT` as user environment
variables; nothing reads them any more, and they can be deleted.

## Adding a server to a catalog

Answer, in the entry's `purpose` or here: what it makes possible that was not before, what
crosses the trust boundary, and why user scope rather than project (or the reverse). Credentials
are always `${ENV_VAR}` placeholders; `install-mcp.ps1` refuses a literal secret, and the
self-test fails on one.
