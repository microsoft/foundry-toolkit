# Microsoft Foundry prerequisite scripts

Helper scripts to install (or remove) everything you need to build with
Microsoft Foundry: Azure CLI, Azure Developer CLI (`azd`), the `azd` Foundry
extension, the `microsoft-foundry` agent skill, and the VS Code Microsoft
Foundry extension.

## Files

| Script | Platform | Purpose |
| --- | --- | --- |
| [install-prereqs.ps1](https://github.com/microsoft/foundry-toolkit/blob/quickinstall/scripts/install-prereqs.ps1) | Windows | Install everything |
| [install-prereqs.sh](https://github.com/microsoft/foundry-toolkit/blob/quickinstall/scripts/install-prereqs.sh) | macOS, Debian/Ubuntu | Install everything |
| [uninstall-prereqs.ps1](https://github.com/microsoft/foundry-toolkit/blob/quickinstall/scripts/uninstall-prereqs.ps1) | Windows | Remove everything (test helper) |
| [uninstall-prereqs.sh](https://github.com/microsoft/foundry-toolkit/blob/quickinstall/scripts/uninstall-prereqs.sh) | macOS, Debian/Ubuntu | Remove everything (test helper) |

## Usage

Run directly from the repo without cloning:

Windows (PowerShell):

```powershell
iex (irm https://raw.githubusercontent.com/microsoft/foundry-toolkit/quickinstall/scripts/install-prereqs.ps1)
iex (irm https://raw.githubusercontent.com/microsoft/foundry-toolkit/quickinstall/scripts/uninstall-prereqs.ps1)
```

macOS / Linux (bash):

```bash
curl -fsSL https://raw.githubusercontent.com/microsoft/foundry-toolkit/quickinstall/scripts/install-prereqs.sh | bash
curl -fsSL https://raw.githubusercontent.com/microsoft/foundry-toolkit/quickinstall/scripts/uninstall-prereqs.sh | bash
```

Or, if you've cloned the repo, run the local copies:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-prereqs.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-prereqs.ps1
```

```bash
chmod +x ./scripts/install-prereqs.sh ./scripts/uninstall-prereqs.sh
./scripts/install-prereqs.sh
./scripts/uninstall-prereqs.sh
```

## What gets installed

1. **Azure CLI** — `winget Microsoft.AzureCLI` · `brew install azure-cli` · `curl … deb_install.sh | sudo bash` (Debian/Ubuntu only)
2. **Azure Developer CLI (`azd`)** — `winget microsoft.azd` · `brew install azure/azd/azd` · `curl https://aka.ms/install-azd.sh | bash`
3. **`azd` Foundry extension** — `azd ext install microsoft.foundry`
4. **`microsoft-foundry` skill** — latest release from [`microsoft/azure-skills`](https://github.com/microsoft/azure-skills) copied to `~/.agents/skills/microsoft-foundry/`
5. **VS Code Microsoft Foundry extension** — `ms-windows-ai-studio.windows-ai-studio` installed into every variant on `PATH` (`code`, `code-insiders`)

Each step is idempotent: it is skipped if the tool is already present, so the
install script is safe to re-run. The uninstall scripts are the inverse —
also idempotent — so install → uninstall → install cycles work for testing.

## Behaviour & limitations

- **No automatic elevation.** If a command needs admin/sudo and the shell
  doesn't have it, the underlying installer fails and the script records it.
- **Linux support is apt-based only** (Debian/Ubuntu) for Azure CLI. Other
  distros: see the [official Azure CLI Linux install doc](https://learn.microsoft.com/cli/azure/install-azure-cli-linux).
- **macOS prerequisites:** [Homebrew](https://brew.sh/). On Apple Silicon,
  `azd` requires Rosetta 2 (`softwareupdate --install-rosetta`) — the script
  warns but does not auto-install it.
- **Windows prerequisite:** `winget` (App Installer), default on Windows 11
  and modern Windows 10.
- **VS Code step** is skipped if neither `code` nor `code-insiders` is on
  `PATH`. Enable via VS Code → command palette → `Shell Command: Install 'code' command in PATH`.
- A single step's failure does **not** abort the rest; the final summary lists
  failures and the script exits non-zero only if at least one step failed.
- Uninstall scripts do **not** remove user data (`~/.azure`, `~/.azd`, etc.).

## Re-running for development

The intended dev loop:

```bash
./scripts/install-prereqs.sh    # install
# ...test...
./scripts/uninstall-prereqs.sh  # tear down
./scripts/install-prereqs.sh    # reinstall from a clean state
```

If `az` or `azd` still appears on `PATH` immediately after uninstall, open a
new terminal — the shell needs to refresh `PATH` from the registry / shell
profile.
