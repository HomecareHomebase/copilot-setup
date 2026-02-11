# copilot-setup

Bootstrap HCHB Copilot configuration for VS Code.

## Requirements

- **PowerShell 7+** (`pwsh`) — the script has `#Requires -Version 7.0`
- **Git** in `PATH`
- **VS Code** (script enforces a minimum version when the `code` CLI is available)
- Access to the private `ai-tools` repo + GitHub auth configured for `git clone`

## Run (download/eval)

Copy/paste into **PowerShell 7**:

```powershell
Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/HomecareHomebase/copilot-setup/main/setup-copilot-vscode.ps1' | Invoke-Expression
```

### Run with options (recommended)

If you want to pass parameters (like `-DryRun`), use a script block instead of piping to `Invoke-Expression`:

```powershell
$script = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/HomecareHomebase/copilot-setup/main/setup-copilot-vscode.ps1'; & ([ScriptBlock]::Create($script)) -DryRun
```

Common parameters:

- `-DryRun` — don’t modify user files/settings (still clones to temp)
- `-KeepTemp` — preserve the temp clone folder
- `-VsCodeChannel "Code" | "Code - Insiders"`
- `-RepoUrl` and `-Branch` — override the `ai-tools` source
