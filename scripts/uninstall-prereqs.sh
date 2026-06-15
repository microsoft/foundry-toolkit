#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# uninstall-prereqs.sh
#
# Uninstall Microsoft Foundry prerequisites on macOS and Linux (Debian/Ubuntu
# only). Test helper that mirrors install-prereqs.sh so the install script
# can be exercised repeatedly.
#
# Steps (reverse dependency order):
#   1. VS Code Foundry extension       : code --uninstall-extension
#                                        ms-windows-ai-studio.windows-ai-studio
#   2. microsoft-foundry skill         : rm -rf ~/.agents/skills/microsoft-foundry
#   3. azd Foundry extension           : azd ext uninstall microsoft.foundry
#   4. azd
#        - macOS : brew uninstall azd
#        - Linux : curl -fsSL https://aka.ms/uninstall-azd.sh | bash
#   5. Azure CLI
#        - macOS : brew uninstall azure-cli
#        - Linux : sudo apt-get remove -y azure-cli
#
# Design rules:
#   * Each step is its own function (Uninstall_*); main() iterates via
#     run_step.
#   * Idempotent: skips if the tool is already absent.
#   * No automatic privilege escalation. apt-get remove on Linux uses sudo.
#   * Does NOT touch user data such as ~/.azure or ~/.azd.
# -----------------------------------------------------------------------------

set -u
set -o pipefail

# -------------------- Configuration (must match install-prereqs.sh) ----------

AZD_FOUNDRY_EXT_ID="microsoft.foundry"
SKILL_NAME="microsoft-foundry"
SKILLS_ROOT="${HOME}/.agents/skills"
VSCODE_EXTENSION_ID="ms-windows-ai-studio.windows-ai-studio"
VSCODE_VARIANTS=(code code-insiders)

AZD_UNINSTALL_SCRIPT='https://aka.ms/uninstall-azd.sh'

# -------------------- Logging ------------------------------------------------

_log() {
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

log_info() { _log INFO 36 "$@"; }
log_step() { _log STEP 35 "$@"; }
log_skip() { _log SKIP 90 "$@"; }
log_ok()   { _log OK   32 "$@"; }
log_warn() { _log WARN 33 "$@"; }
log_err()  { _log ERR  31 "$@"; }

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

# -------------------- Step 1: VS Code Foundry extension ----------------------

is_vscode_ext_installed() {
    "$1" --list-extensions 2>/dev/null | grep -Fxq "$2"
}

Uninstall_VSCodeFoundryToolkit() {
    local found_variant=0
    for variant in "${VSCODE_VARIANTS[@]}"; do
        if ! has_cmd "$variant"; then continue; fi
        found_variant=1

        if ! is_vscode_ext_installed "$variant" "$VSCODE_EXTENSION_ID"; then
            log_skip "Extension '${VSCODE_EXTENSION_ID}' not installed in ${variant}."
            continue
        fi

        log_info "Uninstalling extension '${VSCODE_EXTENSION_ID}' from ${variant}..."
        if ! "$variant" --uninstall-extension "$VSCODE_EXTENSION_ID"; then
            log_err "Failed to uninstall extension from ${variant}."
            return 1
        fi
    done

    if [ "$found_variant" -eq 0 ]; then
        log_skip "Neither 'code' nor 'code-insiders' is on PATH. Nothing to uninstall."
    fi
}

# -------------------- Step 2: microsoft-foundry skill ------------------------

Uninstall_FoundrySkill() {
    local dest_dir="${SKILLS_ROOT}/${SKILL_NAME}"
    if [ ! -e "$dest_dir" ]; then
        log_skip "Skill '${SKILL_NAME}' not present at ${dest_dir}."
        return 0
    fi
    log_info "Removing ${dest_dir} ..."
    rm -rf "$dest_dir"
}

# -------------------- Step 3: azd Foundry extension --------------------------

is_azd_ext_installed() {
    has_cmd azd || return 1
    # --installed restricts output to extensions that are actually installed.
    azd ext list --installed 2>/dev/null | grep -Fq "$1"
}

Uninstall_AzdFoundryExtension() {
    if ! has_cmd azd; then
        log_skip "azd is not on PATH; skipping extension uninstall."
        return 0
    fi
    if ! is_azd_ext_installed "$AZD_FOUNDRY_EXT_ID"; then
        log_skip "azd extension '${AZD_FOUNDRY_EXT_ID}' not installed."
        return 0
    fi
    log_info "Uninstalling azd extension '${AZD_FOUNDRY_EXT_ID}'..."
    azd ext uninstall "$AZD_FOUNDRY_EXT_ID"
}

# -------------------- Step 4: azd --------------------------------------------

Uninstall_Azd() {
    if ! has_cmd azd; then
        log_skip "azd not on PATH; nothing to do."
        return 0
    fi

    case "$(os_kind)" in
        macos)
            if ! has_cmd brew; then
                log_warn "Homebrew not available; cannot uninstall azd automatically."
                return 0
            fi
            log_info "Uninstalling azd via Homebrew..."
            brew uninstall azd
            ;;
        linux)
            if ! has_cmd curl; then
                log_err "'curl' is required to download the azd uninstaller."
                return 1
            fi
            log_info "Uninstalling azd via ${AZD_UNINSTALL_SCRIPT} ..."
            curl -fsSL "$AZD_UNINSTALL_SCRIPT" | bash
            ;;
        *)
            log_err "Unsupported OS: $(uname -s)"
            return 1
            ;;
    esac
}

