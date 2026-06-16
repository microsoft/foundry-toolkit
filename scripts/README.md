# Microsoft Foundry prerequisite scripts

Helper scripts to install everything you need to build with Microsoft Foundry:
Azure CLI, Azure Developer CLI (`azd`), the `azd` Foundry extension, the
`microsoft-foundry` agent skill, and the VS Code Microsoft Foundry extension.

## Files

| Script | Platform |
| --- | --- |
| [install-prereqs.ps1](https://github.com/microsoft/foundry-toolkit/blob/quickinstall/scripts/install-prereqs.ps1) | Windows |
| [install-prereqs.sh](https://github.com/microsoft/foundry-toolkit/blob/quickinstall/scripts/install-prereqs.sh) | macOS, Debian/Ubuntu |

## Usage

Run directly with the official aka.ms shortlinks:

Windows (PowerShell):

```powershell
iex (irm https://aka.ms/foundry-devpack-install.ps1)
```

macOS / Linux (bash):

```bash
curl -fsSL https://aka.ms/foundry-devpack-install.sh | bash
```

Or, if you've cloned the repo, run the local copy:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-prereqs.ps1
```

```bash
chmod +x ./scripts/install-prereqs.sh
./scripts/install-prereqs.sh
```

## What gets installed

1. **Azure CLI** — `winget Microsoft.AzureCLI` · `brew install azure-cli` · `curl … deb_install.sh | sudo bash` (Debian/Ubuntu only)
2. **Azure Developer CLI (`azd`)** — `winget microsoft.azd` · `brew install azure/azd/azd` · `curl https://aka.ms/install-azd.sh | bash`
3. **`azd` Foundry extension** — `azd ext install microsoft.foundry`
4. **`microsoft-foundry` skill** — latest release from [`microsoft/azure-skills`](https://github.com/microsoft/azure-skills) copied to `~/.agents/skills/microsoft-foundry/`
5. **VS Code Microsoft Foundry extension** — `ms-windows-ai-studio.windows-ai-studio` installed into every variant on `PATH` (`code`, `code-insiders`)

Each step is idempotent: it is skipped if the tool is already present, so the
install script is safe to re-run.

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

---

<details>
<summary><b>Maintainers: uninstall scripts (testing only)</b></summary>

[uninstall-prereqs.ps1](https://github.com/microsoft/foundry-toolkit/blob/quickinstall/scripts/uninstall-prereqs.ps1)
and [uninstall-prereqs.sh](https://github.com/microsoft/foundry-toolkit/blob/quickinstall/scripts/uninstall-prereqs.sh)
exist solely so the install scripts can be exercised repeatedly during
development. They are not intended for end users and intentionally do not
remove user data (`~/.azure`, `~/.azd`, etc.).

Typical dev loop:

```bash
./scripts/install-prereqs.sh    # install
# ...test...
./scripts/uninstall-prereqs.sh  # tear down
./scripts/install-prereqs.sh    # reinstall from a clean state
```

On Windows the Azure CLI uninstall step requires an elevated shell; if `az` or
`azd` still appears on `PATH` immediately after uninstall, open a new terminal
so the shell refreshes `PATH`.

</details>
