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
        Version            = "1.5.0"
        ToolkitPackage     = "@tech-leads-club/harness-toolkit@0.16.3"
        AgentSkillsPackage = "@tech-leads-club/agent-skills@1.5.0"
        # why: the version of @tech-leads-club/skills-catalog the CLI downloads; without it, the newest.
        SkillsCatalog      = "0.17.9"
        AgentSkills        = @(
            "tlc-discover", "tlc-spec-lean", "tlc-spec-driven", "tlc-plan", "tlc-implement", "harness-eval",
            "modular-design-principles", "evolutionary-modular-architecture", "modular-decomposition",
            "the-judge", "coding-guidelines", "security-best-practices", "security-threat-model", "create-adr", "create-rfc"
        )
        # why: what a 1.x Tazuna installed and 2.0 removes. Each path maps to the SHA256 of every shipped
        # version, as LF and as CRLF, since a checkout's line endings follow core.autocrlf; a file
        # holding anything else was edited, and is kept.
        Retired            = [PSCustomObject]@{
            Machine = @{
                "skills\fix-bug\SKILL.md" = @(
                "267D924CA58DA2F06B42034BCFF4093DFC68EFE11DE7CB555460BE3882E7592B",
                "C008274C43F59CF9DC09EEFEC25A92F59CD4DC09977D01DCB0168EF2F2A1FEED"
            )
            }
            Project = @{
                ".claude\scripts\verify.ps1" = @(
                "007C387D34692CC62D88515BDB8B2E1B93C180DBCDAB15793BAF286FEB387283",
                "03CFA133A6F94E2BFB9A105385C13EF7557BA316F744EA95766E1F960660C7FF",
                "2183C246C5C7BFEB4875FFD40D0F5062A68B152EB2ADB7955FA4485BC0FCA505",
                "4D3A1315B975104AC6D37AAC41B9A3ACEF5718A86E2FEEE38D709BE662BC00E0",
                "587DB8EE3CB0748145E55A66EA909FD6BC9A104CBB660FC9261982A1B3CE04EE",
                "5A682E2A830BAF6FF811A9A0D0129511147FD041ED5ECD2394969DDEFA600214",
                "6C2DBA7147E77D82F22196C687F340C4F686D997AD9D6540FA504D7A48C23600",
                "88E0A0DBBB02F964D15952E3558452C0E742A403C6868DFD404DA7E7435D57D0",
                "8CBA95A46983DF71C12009BC30FEE85B1F4E74D131F059CB9BCC20270442B68C",
                "A10F9850AAA2F546C5F3B118BCCB235189438B8C6740EBB03E82B736B57F6565",
                "CDE90DC5AB8D98DAD1E993FECDA2F604B69F46DCE83C0A53A7D9601974785C52",
                "E15C45210D9C2C14224475E7BAE5FB62915E7AD79374089493C48DB45FE2A661"
            )
                ".claude\rules\csharp.md" = @(
                "A7A050F9361F1E1EC8A1029EB4F7772E397A7468C0FA1ED8442933484C3A7950",
                "BEF35F0BC1938275D4DE4D96D352B6A95A413C623F78024E206648B12457D965"
            )
                ".claude\rules\testing.md" = @(
                "522DE08BBE0C7B6A7D1F56EB81BA040372C5BBD23095A10200DB58D85161D50A",
                "C33DD7B5D1636184E2308E3FC119660B254E68EBCCED6FC33B910D2DEDCA8BE5"
            )
                ".cursor\rules\csharp.mdc" = @("5487A184C789BCC0C37756E5B41B1BCB2B65BAE3CF8F72A58C06AC0BEF81A834")
                ".cursor\rules\testing.mdc" = @("920C99D295950CCD534D376187877CFA4046011C4B4747D86B45887547EB82AC")
            }
        }
        # why: the harness-toolkit hooks, agent-skills and the npx MCP servers refuse node below 24.
        MinimumNodeMajor     = 24
        # why: the last Claude Code version this harness was proven on; AGENTS.md support landed earlier.
        MinimumClaudeVersion = "2.1.296"
    }
}

Export-ModuleMember -Function @(
    "Get-HarnessManifest"
)