# -------------------- Step 5: Azure CLI --------------------------------------

Uninstall_AzCli() {
    if ! has_cmd az; then
        log_skip "az not on PATH; nothing to do."
        return 0
    fi

    case "$(os_kind)" in
        macos)
            if ! has_cmd brew; then
                log_warn "Homebrew not available; cannot uninstall Azure CLI automatically."
                return 0
            fi
            log_info "Uninstalling Azure CLI via Homebrew..."
            brew uninstall azure-cli
            ;;
        linux)
            if ! has_cmd apt-get; then
                log_warn "Non-apt Linux distro detected; this script only uninstalls Azure CLI on Debian/Ubuntu."
                log_warn "See https://learn.microsoft.com/cli/azure/install-azure-cli-linux for manual steps."
                return 0
            fi
            log_info "Uninstalling Azure CLI via apt-get (requires sudo)..."
            sudo apt-get remove -y azure-cli
            ;;
        *)
            log_err "Unsupported OS: $(uname -s)"
            return 1
            ;;
    esac
}

# -------------------- Verification (warn-only) -------------------------------

verify_uninstall() {
    log_step "--- Verification ---"

    for variant in "${VSCODE_VARIANTS[@]}"; do
        if ! has_cmd "$variant"; then continue; fi
        if is_vscode_ext_installed "$variant" "$VSCODE_EXTENSION_ID"; then
            log_warn "${variant} : ${VSCODE_EXTENSION_ID} still installed"
        else
            log_ok   "${variant} : ${VSCODE_EXTENSION_ID} removed"
        fi
    done

    local skill_path="${SKILLS_ROOT}/${SKILL_NAME}"
    if [ -e "$skill_path" ]; then
        log_warn "skill ${SKILL_NAME} still present at ${skill_path}"
    else
        log_ok   "skill ${SKILL_NAME} removed"
    fi

    if is_azd_ext_installed "$AZD_FOUNDRY_EXT_ID"; then
        log_warn "azd ext ${AZD_FOUNDRY_EXT_ID} still installed"
    else
        log_ok   "azd ext ${AZD_FOUNDRY_EXT_ID} removed"
    fi

    if has_cmd azd; then
        log_warn "azd still on PATH (a new shell may be required to refresh PATH)"
    else
        log_ok   "azd removed"
    fi

    if has_cmd az; then
        log_warn "az still on PATH (a new shell may be required to refresh PATH)"
    else
        log_ok   "az removed"
    fi
}

# -------------------- Main ---------------------------------------------------

main() {
    log_info "Microsoft Foundry prerequisite uninstaller ($(os_kind))"
    log_info "Skills root : ${SKILLS_ROOT}"
    log_info ""

    run_step "VS Code Foundry extension"  Uninstall_VSCodeFoundryToolkit
    run_step "microsoft-foundry skill"    Uninstall_FoundrySkill
    run_step "azd Foundry extension"      Uninstall_AzdFoundryExtension
    run_step "Azure Developer CLI (azd)"  Uninstall_Azd
    run_step "Azure CLI"                  Uninstall_AzCli

    verify_uninstall

    log_info ""
    if [ "${#FAILURES[@]}" -gt 0 ]; then
        log_warn "Completed with ${#FAILURES[@]} failed step(s): ${FAILURES[*]}"
        exit 1
    fi
    log_ok "All steps completed."
}

main "$@"
