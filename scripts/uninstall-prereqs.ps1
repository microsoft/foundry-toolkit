#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstall Microsoft Foundry prerequisites on Windows (test helper).

.DESCRIPTION
    Reverses install-prereqs.ps1 so the install script can be exercised
    repeatedly during testing. Steps (reverse dependency order):

      1. VS Code Microsoft Foundry extension  (code --uninstall-extension ...)
      2. microsoft-foundry skill              (remove ~/.agents/skills/microsoft-foundry)
      3. azd Foundry extension                (azd ext uninstall microsoft.foundry)
      4. azd                                  (winget uninstall microsoft.azd)
      5. Azure CLI                            (winget uninstall Microsoft.AzureCLI)

    Each step is idempotent (skip if not present) and a failure in one step
    does not abort the rest. No automatic elevation; if a step needs admin
    rights the underlying tool will fail and the script records it.

.NOTES
    Intended for local testing. Does NOT delete user data such as
    %USERPROFILE%\.azure or %USERPROFILE%\.azd.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Configuration (must match install-prereqs.ps1)
# ---------------------------------------------------------------------------

$script:Config = [pscustomobject]@{
    AzCliWingetId           = 'Microsoft.AzureCLI'
    AzdWingetId             = 'microsoft.azd'
    AzdFoundryExtensionId   = 'microsoft.foundry'
    SkillName               = 'microsoft-foundry'
    SkillsRoot              = Join-Path $env:USERPROFILE '.agents\skills'
    VSCodeExtensionId       = 'ms-windows-ai-studio.windows-ai-studio'
    VSCodeVariantCommands   = @('code', 'code-insiders')
}

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Level,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Message,
        [ConsoleColor] $Color = [ConsoleColor]::Gray
    )
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $line  = '{0} [{1,-5}] {2}' -f $stamp, $Level, $Message
    Write-Host $line -ForegroundColor $Color
}

function Write-Info { param([AllowEmptyString()][string] $m) Write-Log -Level 'INFO' -Message $m -Color Cyan }
function Write-Step { param([AllowEmptyString()][string] $m) Write-Log -Level 'STEP' -Message $m -Color Magenta }
function Write-Skip { param([AllowEmptyString()][string] $m) Write-Log -Level 'SKIP' -Message $m -Color DarkGray }
function Write-Done { param([AllowEmptyString()][string] $m) Write-Log -Level 'OK'   -Message $m -Color Green }
function Write-Warn { param([AllowEmptyString()][string] $m) Write-Log -Level 'WARN' -Message $m -Color Yellow }
function Write-Err  { param([AllowEmptyString()][string] $m) Write-Log -Level 'ERR'  -Message $m -Color Red }

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

function Test-Command {
    param([Parameter(Mandatory)][string] $Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]      $Name,
        [Parameter(Mandatory)][scriptblock] $Action
    )

    Write-Step "--- $Name ---"
    try {
        & $Action
        Write-Done $Name
    }
    catch {
        Write-Err ("{0} failed: {1}" -f $Name, $_.Exception.Message)
        $script:Failures += $Name
    }
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]   $File,
        [Parameter()][string[]]          $Arguments = @()
    )

    & $File @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command '$File $($Arguments -join ' ')' exited with code $LASTEXITCODE."
    }
}

