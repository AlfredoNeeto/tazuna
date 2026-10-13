---
name: ship
description: Hands a finished change over for the owner's approval - runs the verification, reads the whole diff for anything nobody asked for, writes a Conventional Commit message and the pull request text, and stops before anything is published. Use when the user says "ship", "wrap up", "prepare the commit", "write the PR" or "finish this branch". It never pushes.
---

# Ship a change

Publishing is the owner's decision. This prepares everything up to it, then stops.

## Steps

1. **Verify.** Run `.\.claude\scripts\verify.ps1`, or the project's own build and tests. A
   pass on unchanged sources is reported at once. Stop on a failure: fix it or report it.
2. **Read the diff.** `git status`, then `git diff` and `git diff --staged`, untracked files
   included. Look for changes nobody asked for, debug leftovers, commented-out code, secrets,
   generated files, and tests that were weakened, skipped or deleted. Raise each one; do not
   tidy it away silently.
3. **Write the commit message** as a Conventional Commit: `type(scope): summary` in the
   imperative, under 72 characters, then a body that says what changed and why. Where the
   tlc-spec-driven skill is installed, check the message with its `check_commit.py --message`.
4. **Commit only as the project allows.** Where the project or the user wants to approve
   commits, propose the message and wait. Never amend or rewrite history someone else has.
5. **Draft the pull request**: a title, what changed and why, how it was verified (the command
   and its result), the risks, and what a human should read closely. When the project has the
   azure-devops MCP server, offer to open the pull request there as a draft; otherwise hand
   the text over.
6. **Stop before publishing.** Never run `git push`, never merge, never complete a pull
   request. Say what is left for the owner to do.
