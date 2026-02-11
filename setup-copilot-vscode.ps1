#Requires -Version 7.0
<#
.SYNOPSIS
  HCHB Copilot VS Code Bootstrap

.DESCRIPTION
  Clones the private ai-tools repo to a temp folder, syncs selected Copilot
  assets (agents/skills/prompts) into VS Code user folders and ~/.copilot,
  updates VS Code settings, and cleans up the temp repo.

  Designed to be executed directly from a URL using pwsh.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RepoUrl = "https://github.com/homecareHomebase/ai-tools",
    [string]$Branch = "main",
    [ValidateSet("Code", "Code - Insiders")]
    [string]$VsCodeChannel = "Code",
    [switch]$KeepTemp,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$script:IsDryRun = $DryRun.IsPresent

function Write-Banner {
    $banner = @'
 _   _  ____ _   _ ____   ____            _ _ _ 
| | | |/ ___| | | | __ ) / ___|___  _ __ (_) (_)
| |_| | |   | |_| |  _ \| |   / _ \| '_ \| | | |
|  _  | |___|  _  | |_) | |__| (_) | |_) | | | |
|_| |_|\____|_| |_|____/ \____\___/| .__/|_|_|_|
                                  |_|           
'@
    Write-Host $banner -ForegroundColor Magenta
    Write-Host "HCHB Copilot VS Code Bootstrap" -ForegroundColor Cyan
}

function Write-Section {
    param([string]$Message)
    Write-Host ""
    Write-Host $Message -ForegroundColor Cyan
    Write-Host ("─" * [Math]::Min(72, $Message.Length + 6)) -ForegroundColor DarkCyan
}

function Write-Step {
    param([string]$Message)
    if (-not $script:TotalSteps) {
        $script:TotalSteps = 5
    }
    if (-not $script:StepIndex) {
        $script:StepIndex = 0
    }

    $script:StepIndex++
    Write-Host ("➤  [" + $script:StepIndex + "/" + $script:TotalSteps + "] " + $Message) -ForegroundColor Yellow
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  ✓ $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  ⚠ $Message" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "  • $Message" -ForegroundColor Gray
}

function Write-Stat {
    param(
        [string]$Label,
        [string]$Value
    )
    $padded = $Label.PadRight(18)
    Write-Host "  $padded $Value" -ForegroundColor DarkGray
}

function Get-VsCodeVersion {
    $code = Get-Command code -ErrorAction SilentlyContinue
    if (-not $code) {
        return $null
    }

    try {
        $output = & $code.Source --version 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $null
        }

        if ($output -is [System.Array]) {
            return $output[0].Trim()
        }

        return $output.Trim()
    } catch {
        return $null
    }
}

function Get-VsCodeUserRoot {
    param([string]$Channel)

    if ($IsWindows) {
        return (Join-Path $env:APPDATA "$Channel\User")
    }

    if ($IsMacOS) {
        return (Join-Path $HOME "Library/Application Support/$Channel/User")
    }

    return (Join-Path $HOME ".config/$Channel/User")
}

function Ensure-Directory {
    param([string]$Path)
    if (Test-Path $Path) {
        return
    }

    if ($script:IsDryRun) {
        Write-Info "DRY RUN: would create directory $Path"
        return
    }

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Invoke-GitClone {
    param(
        [string]$Url,
        [string]$BranchName,
        [string]$Destination
    )

    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        throw "Git is required but was not found in PATH."
    }

    & $git.Source clone --depth 1 --branch $BranchName $Url $Destination 2>&1 | ForEach-Object { $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "git clone failed"
    }
}

function Get-FileHashSafe {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return $null
    }

    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash
}

function Copy-FileIfChanged {
    param(
        [string]$Source,
        [string]$Destination
    )

    $sourceHash = Get-FileHashSafe -Path $Source
    $destHash = Get-FileHashSafe -Path $Destination

    if (-not $destHash -or ($sourceHash -and $sourceHash -ne $destHash)) {
        if ($script:IsDryRun) {
            return $true
        }
        Ensure-Directory -Path (Split-Path -Path $Destination -Parent)
        Copy-Item -Path $Source -Destination $Destination -Force
        return $true
    }

    return $false
}

