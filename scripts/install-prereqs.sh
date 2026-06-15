#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# install-prereqs.sh
#
# Installs Microsoft Foundry prerequisites on macOS and Linux (Debian/Ubuntu only).
#
# Steps (in order):
#   1. Azure CLI
#        - macOS : brew update && brew install azure-cli
#        - Linux : curl -fsSL \
#                  'https://azurecliprod.blob.core.windows.net/$root/deb_install.sh' \
#                  | sudo bash    # apt-based distros only
#   2. Azure Developer CLI (azd)
#        - macOS : brew install azure/azd/azd
#        - Linux : curl -fsSL https://aka.ms/install-azd.sh | bash
#   3. azd Foundry extension          : azd ext install microsoft.foundry
#   4. microsoft-foundry skill        : download latest release of
#                                       github.com/microsoft/azure-skills,
#                                       copy skills/microsoft-foundry to
#                                       ~/.agents/skills/microsoft-foundry
#   5. VS Code Foundry Toolkit ext    : code --install-extension
#                                       ms-windows-ai-studio.windows-ai-studio
#                                       (and code-insiders if present)
#
# Design rules:
#   * Each step is its own function (Install_*); main() iterates over them
#     via run_step so retry/version pinning/extra logging can be added in one
#     place later.
#   * Idempotent: skips if the tool is already on PATH.
#   * No automatic privilege escalation: if a step needs sudo and the user is
#     not root, the underlying installer prompts (or fails). On failure the
#     script records it and moves on; the final verification is warn-only.
# -----------------------------------------------------------------------------

set -u                          # error on unset vars
set -o pipefail                 # propagate errors through pipes
# Intentionally NOT `set -e`: we want a single step's failure to be recorded
# and the rest of the steps to still run.

# -------------------- Configuration ------------------------------------------

AZD_FOUNDRY_EXT_ID="microsoft.foundry"
SKILL_REPO="microsoft/azure-skills"
SKILL_NAME="microsoft-foundry"
SKILLS_ROOT="${HOME}/.agents/skills"
VSCODE_EXTENSION_ID="ms-windows-ai-studio.windows-ai-studio"
VSCODE_VARIANTS=(code code-insiders)

AZ_CLI_DEB_INSTALLER='https://azurecliprod.blob.core.windows.net/$root/deb_install.sh'
AZD_INSTALL_SCRIPT='https://aka.ms/install-azd.sh'

# -------------------- Logging ------------------------------------------------

_log() {
    # $1 = level, $2 = colour code, $3.. = message
    local level=$1; shift
    local color=$1; shift
    local stamp
    stamp=$(date +%H:%M:%S)
    if [ -t 1 ]; then
        printf '\033[%sm%s [%-5s]\033[0m %s\n' "$color" "$stamp" "$level" "$*"
    else
        printf '%s [%-5s] %s\n' "$stamp" "$level" "$*"
    fi
}

log_info() { _log INFO 36 "$@"; }   # cyan
log_step() { _log STEP 35 "$@"; }   # magenta
log_skip() { _log SKIP 90 "$@"; }   # bright black
log_ok()   { _log OK   32 "$@"; }   # green
log_warn() { _log WARN 33 "$@"; }   # yellow
log_err()  { _log ERR  31 "$@"; }   # red

# -------------------- Utilities ----------------------------------------------

FAILURES=()

has_cmd() { command -v "$1" >/dev/null 2>&1; }

os_kind() {
    case "$(uname -s)" in
        Darwin*) echo macos ;;
        Linux*)  echo linux ;;
        *)       echo unknown ;;
    esac
}

run_step() {
    # $1 = friendly name, $2 = function to call
    local name=$1
    local fn=$2

    log_step "--- ${name} ---"
    if "$fn"; then
        log_ok "${name}"
    else
        log_err "${name} failed (see output above)."
        FAILURES+=("${name}")
    fi
}

# -------------------- Step 1: Azure CLI --------------------------------------
# Docs:
#   macOS : https://learn.microsoft.com/cli/azure/install-azure-cli-macos
#   Linux : https://learn.microsoft.com/cli/azure/install-azure-cli-linux

Install_AzCli() {
    if has_cmd az; then
        log_skip "Azure CLI (az) already on PATH."
        return 0
    fi

    case "$(os_kind)" in
        macos)
            if ! has_cmd brew; then
                log_err "Homebrew is required on macOS. Install from https://brew.sh/ and retry."
                return 1
            fi
            log_info "Installing Azure CLI via Homebrew..."
            brew update && brew install azure-cli
            ;;
        linux)
            if ! has_cmd apt-get; then
                log_err "This script only installs Azure CLI on Debian/Ubuntu (apt-based) Linux."
                log_err "For other distros see https://learn.microsoft.com/cli/azure/install-azure-cli-linux"
                return 1
            fi
            if ! has_cmd curl; then
                log_err "'curl' is required to download the Azure CLI installer."
                return 1
            fi
            log_info "Installing Azure CLI via official deb_install.sh (requires sudo)..."
            # shellcheck disable=SC2016  # $root is literal in the URL
            curl -fsSL "$AZ_CLI_DEB_INSTALLER" | sudo bash
            ;;
        *)
            log_err "Unsupported OS: $(uname -s)"
            return 1
            ;;
    esac
}

