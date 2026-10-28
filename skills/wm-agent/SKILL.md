---
name: wm-agent
description: Operate the Windows Manager `wm` command line tool (capture, profiles, layouts, rules, plan, run, verify) safely on macOS. Use when the user asks you to inspect, script or change window profiles or restore workspaces with wm. Always start from `wm agent-guide` and `wm schema --json`.
---

# wm agent skill

Use this skill when driving the `wm` CLI for the user.

## Start here

1. Run `wm agent-guide` and read it. It holds the safety rules, recipes, envelope and exit codes.
2. Run `wm schema --json` to get the exact commands, arguments, options, and the `mutates` and `touchesWindows` flags. Do not guess flag names.
3. Run `wm doctor --json` before any profile work.

## Rules

- Dry-run first: `wm plan <profile>` and `wm run <profile> --dry-run` change nothing.
- Never run `wm run`, `wm capture` or `wm verify` without the user's explicit consent in this conversation.
- Confirm before any command with `"mutates": true` changes the user's profiles, settings, layouts or rules. Copy a profile first for experiments.
- Use `--json` and read the `ok` field of the envelope.
- Do not edit profile files by hand, and do not change macOS permissions. Ask the user to do those.
