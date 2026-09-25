# Security policy

## Supported versions

Only the latest release receives fixes. Run `tazuna update` to get it.

## Reporting a vulnerability

Please report it privately, not in a public issue:
[open a private security advisory](https://github.com/AlfredoNeeto/tazuna/security/advisories/new).

Include what you ran, what happened, and what you expected. A report about a secret reaching a
commit, the context or a log, a permission rule that lets a command run without approval, or the
`Stop` gate letting unverified code through is in scope.

The safety floor comes from [harness-toolkit](https://github.com/tech-leads-club/harness-toolkit)
and the `tlc-*` skills from [agent-skills](https://github.com/tech-leads-club/agent-skills); a
flaw inside either belongs with that project.