# -------------------- Step 2: Azure Developer CLI ----------------------------
# Docs: https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd

Install_Azd() {
    if has_cmd azd; then
        log_skip "azd already on PATH."
        return 0
    fi

    case "$(os_kind)" in
        macos)
            if ! has_cmd brew; then
                log_err "Homebrew is required on macOS. Install from https://brew.sh/ and retry."
                return 1
            fi
            if [ "$(uname -m)" = "arm64" ] && ! /usr/bin/pgrep -q oahd 2>/dev/null; then
                log_warn "Apple Silicon detected. azd requires Rosetta 2."
                log_warn "If azd fails to start, run: softwareupdate --install-rosetta"
            fi
            log_info "Installing azd via Homebrew (azure/azd/azd)..."
            brew install azure/azd/azd
            ;;
        linux)
            if ! has_cmd curl; then
                log_err "'curl' is required to download the azd installer."
                return 1
            fi
            log_info "Installing azd via $AZD_INSTALL_SCRIPT ..."
            curl -fsSL "$AZD_INSTALL_SCRIPT" | bash
            ;;
        *)
            log_err "Unsupported OS: $(uname -s)"
            return 1
            ;;
    esac
}

# -------------------- Step 3: azd Foundry extension --------------------------

is_azd_ext_installed() {
    # $1 = extension id
    has_cmd azd || return 1
    # --installed restricts output to extensions that are actually installed
    # (without it the full registry is returned and a plain grep would match
    # "Not installed" rows).
    azd ext list --installed 2>/dev/null | grep -Fq "$1"
}

Install_AzdFoundryExtension() {
    if ! has_cmd azd; then
        log_err "azd is not on PATH. Open a new shell after the previous step or install azd manually."
        return 1
    fi
    if is_azd_ext_installed "$AZD_FOUNDRY_EXT_ID"; then
        log_skip "azd extension '$AZD_FOUNDRY_EXT_ID' already installed."
        return 0
    fi
    log_info "Installing azd extension '$AZD_FOUNDRY_EXT_ID'..."
    azd ext install "$AZD_FOUNDRY_EXT_ID"
}

# -------------------- Step 4: microsoft-foundry skill ------------------------

