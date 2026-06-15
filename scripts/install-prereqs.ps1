#Requires -Version 5.1
<#
.SYNOPSIS
    Install Microsoft Foundry prerequisites on Windows.

.DESCRIPTION
    Installs (in order):
      1. Azure CLI                          (winget Microsoft.AzureCLI)
      2. Azure Developer CLI (azd)          (winget microsoft.azd)
      3. azd Foundry extension              (azd ext install microsoft.foundry)
      4. microsoft-foundry skill            (download latest release of
                                             github.com/microsoft/azure-skills
                                             and copy skills/microsoft-foundry
                                             to ~/.agents/skills/microsoft-foundry)
      5. VS Code Microsoft Foundry          (code --install-extension
         extension for every variant         ms-windows-ai-studio.windows-ai-studio)
         present (code, code-insiders)

    Each step is idempotent: if the tool is already present it is skipped.
    No automatic elevation is attempted. If a step needs admin rights and the
    current shell does not have them, the underlying installer will fail and
    the script exits with that error.

    The script is intentionally modular: every step is its own function and is
    invoked through Invoke-Step. To add retry, version pinning, or extra
    diagnostics later, change Invoke-Step or the individual function.

.NOTES
    Tested on PowerShell 5.1 and 7.x on Windows 10/11.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'  # speeds up Invoke-WebRequest

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

$script:Config = [pscustomobject]@{
    AzCliWingetId           = 'Microsoft.AzureCLI'
    AzdWingetId             = 'microsoft.azd'
    AzdFoundryExtensionId   = 'microsoft.foundry'
    SkillRepo               = 'microsoft/azure-skills'
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
    <#
    .SYNOPSIS
        Run one install step with consistent logging and error handling.
        A failure inside one step does not abort the rest of the script;
        the failure is recorded and surfaced in the final summary.
    #>
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
        Write-Err  ("{0} failed: {1}" -f $Name, $_.Exception.Message)
        $script:Failures += $Name
    }
}

