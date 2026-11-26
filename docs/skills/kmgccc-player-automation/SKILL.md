---
name: kmgccc-player-automation
description: Compatibility entry for existing installations of the Muci CLI and MCP automation skill.
---

# Muci Automation Skill

This entry keeps existing installations working. Install one Muci automation skill per Agent.

Open Muci → Settings → Automation to refresh the local skill and commands. For the full workflow,
read the installed guide under
`$HOME/Library/Application Support/kmgccc.player/Automation/skills/muci-automation/SKILL.md`
or the [Muci Automation Skill](https://github.com/kmgcc/Muci/tree/main/docs/skills/muci-automation).

Existing commands use the same socket, authorization and catalog.

    CLI="$HOME/Library/Application Support/kmgccc.player/Automation/bin/player-automation"
    "$CLI" automation tools
    "$CLI" automation describe system.info

For MCP, run `"$CLI" mcp-stdio --profile core`. Keep the existing server key, tool names and
`kmgccc://` resource addresses. If your MCP command contains the previous App bundle path,
replace the command path with the stable CLI above.

Use tool descriptions, preview mutations with `dryRun` where supported and honor foreground
confirmation. For advanced workflows, consult the [automation reference](https://github.com/kmgcc/Muci/blob/main/docs/automation-capability-reference.md).