function Sync-Directory {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string]$Filter = "*"
    )

    if (-not (Test-Path $SourceRoot)) {
        Write-Warn "Source not found: $SourceRoot"
        return 0
    }
    Ensure-Directory -Path $DestinationRoot

    Get-ChildItem -Path $SourceRoot -Directory -Recurse | ForEach-Object {
        $relative = $_.FullName.Substring($SourceRoot.Length).TrimStart([char[]]"\\/")
        $destDir = Join-Path $DestinationRoot $relative
        Ensure-Directory -Path $destDir
    }

    $updated = 0
    Get-ChildItem -Path $SourceRoot -File -Recurse -Filter $Filter | ForEach-Object {
        $relative = $_.FullName.Substring($SourceRoot.Length).TrimStart([char[]]"\\/")
        $dest = Join-Path $DestinationRoot $relative
        if (Copy-FileIfChanged -Source $_.FullName -Destination $dest) {
            $updated++
        }
    }

    return $updated
}

function Sync-Selection {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string[]]$Items,
        [ValidateSet("files", "folders")]
        [string]$Mode = "files"
    )

    if (-not $Items -or $Items.Count -eq 0) {
        return Sync-Directory -SourceRoot $SourceRoot -DestinationRoot $DestinationRoot
    }

    $updated = 0
    foreach ($item in $Items) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }

        $sourcePath = Join-Path $SourceRoot $item
        if (-not (Test-Path $sourcePath)) {
            Write-Warn "Selected $Mode item not found: $sourcePath"
            continue
        }

        if ($Mode -eq "files") {
            $destPath = Join-Path $DestinationRoot $item
            if (Copy-FileIfChanged -Source $sourcePath -Destination $destPath) {
                $updated++
            }
        } else {
            $destPath = Join-Path $DestinationRoot $item
            $updated += Sync-Directory -SourceRoot $sourcePath -DestinationRoot $destPath
        }
    }

    return $updated
}

function Read-SettingsJson {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return @{}
    }

    $raw = Get-Content -Path $Path -Raw
    try {
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Warn "settings.json is not valid JSON. Creating fresh settings."
        return @{}
    }
}

function Set-SettingsValue {
    param(
        [object]$Settings,
        [string]$Key,
        [object]$Value
    )

    if ($Settings -is [hashtable]) {
        $Settings[$Key] = $Value
        return
    }

    $Settings | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
}

function Write-SettingsJson {
    param(
        [string]$Path,
        [object]$Settings
    )

    if ($script:IsDryRun) {
        Write-Info "DRY RUN: would update settings.json at $Path"
        return
    }

    Ensure-Directory -Path (Split-Path -Path $Path -Parent)
    $Settings | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
}

Write-Banner
Write-Section "Starting setup"

$vsCodeUserRoot = Get-VsCodeUserRoot -Channel $VsCodeChannel
$agentsRoot = Join-Path $vsCodeUserRoot "prompts"
$promptsRoot = Join-Path $vsCodeUserRoot "prompts"
$skillsRoot = Join-Path (Join-Path $HOME ".copilot") "skills"
$vsCodeVersion = Get-VsCodeVersion
$minVsCodeVersion = [version]"1.109.0"

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("hchb-ai-tools-" + [Guid]::NewGuid())