function Invoke-NativeCommand {
    <#
    .SYNOPSIS
        Run a native (non-PS) command and throw on non-zero exit code.
    #>
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
        stderr text (e.g. azd's "Update available:" notice) is NOT treated as
        a terminating PowerShell error. $LASTEXITCODE is preserved.
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

# ---------------------------------------------------------------------------
# Step 1: Azure CLI (winget)
#   Docs: https://learn.microsoft.com/cli/azure/install-azure-cli-windows
# ---------------------------------------------------------------------------

function Install-AzCli {
    if (Test-Command -Name 'az') {
        Write-Skip 'Azure CLI (az) already on PATH.'
        return
    }
    if (-not (Test-Command -Name 'winget')) {
        throw 'winget is not available. Install App Installer from the Microsoft Store, then retry.'
    }

    Write-Info "Installing Azure CLI via winget ($($script:Config.AzCliWingetId))..."
    Invoke-NativeCommand -File 'winget' -Arguments @(
        'install', '--exact',
        '--id', $script:Config.AzCliWingetId,
        '--source', 'winget',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--silent'
    )

    Write-Info 'Azure CLI installed. Open a new terminal so the updated PATH is picked up before running az.'
}

# ---------------------------------------------------------------------------
# Step 2: Azure Developer CLI (winget)
#   Docs: https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd
# ---------------------------------------------------------------------------

function Install-Azd {
    if (Test-Command -Name 'azd') {
        Write-Skip 'azd already on PATH.'
        return
    }
    if (-not (Test-Command -Name 'winget')) {
        throw 'winget is not available. Install App Installer from the Microsoft Store, then retry.'
    }

    Write-Info "Installing azd via winget ($($script:Config.AzdWingetId))..."
    Invoke-NativeCommand -File 'winget' -Arguments @(
        'install',
        '--id', $script:Config.AzdWingetId,
        '--source', 'winget',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--silent'
    )
}

# ---------------------------------------------------------------------------
# Step 3: azd Foundry extension
# ---------------------------------------------------------------------------

function Test-AzdExtensionInstalled {
    param([Parameter(Mandatory)][string] $ExtensionId)

    if (-not (Test-Command -Name 'azd')) { return $false }

    try {
        # --installed restricts output to extensions that are actually
        # installed (without it, the registry of all available extensions is
        # returned and a plain text match would match "Not installed" rows).
        $output = Invoke-NativeOutput -File 'azd' -Arguments @('ext', 'list', '--installed')
        if ($LASTEXITCODE -ne 0) { return $false }
        return ($output -match [regex]::Escape($ExtensionId))
    }
    catch {
        return $false
    }
}

function Install-AzdFoundryExtension {
    if (-not (Test-Command -Name 'azd')) {
        throw 'azd is not on PATH. Open a new terminal after the previous step or install azd manually, then retry.'
    }

    $extId = $script:Config.AzdFoundryExtensionId
    if (Test-AzdExtensionInstalled -ExtensionId $extId) {
        Write-Skip "azd extension '$extId' already installed."
        return
    }

    Write-Info "Installing azd extension '$extId'..."
    Invoke-NativeCommand -File 'azd' -Arguments @('ext', 'install', $extId)
}

# ---------------------------------------------------------------------------
# Step 4: microsoft-foundry skill (from GitHub release tarball)
# ---------------------------------------------------------------------------

function Install-FoundrySkill {
    $skillsRoot = $script:Config.SkillsRoot
    $skillName  = $script:Config.SkillName
    $destDir    = Join-Path $skillsRoot $skillName
    $marker     = Join-Path $destDir 'SKILL.md'

    if (Test-Path -LiteralPath $marker) {
        Write-Skip "Skill '$skillName' already present at $destDir."
        return
    }

    if (-not (Test-Command -Name 'tar')) {
        throw "'tar' is required to extract the skill archive (built in on Windows 10 1803+)."
    }

    # 1. Look up latest release.
    $apiUrl = "https://api.github.com/repos/$($script:Config.SkillRepo)/releases/latest"
    Write-Info "Querying $apiUrl ..."
    $release = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'foundry-prereqs-installer' }
    $tag      = $release.tag_name
    $tarball  = $release.tarball_url
    if (-not $tarball) { throw "Release '$tag' has no tarball_url." }
    Write-Info "Latest release: $tag"

    # 2. Download + extract into a temp directory.
    $tmpRoot   = Join-Path ([System.IO.Path]::GetTempPath()) ("azure-skills-$tag-" + [Guid]::NewGuid().ToString('N'))
    $tarPath   = Join-Path $tmpRoot 'release.tar.gz'
    $extractTo = Join-Path $tmpRoot 'extracted'
    New-Item -ItemType Directory -Path $extractTo -Force | Out-Null

    try {
        Write-Info "Downloading tarball to $tarPath ..."
        Invoke-WebRequest -Uri $tarball -OutFile $tarPath -UseBasicParsing -Headers @{ 'User-Agent' = 'foundry-prereqs-installer' }

        Write-Info "Extracting archive..."
        Invoke-NativeCommand -File 'tar' -Arguments @('-xzf', $tarPath, '-C', $extractTo)

        # 3. Locate skills/<name> inside the (single) top-level folder GitHub creates.
        $topLevel = Get-ChildItem -LiteralPath $extractTo -Directory | Select-Object -First 1
        if (-not $topLevel) { throw 'Archive did not contain a top-level directory.' }
        $sourceSkillDir = Join-Path $topLevel.FullName ("skills\$skillName")
        if (-not (Test-Path -LiteralPath $sourceSkillDir)) {
            throw "Skill folder 'skills/$skillName' not found in archive."
        }

        # 4. Copy into ~/.agents/skills/<name>/.
        if (-not (Test-Path -LiteralPath $skillsRoot)) {
            New-Item -ItemType Directory -Path $skillsRoot -Force | Out-Null
        }
        if (Test-Path -LiteralPath $destDir) {
            Remove-Item -LiteralPath $destDir -Recurse -Force
        }
        Copy-Item -LiteralPath $sourceSkillDir -Destination $destDir -Recurse -Force
        Write-Info "Skill copied to $destDir."
    }
    finally {
        if (Test-Path -LiteralPath $tmpRoot) {
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Step 5: VS Code Foundry Toolkit extension
# ---------------------------------------------------------------------------

function Get-VSCodeVariants {
    return $script:Config.VSCodeVariantCommands | Where-Object { Test-Command -Name $_ }
}

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

function Install-VSCodeFoundryToolkit {
    $extId    = $script:Config.VSCodeExtensionId
    $variants = Get-VSCodeVariants

    if (-not $variants) {
        Write-Warn "Neither 'code' nor 'code-insiders' is on PATH. Skipping VS Code extension install."
        Write-Warn "Tip: in VS Code run 'Shell Command: Install ''code'' command in PATH', then re-run this script."
        return
    }

    foreach ($variant in $variants) {
        if (Test-VSCodeExtensionInstalled -VariantCommand $variant -ExtensionId $extId) {
            Write-Skip "Extension '$extId' already installed in $variant."
            continue
        }
        Write-Info "Installing extension '$extId' into $variant..."
        Invoke-NativeCommand -File $variant -Arguments @('--install-extension', $extId, '--force')
    }
}

# ---------------------------------------------------------------------------
# Verification (warn-only)
# ---------------------------------------------------------------------------

function Invoke-Check {
    param(
        [Parameter(Mandatory)][string]      $Name,
        [Parameter(Mandatory)][scriptblock] $Probe
    )
    try {
        $result = & $Probe
        if ($result) {
            Write-Done "$Name : $result"
        } else {
            Write-Warn "$Name : check returned no value"
        }
    }
    catch {
        Write-Warn "$Name : $($_.Exception.Message)"
    }
}

function Test-Install {
    Write-Step '--- Verification ---'

    Invoke-Check -Name 'az' -Probe {
        if (-not (Test-Command -Name 'az')) { throw 'az not on PATH' }
        (& az version --output tsv 2>$null | Select-Object -First 1)
    }

    Invoke-Check -Name 'azd' -Probe {
        if (-not (Test-Command -Name 'azd')) { throw 'azd not on PATH' }
        (& azd version 2>$null | Select-Object -First 1)
    }

    Invoke-Check -Name "azd ext $($script:Config.AzdFoundryExtensionId)" -Probe {
        if (Test-AzdExtensionInstalled -ExtensionId $script:Config.AzdFoundryExtensionId) {
            return 'installed'
        }
        throw 'not installed'
    }

    Invoke-Check -Name "skill $($script:Config.SkillName)" -Probe {
        $p = Join-Path $script:Config.SkillsRoot (Join-Path $script:Config.SkillName 'SKILL.md')
        if (Test-Path -LiteralPath $p) { return $p }
        throw 'SKILL.md not found'
    }

    foreach ($variant in $script:Config.VSCodeVariantCommands) {
        if (-not (Test-Command -Name $variant)) {
            Write-Warn "VS Code variant '$variant' not on PATH (skipped)."
            continue
        }
        Invoke-Check -Name "$variant : $($script:Config.VSCodeExtensionId)" -Probe {
            if (Test-VSCodeExtensionInstalled -VariantCommand $variant -ExtensionId $script:Config.VSCodeExtensionId) {
                return 'installed'
            }
            throw 'not installed'
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$script:Failures = @()

Write-Info "Microsoft Foundry prerequisite installer (Windows)"
Write-Info "Skills root : $($script:Config.SkillsRoot)"
Write-Info ""

Invoke-Step -Name 'Azure CLI'                          -Action { Install-AzCli }
Invoke-Step -Name 'Azure Developer CLI (azd)'          -Action { Install-Azd }
Invoke-Step -Name 'azd Foundry extension'              -Action { Install-AzdFoundryExtension }
Invoke-Step -Name 'microsoft-foundry skill'            -Action { Install-FoundrySkill }
Invoke-Step -Name 'VS Code Foundry Toolkit extension'  -Action { Install-VSCodeFoundryToolkit }

Test-Install

Write-Info ''
if ($script:Failures.Count -gt 0) {
    Write-Warn ("Completed with {0} failed step(s): {1}" -f $script:Failures.Count, ($script:Failures -join ', '))
    exit 1
} else {
    Write-Done 'All steps completed.'
    exit 0
}