function Invoke-NativeOutput {
    <#
    .SYNOPSIS
        Run a native command and return its combined stdout+stderr as a single
        string. Native stderr lines are merged so that, with
        $ErrorActionPreference = 'Stop' set at the script level, informational
        stderr text is NOT treated as a terminating PowerShell error.
        $LASTEXITCODE is preserved.
    #>
    param(
        [Parameter(Mandatory)][string] $File,
        [Parameter()][string[]]        $Arguments = @()
    )

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        (& $File @Arguments 2>&1 | Out-String)
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Test-WingetPackageInstalled {
    param([Parameter(Mandatory)][string] $Id)

    if (-not (Test-Command -Name 'winget')) { return $false }
    # NOTE: 'winget list --exact --id' is case-sensitive against the displayed
    # ID column (e.g. installed 'Microsoft.Azd' will NOT match query
    # 'microsoft.azd'). Omit --exact and rely on the case-insensitive regex
    # below.
    $output = Invoke-NativeOutput -File 'winget' -Arguments @('list', '--id', $Id, '--source', 'winget')
    return ($output -match [regex]::Escape($Id))
}

# ---------------------------------------------------------------------------
# Step 1: VS Code Foundry extension
# ---------------------------------------------------------------------------

function Test-VSCodeExtensionInstalled {
    param(
        [Parameter(Mandatory)][string] $VariantCommand,
        [Parameter(Mandatory)][string] $ExtensionId
    )
    try {
        $output = Invoke-NativeOutput -File $VariantCommand -Arguments @('--list-extensions')
        if ($LASTEXITCODE -ne 0) { return $false }
        $lines = $output -split "`r?`n" | Where-Object { $_ -ne '' }
        return ($lines -contains $ExtensionId)
    }
    catch {
        return $false
    }
}

function Uninstall-VSCodeFoundryToolkit {
    $extId    = $script:Config.VSCodeExtensionId
    $variants = $script:Config.VSCodeVariantCommands | Where-Object { Test-Command -Name $_ }

    if (-not $variants) {
        Write-Skip "Neither 'code' nor 'code-insiders' is on PATH. Nothing to uninstall."
        return
    }

    foreach ($variant in $variants) {
        if (-not (Test-VSCodeExtensionInstalled -VariantCommand $variant -ExtensionId $extId)) {
            Write-Skip "Extension '$extId' not installed in $variant."
            continue
        }
        Write-Info "Uninstalling extension '$extId' from $variant..."
        Invoke-NativeCommand -File $variant -Arguments @('--uninstall-extension', $extId)
    }
}

# ---------------------------------------------------------------------------
# Step 2: microsoft-foundry skill
# ---------------------------------------------------------------------------

function Uninstall-FoundrySkill {
    $destDir = Join-Path $script:Config.SkillsRoot $script:Config.SkillName

    if (-not (Test-Path -LiteralPath $destDir)) {
        Write-Skip "Skill '$($script:Config.SkillName)' not present at $destDir."
        return
    }

    Write-Info "Removing $destDir ..."
    Remove-Item -LiteralPath $destDir -Recurse -Force
}

# ---------------------------------------------------------------------------
# Step 3: azd Foundry extension
# ---------------------------------------------------------------------------

function Test-AzdExtensionInstalled {
    param([Parameter(Mandatory)][string] $ExtensionId)

    if (-not (Test-Command -Name 'azd')) { return $false }
    try {
        # --installed restricts output to extensions that are actually
        # installed (without it the registry of all available extensions is
        # returned and a plain text match would match "Not installed" rows).
        $output = Invoke-NativeOutput -File 'azd' -Arguments @('ext', 'list', '--installed')
        if ($LASTEXITCODE -ne 0) { return $false }
        return ($output -match [regex]::Escape($ExtensionId))
    }
    catch {
        return $false
    }
}

function Uninstall-AzdFoundryExtension {
    $extId = $script:Config.AzdFoundryExtensionId

    if (-not (Test-Command -Name 'azd')) {
        Write-Skip "azd is not on PATH; skipping extension uninstall."
        return
    }
    if (-not (Test-AzdExtensionInstalled -ExtensionId $extId)) {
        Write-Skip "azd extension '$extId' not installed."
        return
    }

    Write-Info "Uninstalling azd extension '$extId'..."
    Invoke-NativeCommand -File 'azd' -Arguments @('ext', 'uninstall', $extId)
}

# ---------------------------------------------------------------------------
# Step 4: azd
# ---------------------------------------------------------------------------

function Uninstall-Azd {
    $id = $script:Config.AzdWingetId

    if (-not (Test-Command -Name 'winget')) {
        if (Test-Command -Name 'azd') {
            Write-Warn "winget not available; cannot uninstall azd automatically."
        } else {
            Write-Skip "azd not on PATH; nothing to do."
        }
        return
    }
    if (-not (Test-WingetPackageInstalled -Id $id)) {
        Write-Skip "winget package '$id' not installed."
        return
    }

    Write-Info "Uninstalling azd via winget ($id)..."
    Invoke-NativeCommand -File 'winget' -Arguments @(
        'uninstall',
        '--id', $id,
        '--source', 'winget',
        '--accept-source-agreements',
        '--silent'
    )
}

# ---------------------------------------------------------------------------
# Step 5: Azure CLI
# ---------------------------------------------------------------------------

function Uninstall-AzCli {
    $id = $script:Config.AzCliWingetId

    if (-not (Test-Command -Name 'winget')) {
        if (Test-Command -Name 'az') {
            Write-Warn "winget not available; cannot uninstall Azure CLI automatically."
        } else {
            Write-Skip "az not on PATH; nothing to do."
        }
        return
    }
    if (-not (Test-WingetPackageInstalled -Id $id)) {
        Write-Skip "winget package '$id' not installed."
        return
    }

    Write-Info "Uninstalling Azure CLI via winget ($id)..."
    Invoke-NativeCommand -File 'winget' -Arguments @(
        'uninstall', '--exact',
        '--id', $id,
        '--source', 'winget',
        '--accept-source-agreements',
        '--silent'
    )
}

# ---------------------------------------------------------------------------
# Verification (warn-only) — opposite of install verification
# ---------------------------------------------------------------------------

function Test-Uninstall {
    Write-Step '--- Verification ---'

    foreach ($variant in $script:Config.VSCodeVariantCommands) {
        if (-not (Test-Command -Name $variant)) { continue }
        if (Test-VSCodeExtensionInstalled -VariantCommand $variant -ExtensionId $script:Config.VSCodeExtensionId) {
            Write-Warn "$variant : $($script:Config.VSCodeExtensionId) still installed"
        } else {
            Write-Done "$variant : $($script:Config.VSCodeExtensionId) removed"
        }
    }

    $skillPath = Join-Path $script:Config.SkillsRoot $script:Config.SkillName
    if (Test-Path -LiteralPath $skillPath) {
        Write-Warn "skill $($script:Config.SkillName) still present at $skillPath"
    } else {
        Write-Done "skill $($script:Config.SkillName) removed"
    }

    if (Test-AzdExtensionInstalled -ExtensionId $script:Config.AzdFoundryExtensionId) {
        Write-Warn "azd ext $($script:Config.AzdFoundryExtensionId) still installed"
    } else {
        Write-Done "azd ext $($script:Config.AzdFoundryExtensionId) removed"
    }

    if (Test-Command -Name 'azd') {
        Write-Warn "azd still on PATH (a new shell may be required to refresh PATH)"
    } else {
        Write-Done 'azd removed'
    }

    if (Test-Command -Name 'az') {
        Write-Warn "az still on PATH (a new shell may be required to refresh PATH)"
    } else {
        Write-Done 'az removed'
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$script:Failures = @()

Write-Info "Microsoft Foundry prerequisite uninstaller (Windows)"
Write-Info "Skills root : $($script:Config.SkillsRoot)"
Write-Info ""

Invoke-Step -Name 'VS Code Foundry extension' -Action { Uninstall-VSCodeFoundryToolkit }
Invoke-Step -Name 'microsoft-foundry skill'   -Action { Uninstall-FoundrySkill }
Invoke-Step -Name 'azd Foundry extension'     -Action { Uninstall-AzdFoundryExtension }
Invoke-Step -Name 'Azure Developer CLI (azd)' -Action { Uninstall-Azd }
Invoke-Step -Name 'Azure CLI'                 -Action { Uninstall-AzCli }

Test-Uninstall

Write-Info ''
if ($script:Failures.Count -gt 0) {
    Write-Warn ("Completed with {0} failed step(s): {1}" -f $script:Failures.Count, ($script:Failures -join ', '))
    exit 1
} else {
    Write-Done 'All steps completed.'
    exit 0
}