Write-Stat "OS" ([System.Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim())
Write-Stat "VS Code" $VsCodeChannel
if ($vsCodeVersion) {
    Write-Stat "VS Code ver" $vsCodeVersion
} else {
    Write-Stat "VS Code ver" "Not detected (code CLI unavailable)"
}
Write-Stat "Mode" ($(if ($script:IsDryRun) { "Dry Run" } else { "Live" }))
Write-Stat "User root" $vsCodeUserRoot
Write-Stat "Agents" $agentsRoot
Write-Stat "Prompts" $promptsRoot
Write-Stat "Skills" $skillsRoot

if ($script:IsDryRun) {
    Write-Info "Dry run enabled: no user files or settings will be modified (temp clone will be cleaned)."
}

Write-Step "Step 0: Verify VS Code version (min $minVsCodeVersion)"
if ($vsCodeVersion) {
    try {
        $parsedVersion = [version]$vsCodeVersion
        if ($parsedVersion -lt $minVsCodeVersion) {
            throw "VS Code $vsCodeVersion detected, but $minVsCodeVersion or later is required. Please update VS Code."
        }
        Write-Ok "VS Code version check passed"
    } catch {
        throw $_
    }
} else {
    Write-Warn "VS Code version not detected (code CLI unavailable). Skipping version check."
}

Write-Step "Step 1: Clone ai-tools repo to temp"
try {
    Invoke-GitClone -Url $RepoUrl -BranchName $Branch -Destination $tempRoot
    Write-Ok "Repo cloned"
    Write-Info "Temp path: $tempRoot"
} catch {
    throw "Unable to clone ai-tools. Ensure GitHub authentication is configured for the private repo. Details: $($_.Exception.Message)"
}

Write-Step "Step 2: Sync Copilot assets"
# TODO: Populate these lists. Leave empty to sync everything in that folder.
$agentFiles = @(
    "hchb-planner-subagent.agent.md",
    "hchb-implement-subagent.agent.md",
    "hchb-code-review-subagent.agent.md",
    "hchb-test-plan-subagent.agent.md"
)

$promptFiles = @(
    "remove-feature-flag.prompt.md"
)

$skillFolders = @(
    "ilspy-decompile",
    "figma-implement-design"
)

$updateVerb = if ($script:IsDryRun) { "Would update" } else { "Updated" }
$updateSummary = if ($script:IsDryRun) { "would be updated" } else { "updated" }

$agentsSource = Join-Path $tempRoot "agents"
$promptsSource = Join-Path $tempRoot "prompts"
$skillsSource = Join-Path $tempRoot "skills"

$updatedAgents = Sync-Selection -SourceRoot $agentsSource -DestinationRoot $agentsRoot -Items $agentFiles -Mode "files"
if ($updatedAgents -gt 0) {
    Write-Ok "$updateVerb $updatedAgents files from agents"
} else {
    Write-Info "No changes for agents"
}

$updatedPrompts = Sync-Selection -SourceRoot $promptsSource -DestinationRoot $promptsRoot -Items $promptFiles -Mode "files"
if ($updatedPrompts -gt 0) {
    Write-Ok "$updateVerb $updatedPrompts files from prompts"
} else {
    Write-Info "No changes for prompts"
}

$updatedSkills = Sync-Selection -SourceRoot $skillsSource -DestinationRoot $skillsRoot -Items $skillFolders -Mode "folders"
if ($updatedSkills -gt 0) {
    Write-Ok "$updateVerb $updatedSkills files from skills"
} else {
    Write-Info "No changes for skills"
}

$totalUpdated = $updatedAgents + $updatedPrompts + $updatedSkills

Write-Ok "Asset sync complete. Files ${updateSummary}: $totalUpdated"

Write-Step "Step 3: Cleanup temp repo"
if (-not $KeepTemp) {
    try {
        Remove-Item -Path $tempRoot -Recurse -Force
        if ($script:IsDryRun) {
            Write-Ok "Removed temp repo (dry run)"
        } else {
            Write-Ok "Removed temp repo"
        }
    } catch {
        Write-Warn "Could not remove temp repo at $tempRoot"
    }
} else {
    Write-Warn "Temp repo preserved at $tempRoot"
}

Write-Step "Step 4: Update VS Code settings"
$settingsPath = Join-Path $vsCodeUserRoot "settings.json"
$settings = Read-SettingsJson -Path $settingsPath

# Required Copilot/VS Code settings to enforce.
$settingsUpdates = [ordered]@{
    "github.copilot.chat.agent.thinkingTool" = $true
    "github.copilot.chat.codeGeneration.useInstructionFiles" = $true
    "chat.agent.maxRequests" = 500
    "chat.todoListTool.enabled" = $true
    "github.copilot.chat.alternateGptPrompt.enabled" = $true
    "github.copilot.chat.gpt5AlternatePrompt" = "v2"
    "chat.customAgentInSubagent.enabled" = $true
    "github.copilot.chat.anthropic.thinking.budgetTokens" = 32000
    "chat.useNestedAgentsMdFiles" = $true
    "chat.experimental.useSkillAdherencePrompt" = $true
}

foreach ($key in $settingsUpdates.Keys) {
    Set-SettingsValue -Settings $settings -Key $key -Value $settingsUpdates[$key]
}

Write-SettingsJson -Path $settingsPath -Settings $settings
Write-Ok "VS Code settings updated"

Write-Host ""
Write-Section "All set"
Write-Ok "VS Code user root: $vsCodeUserRoot"
Write-Ok "Agents: $agentsRoot"
Write-Ok "Prompts: $promptsRoot"
Write-Ok "Skills: $skillsRoot"
Write-Ok "Files ${updateSummary}: $totalUpdated"