Install_FoundrySkill() {
    local dest_dir="${SKILLS_ROOT}/${SKILL_NAME}"
    local marker="${dest_dir}/SKILL.md"

    if [ -f "$marker" ]; then
        log_skip "Skill '${SKILL_NAME}' already present at ${dest_dir}."
        return 0
    fi
    if ! has_cmd curl; then log_err "'curl' is required."; return 1; fi
    if ! has_cmd tar;  then log_err "'tar' is required.";  return 1; fi

    local api_url="https://api.github.com/repos/${SKILL_REPO}/releases/latest"
    log_info "Querying ${api_url} ..."
    local release_json
    if ! release_json=$(curl -fsSL -H 'User-Agent: foundry-prereqs-installer' "$api_url"); then
        log_err "Failed to query GitHub API."
        return 1
    fi

    # Extract tarball_url without requiring jq. Match the first occurrence of
    # the field; the value is a URL with no embedded quotes.
    local tarball
    tarball=$(printf '%s' "$release_json" \
        | grep -oE '"tarball_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -n1 \
        | sed -E 's/.*"tarball_url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    if [ -z "${tarball}" ]; then
        log_err "Could not find tarball_url in GitHub release JSON."
        return 1
    fi
    log_info "Latest release tarball: ${tarball}"

    local tmp_root tar_path extract_to
    tmp_root=$(mktemp -d -t azure-skills.XXXXXX)
    tar_path="${tmp_root}/release.tar.gz"
    extract_to="${tmp_root}/extracted"
    mkdir -p "$extract_to"
    # Cleanup on function exit. Double-quote so $tmp_root is expanded NOW
    # (at trap install time, while the variable is still in scope) instead of
    # at trap fire time (after the function returns, when the local has gone
    # out of scope and `set -u` would treat it as an unbound variable).
    # mktemp -d paths never contain single quotes, so simple ' ' wrapping
    # is safe.
    trap "rm -rf -- '$tmp_root'" RETURN

    log_info "Downloading tarball to ${tar_path} ..."
    if ! curl -fsSL -H 'User-Agent: foundry-prereqs-installer' -o "$tar_path" "$tarball"; then
        log_err "Failed to download tarball."
        return 1
    fi

    log_info "Extracting archive..."
    if ! tar -xzf "$tar_path" -C "$extract_to"; then
        log_err "Failed to extract tarball."
        return 1
    fi

    # GitHub tarballs contain a single top-level directory like
    # microsoft-azure-skills-<sha>/. Find it generically.
    local top_level
    top_level=$(find "$extract_to" -mindepth 1 -maxdepth 1 -type d | head -n1)
    if [ -z "$top_level" ] || [ ! -d "$top_level" ]; then
        log_err "Archive did not contain a top-level directory."
        return 1
    fi
    local source_skill_dir="${top_level}/skills/${SKILL_NAME}"
    if [ ! -d "$source_skill_dir" ]; then
        log_err "Skill folder 'skills/${SKILL_NAME}' not found in archive."
        return 1
    fi

    mkdir -p "$SKILLS_ROOT"
    rm -rf "$dest_dir"
    cp -R "$source_skill_dir" "$dest_dir"
    log_info "Skill copied to ${dest_dir}."
}

# -------------------- Step 5: VS Code Foundry Toolkit extension --------------

is_vscode_ext_installed() {
    # $1 = variant command, $2 = extension id
    "$1" --list-extensions 2>/dev/null | grep -Fxq "$2"
}

Install_VSCodeFoundryToolkit() {
    local installed_any=0
    local found_variant=0

    for variant in "${VSCODE_VARIANTS[@]}"; do
        if ! has_cmd "$variant"; then continue; fi
        found_variant=1

        if is_vscode_ext_installed "$variant" "$VSCODE_EXTENSION_ID"; then
            log_skip "Extension '${VSCODE_EXTENSION_ID}' already installed in ${variant}."
            installed_any=1
            continue
        fi

        log_info "Installing extension '${VSCODE_EXTENSION_ID}' into ${variant}..."
        if "$variant" --install-extension "$VSCODE_EXTENSION_ID" --force; then
            installed_any=1
        else
            log_err "Failed to install extension into ${variant}."
            return 1
        fi
    done

    if [ "$found_variant" -eq 0 ]; then
        log_warn "Neither 'code' nor 'code-insiders' is on PATH. Skipping VS Code extension install."
        log_warn "Tip: in VS Code run 'Shell Command: Install \"code\" command in PATH', then re-run this script."
        return 0
    fi

    if [ "$installed_any" -eq 0 ]; then
        return 1
    fi
}

# -------------------- Verification (warn-only) -------------------------------

check() {
    # $1 = name, $2.. = command to run
    local name=$1; shift
    local output
    if output=$("$@" 2>&1); then
        # Trim to first line for log readability.
        output=$(printf '%s' "$output" | head -n1)
        log_ok "${name} : ${output}"
    else
        log_warn "${name} : check failed"
    fi
}

verify_install() {
    log_step "--- Verification ---"

    if has_cmd az;  then check "az"  az version --output tsv;
    else log_warn "az not on PATH."; fi

    if has_cmd azd; then check "azd" azd version;
    else log_warn "azd not on PATH."; fi

    if is_azd_ext_installed "$AZD_FOUNDRY_EXT_ID"; then
        log_ok   "azd ext ${AZD_FOUNDRY_EXT_ID} : installed"
    else
        log_warn "azd ext ${AZD_FOUNDRY_EXT_ID} : not installed"
    fi

    local skill_marker="${SKILLS_ROOT}/${SKILL_NAME}/SKILL.md"
    if [ -f "$skill_marker" ]; then
        log_ok   "skill ${SKILL_NAME} : ${skill_marker}"
    else
        log_warn "skill ${SKILL_NAME} : SKILL.md not found at ${skill_marker}"
    fi

    for variant in "${VSCODE_VARIANTS[@]}"; do
        if ! has_cmd "$variant"; then
            log_warn "VS Code variant '${variant}' not on PATH (skipped)."
            continue
        fi
        if is_vscode_ext_installed "$variant" "$VSCODE_EXTENSION_ID"; then
            log_ok   "${variant} : ${VSCODE_EXTENSION_ID} installed"
        else
            log_warn "${variant} : ${VSCODE_EXTENSION_ID} not installed"
        fi
    done
}

# -------------------- Main ---------------------------------------------------

main() {
    log_info "Microsoft Foundry prerequisite installer ($(os_kind))"
    log_info "Skills root : ${SKILLS_ROOT}"
    log_info ""

    run_step "Azure CLI"                         Install_AzCli
    run_step "Azure Developer CLI (azd)"         Install_Azd
    run_step "azd Foundry extension"             Install_AzdFoundryExtension
    run_step "microsoft-foundry skill"           Install_FoundrySkill
    run_step "VS Code Foundry Toolkit extension" Install_VSCodeFoundryToolkit

    verify_install

    log_info ""
    if [ "${#FAILURES[@]}" -gt 0 ]; then
        log_warn "Completed with ${#FAILURES[@]} failed step(s): ${FAILURES[*]}"
        exit 1
    fi
    log_ok "All steps completed."
}

main "$@"
