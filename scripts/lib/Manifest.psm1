# Manifest.psm1
#
# What this harness installs and requires, pinned in one place.
# invariant: a leaf - imports no other module, and only Console.psm1 writes to the host.
# Windows PowerShell 5.1 compatible.

Set-StrictMode -Version 2.0

function Get-HarnessManifest {
    <#
        The upstream pieces this harness installs, pinned in one place so setup,
        doctor and init cannot disagree about them.
    #>
    return [PSCustomObject]@{
        Version            = "1.2.0"
        ToolkitPackage     = "@tech-leads-club/harness-toolkit@0.16.2"
        AgentSkillsPackage = "@tech-leads-club/agent-skills@1.4.10"
        AgentSkills        = @("tlc-discover", "tlc-spec-lean", "tlc-spec-driven", "tlc-plan", "tlc-implement", "harness-eval")
        # why: the harness-toolkit hooks, agent-skills and the npx MCP servers refuse node below 24.
        MinimumNodeMajor     = 24
        # why: AGENTS.md support, which the project templates rely on, landed in this version.
        MinimumClaudeVersion = "2.1.277"
    }
}

Export-ModuleMember -Function @(
    "Get-HarnessManifest"
)
