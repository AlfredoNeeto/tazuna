# Azure DevOps Server (on-premises)

Added by `tazuna mcp add azure-devops`. The server is `@tiberriver256/mcp-server-azure-devops`, a
community server: Microsoft's hardcodes `dev.azure.com` and does not support on-premises. It
holds a PAT and exposes 46 tools; none carries an allow rule, so every call is shown before it runs.

This project talks to an **on-premises** Azure DevOps Server, not `dev.azure.com`. Its REST API
surface is older and narrower, and several endpoints the cloud documentation describes do not
exist on it.

## Do not assume

- **Not** `https://dev.azure.com/<org>`. The collection URL is the server's own.
- **Not** API version 7.1 or 7.2. A server answers only the API versions its release shipped
  with; 7.1 returned HTTP 400 on the server this was tested against. The MCP entry pins
  `AZURE_DEVOPS_API_VERSION` to 7.0.
- **Not** the cloud's auth. On-premises means a Personal Access Token, issued on that server.

A snippet copied from the cloud documentation that returns 404 or 400 here has usually not
failed because of the code around it. Check the API version before debugging anything else.

The server is registered for this project only, in Claude Code's local scope, with the
collection, the default project and the PAT taken from the project URL the user gave. If a call
returns 401, or the collection or project is wrong, do not guess a server address and do not ask
for the token in chat: tell the user to run `tazuna mcp add azure-devops` again in this project,
which prompts for the project URL and a PAT, verifies them and replaces the registration without
echoing the token.

## Pipelines

- Read the existing pipelines before writing a new one. An internal server accumulates
  conventions - agent pool names, variable groups, service connections - that are not
  discoverable from the YAML schema.
- Never commit a secret into a pipeline file. Variable groups and secret variables exist for
  this, and a value in YAML is in the history permanently.
- A pipeline change is a deployment change. Treat it as high-risk and confirm before applying.
- **`mcp__azure-devops__trigger_pipeline` starts a build or a deployment.** Deny it in the
  project's `.claude/settings.json` unless someone deliberately decided otherwise. A permission
  prompt for it looks like every other prompt, and this one deploys.

## Constraints

- Never write to work items, pull requests or pipelines without explicit confirmation. Reading
  is the default; changing something that a team sees is not.
- Never paste internal ticket contents, customer data or proprietary source into an external
  service.
