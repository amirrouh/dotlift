#!/usr/bin/env bash
# ============================================================================
#  bash2zsh — Migrate any Linux machine from bash to a fully configured zsh
#
#  Reads config.yaml for your preferences (theme, plugins, tools, aliases,
#  exports) and sets everything up automatically.
#
#  Usage:
#    bash setup.sh                       # auto-install from config.yaml
#    bash setup.sh --interactive         # prompt before each step
#    bash setup.sh --config my.yaml      # use a custom config file
#    bash setup.sh --help
#
#  Supports: Ubuntu/Debian, Fedora/RHEL, Arch, openSUSE, Alpine
# ============================================================================
set -uo pipefail

SCRIPT_VERSION="3.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"
INTERACTIVE=false
BACKUP_DIR="$HOME/.bash2zsh-backup/$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/tmp/bash2zsh-$(date +%Y%m%d_%H%M%S).log"
PKG_MANAGER=""
DISTRO=""
NEEDS_SUDO=""

# Temp files for bashrc migration
BASH_ALIASES_FILE=""
BASH_EXPORTS_FILE=""

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }
step()    { echo -e "\n${MAGENTA}${BOLD}>>> $*${NC}"; }
dim()     { echo -e "${DIM}$*${NC}"; }

confirm() {
    if ! $INTERACTIVE; then return 0; fi
    local msg="${1:-Continue?}"
    echo -en "${CYAN}[?]${NC}  ${msg} ${DIM}[Y/n]${NC} "
    read -r reply
    [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

command_exists() { command -v "$1" &>/dev/null; }

# ═════════════════════════════════════════════════════════════════════════════
# YAML Parser — reads config.yaml without external dependencies
# ═════════════════════════════════════════════════════════════════════════════

# Get a simple key: value (top-level scalar)
# Usage: cfg_get "theme"  ->  "robbyrussell"
cfg_get() {
    local key="$1"
    sed -n "s/^${key}:[[:space:]]*\(.*\)/\1/p" "$CONFIG_FILE" | head -1 | sed 's/[[:space:]]*$//' | sed 's/^"//' | sed 's/"$//'
}

# Get a list under a key (lines starting with "  - ")
# Usage: cfg_list "plugins"  ->  one item per line
cfg_list() {
    local key="$1"
    local in_section=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        if [[ "$line" =~ ^${key}: ]]; then
            in_section=true
            continue
        fi

        if $in_section; then
            # End of section: non-indented line that isn't a list item
            if [[ ! "$line" =~ ^[[:space:]] ]]; then
                break
            fi
            # List item: "  - value"
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(.*) ]]; then
                echo "${BASH_REMATCH[1]}" | sed 's/[[:space:]]*$//'
            fi
        fi
    done < "$CONFIG_FILE"
}

# Get a map under a key (lines like "  name: value")
# Usage: cfg_map "aliases"  ->  "name=value" per line
cfg_map() {
    local key="$1"
    local in_section=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        if [[ "$line" =~ ^${key}: ]]; then
            in_section=true
            continue
        fi

        if $in_section; then
            if [[ ! "$line" =~ ^[[:space:]] ]]; then
                break
            fi
            # Skip list items (  - xxx)
            [[ "$line" =~ ^[[:space:]]*- ]] && continue
            # Map entry: "  key: value"
            if [[ "$line" =~ ^[[:space:]]+([^:]+):[[:space:]]+(.*) ]]; then
                local k="${BASH_REMATCH[1]}"
                local v="${BASH_REMATCH[2]}"
                # Strip quotes
                v=$(echo "$v" | sed 's/^"//;s/"$//;s/^'\''//;s/'\''$//')
                echo "${k}=${v}"
            fi
        fi
    done < "$CONFIG_FILE"
}

# Get a tool flag: cfg_tool "fzf" -> "true" or "false"
cfg_tool() {
    local tool="$1"
    cfg_map "tools" | grep "^${tool}=" | head -1 | cut -d= -f2 | tr -d '[:space:]'
}

# Get multi-line block under a key (for extra_zshrc)
cfg_block() {
    local key="$1"
    local in_block=false
    local found_pipe=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^${key}:[[:space:]]*\| ]]; then
            in_block=true
            found_pipe=true
            continue
        fi

        if $in_block; then
            # End on non-indented, non-empty line
            if [[ ! "$line" =~ ^[[:space:]] ]] && [[ -n "${line// /}" ]]; then
                break
            fi
            # Remove exactly 2 leading spaces
            echo "${line#  }"
        fi
    done < "$CONFIG_FILE"
}

# ═════════════════════════════════════════════════════════════════════════════
# Parse CLI args
# ═════════════════════════════════════════════════════════════════════════════
while [[ $# -gt 0 ]]; do
    case "$1" in
        --interactive|-i) INTERACTIVE=true; shift ;;
        --config|-c) CONFIG_FILE="$2"; shift 2 ;;
        --help|-h)
            echo "bash2zsh v${SCRIPT_VERSION} — Migrate bash to a fully configured zsh"
            echo ""
            echo "Usage: bash setup.sh [options]"
            echo ""
            echo "Options:"
            echo "  --interactive, -i     Prompt before each step"
            echo "  --config, -c FILE     Use a custom config file (default: config.yaml)"
            echo "  --help, -h            Show this help"
            echo ""
            echo "Edit config.yaml to set your theme, plugins, tools, aliases, and exports."
            exit 0
            ;;
        *) warn "Unknown option: $1"; shift ;;
    esac
done

# ═════════════════════════════════════════════════════════════════════════════
# System detection
# ═════════════════════════════════════════════════════════════════════════════
detect_system() {
    step "Detecting system"

    if [[ "$(uname)" == "Darwin" ]]; then
        error "This script is designed for Linux. You're already on macOS!"
        exit 1
    fi

    if [[ ! -f /etc/os-release ]]; then
        error "Cannot detect Linux distribution"
        exit 1
    fi

    source /etc/os-release
    DISTRO="${ID:-unknown}"

    if   command_exists apt-get; then PKG_MANAGER="apt"
    elif command_exists dnf;     then PKG_MANAGER="dnf"
    elif command_exists pacman;  then PKG_MANAGER="pacman"
    elif command_exists zypper;  then PKG_MANAGER="zypper"
    elif command_exists apk;     then PKG_MANAGER="apk"
    else error "No supported package manager found"; exit 1
    fi

    if [[ $EUID -ne 0 ]]; then
        if command_exists sudo; then
            NEEDS_SUDO="sudo"
        else
            warn "Not root and sudo not found. Package installs may fail."
            NEEDS_SUDO=""
        fi
    fi

    success "Distro: ${PRETTY_NAME:-$DISTRO}"
    success "Package manager: ${PKG_MANAGER}"
    info "Config: ${CONFIG_FILE}"
    info "Log: ${LOG_FILE}"

    if [[ -n "$NEEDS_SUDO" ]]; then
        info "Requesting sudo access..."
        sudo -v || { error "Failed to get sudo."; }
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# Package helpers
# ═════════════════════════════════════════════════════════════════════════════
pkg_update() {
    info "Updating package index..."
    local rc=0
    case "$PKG_MANAGER" in
        apt)    $NEEDS_SUDO apt-get update -qq >> "$LOG_FILE" 2>&1 || rc=$? ;;
        dnf)    $NEEDS_SUDO dnf check-update -q >> "$LOG_FILE" 2>&1 || true ;;
        pacman) $NEEDS_SUDO pacman -Sy --noconfirm >> "$LOG_FILE" 2>&1 || rc=$? ;;
        zypper) $NEEDS_SUDO zypper refresh -q >> "$LOG_FILE" 2>&1 || rc=$? ;;
        apk)    $NEEDS_SUDO apk update >> "$LOG_FILE" 2>&1 || rc=$? ;;
    esac
    [[ $rc -ne 0 ]] && warn "Package update failed (code $rc), check $LOG_FILE" || success "Package index updated"
}

pkg_install() {
    local name="$1"
    local pkg_apt="${2:-$1}"
    local pkg_dnf="${3:-$pkg_apt}" pkg_pacman="${4:-$pkg_apt}" pkg_zypper="${5:-$pkg_apt}" pkg_apk="${6:-$pkg_apt}"
    local pkg=""
    case "$PKG_MANAGER" in
        apt) pkg="$pkg_apt" ;; dnf) pkg="$pkg_dnf" ;; pacman) pkg="$pkg_pacman" ;;
        zypper) pkg="$pkg_zypper" ;; apk) pkg="$pkg_apk" ;;
    esac
    [[ -z "$pkg" || "$pkg" == "SKIP" ]] && { warn "'$name' unavailable on $PKG_MANAGER"; return 1; }
    info "Installing $name..."
    local rc=0
    case "$PKG_MANAGER" in
        apt)    $NEEDS_SUDO apt-get install -y -qq "$pkg" >> "$LOG_FILE" 2>&1 || rc=$? ;;
        dnf)    $NEEDS_SUDO dnf install -y -q "$pkg" >> "$LOG_FILE" 2>&1 || rc=$? ;;
        pacman) $NEEDS_SUDO pacman -S --noconfirm --needed "$pkg" >> "$LOG_FILE" 2>&1 || rc=$? ;;
        zypper) $NEEDS_SUDO zypper install -y -q "$pkg" >> "$LOG_FILE" 2>&1 || rc=$? ;;
        apk)    $NEEDS_SUDO apk add "$pkg" >> "$LOG_FILE" 2>&1 || rc=$? ;;
    esac
    [[ $rc -ne 0 ]] && { warn "Failed to install '$name' (code $rc)"; return 1; }
}

# ═════════════════════════════════════════════════════════════════════════════
# Backup
# ═════════════════════════════════════════════════════════════════════════════
backup_configs() {
    step "Backing up existing configs"
    mkdir -p "$BACKUP_DIR"
    local n=0
    for f in .bashrc .bash_profile .bash_aliases .profile .zshrc .zshenv .zprofile; do
        if [[ -f "$HOME/$f" ]]; then
            cp "$HOME/$f" "$BACKUP_DIR/$f"
            dim "  ~/$f"
            n=$((n + 1))
        fi
    done
    [[ -d "$HOME/.oh-my-zsh/custom" ]] && {
        cp -r "$HOME/.oh-my-zsh/custom" "$BACKUP_DIR/omz-custom" 2>/dev/null || true
        n=$((n + 1))
    }
    success "Backed up $n items to $BACKUP_DIR"
}

# ═════════════════════════════════════════════════════════════════════════════
# Install zsh + set as default shell
# ═════════════════════════════════════════════════════════════════════════════
install_zsh() {
    step "Setting up zsh"
    if command_exists zsh; then
        success "zsh already installed: $(zsh --version)"
    else
        pkg_install "zsh"
        success "zsh installed: $(zsh --version)"
    fi

    local zsh_path
    zsh_path="$(command -v zsh)"
    grep -qF "$zsh_path" /etc/shells 2>/dev/null || {
        echo "$zsh_path" | $NEEDS_SUDO tee -a /etc/shells >> "$LOG_FILE" 2>&1
    }

    local current_shell
    current_shell="$(getent passwd "$USER" 2>/dev/null | cut -d: -f7 || echo "$SHELL")"
    if [[ "$current_shell" != *"zsh"* ]]; then
        if confirm "Change default shell to zsh?"; then
            $NEEDS_SUDO chsh -s "$zsh_path" "$USER" 2>> "$LOG_FILE" || \
                warn "Could not change shell. Run manually: chsh -s $zsh_path"
            success "Default shell set to zsh"
        fi
    else
        success "zsh is already the default shell"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# Oh My Zsh
# ═════════════════════════════════════════════════════════════════════════════
install_oh_my_zsh() {
    step "Setting up Oh My Zsh"
    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        success "Oh My Zsh already installed"
    else
        info "Installing Oh My Zsh..."
        RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
            >> "$LOG_FILE" 2>&1
        success "Oh My Zsh installed"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# Custom plugins (from config.yaml custom_plugins section)
# ═════════════════════════════════════════════════════════════════════════════
install_custom_plugins() {
    step "Installing custom Oh My Zsh plugins"
    local custom_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

    cfg_map "custom_plugins" | while IFS='=' read -r name url; do
        [[ -z "$name" || -z "$url" ]] && continue
        if [[ -d "$custom_dir/plugins/$name" ]]; then
            success "$name already installed"
        else
            info "Installing $name..."
            git clone --depth=1 "$url" "$custom_dir/plugins/$name" >> "$LOG_FILE" 2>&1
            success "$name installed"
        fi
    done
}

# ═════════════════════════════════════════════════════════════════════════════
# Theme
# ═════════════════════════════════════════════════════════════════════════════
install_theme() {
    step "Setting up theme"
    local theme
    theme=$(cfg_get "theme")
    theme="${theme:-robbyrussell}"

    if [[ "$theme" == "powerlevel10k" ]]; then
        local p10k_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
        if [[ -d "$p10k_dir" ]]; then
            success "Powerlevel10k already installed"
        else
            info "Installing Powerlevel10k..."
            git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$p10k_dir" >> "$LOG_FILE" 2>&1
            success "Powerlevel10k installed"
        fi
        info "Run 'p10k configure' after setup to customize your prompt"
    else
        # Check if it's a built-in theme
        if [[ -f "$HOME/.oh-my-zsh/themes/${theme}.zsh-theme" ]]; then
            success "Using built-in theme: $theme"
        else
            warn "Theme '$theme' not found in oh-my-zsh. It may still work if installed separately."
        fi
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# CLI tools (reads tools section from config.yaml)
# ═════════════════════════════════════════════════════════════════════════════
install_cli_tools() {
    step "Installing CLI tools"
    local n=0

    # Core deps
    case "$PKG_MANAGER" in
        apt)    $NEEDS_SUDO apt-get install -y -qq curl git wget unzip >> "$LOG_FILE" 2>&1 || true ;;
        dnf)    $NEEDS_SUDO dnf install -y -q curl git wget unzip >> "$LOG_FILE" 2>&1 || true ;;
        pacman) $NEEDS_SUDO pacman -S --noconfirm --needed curl git wget unzip >> "$LOG_FILE" 2>&1 || true ;;
        zypper) $NEEDS_SUDO zypper install -y -q curl git wget unzip >> "$LOG_FILE" 2>&1 || true ;;
        apk)    $NEEDS_SUDO apk add curl git wget unzip >> "$LOG_FILE" 2>&1 || true ;;
    esac

    # fzf
    if [[ "$(cfg_tool fzf)" == "true" ]]; then
        if command_exists fzf; then success "fzf already installed"
        elif confirm "Install fzf?"; then
            [[ -d "$HOME/.fzf" ]] && rm -rf "$HOME/.fzf"
            git clone --depth 1 https://github.com/junegunn/fzf.git "$HOME/.fzf" >> "$LOG_FILE" 2>&1
            "$HOME/.fzf/install" --all --no-bash --no-fish >> "$LOG_FILE" 2>&1
            success "fzf installed"; n=$((n+1))
        fi
    fi

    # fd
    if [[ "$(cfg_tool fd)" == "true" ]]; then
        if command_exists fd || command_exists fdfind; then success "fd already installed"
        elif confirm "Install fd?"; then
            if ! pkg_install "fd" "fd-find" "fd-find" "fd" "fd" "fd"; then
                local ver arch
                ver=$(curl -fsSL "https://api.github.com/repos/sharkdp/fd/releases/latest" | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
                arch=$(uname -m); [[ "$arch" == "aarch64" ]] || arch="x86_64"
                curl -fsSL "https://github.com/sharkdp/fd/releases/download/v${ver}/fd-v${ver}-${arch}-unknown-linux-gnu.tar.gz" \
                    | tar xz -C /tmp >> "$LOG_FILE" 2>&1
                $NEEDS_SUDO cp "/tmp/fd-v${ver}-${arch}-unknown-linux-gnu/fd" /usr/local/bin/ 2>> "$LOG_FILE"
                rm -rf "/tmp/fd-v${ver}-${arch}-unknown-linux-gnu"
            fi
            command_exists fdfind && ! command_exists fd && {
                mkdir -p "$HOME/.local/bin"; ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
            }
            success "fd installed"; n=$((n+1))
        fi
    fi

    # ripgrep
    if [[ "$(cfg_tool ripgrep)" == "true" ]]; then
        if command_exists rg; then success "ripgrep already installed"
        elif confirm "Install ripgrep?"; then
            pkg_install "ripgrep" "ripgrep" "ripgrep" "ripgrep" "ripgrep" "ripgrep"
            success "ripgrep installed"; n=$((n+1))
        fi
    fi

    # eza
    if [[ "$(cfg_tool eza)" == "true" ]]; then
        if command_exists eza; then success "eza already installed"
        elif confirm "Install eza?"; then
            case "$PKG_MANAGER" in
                apt)    pkg_install "eza" "eza" "" "" "" "" || install_eza_from_github ;;
                pacman) pkg_install "eza" "" "" "eza" "" "" ;;
                dnf)    pkg_install "eza" "" "eza" "" "" "" || install_eza_from_github ;;
                *)      install_eza_from_github ;;
            esac
            success "eza installed"; n=$((n+1))
        fi
    fi

    # zoxide
    if [[ "$(cfg_tool zoxide)" == "true" ]]; then
        if command_exists zoxide; then success "zoxide already installed"
        elif confirm "Install zoxide?"; then
            curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh >> "$LOG_FILE" 2>&1
            success "zoxide installed"; n=$((n+1))
        fi
    fi

    # bat
    if [[ "$(cfg_tool bat)" == "true" ]]; then
        if command_exists bat || command_exists batcat; then success "bat already installed"
        elif confirm "Install bat?"; then
            pkg_install "bat" "bat" "bat" "bat" "bat" "bat"
            command_exists batcat && ! command_exists bat && {
                mkdir -p "$HOME/.local/bin"; ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
            }
            success "bat installed"; n=$((n+1))
        fi
    fi

    # neovim
    if [[ "$(cfg_tool neovim)" == "true" ]]; then
        if command_exists nvim; then success "neovim already installed"
        elif confirm "Install neovim?"; then
            if [[ "$PKG_MANAGER" == "apt" && "$DISTRO" == "ubuntu" ]]; then
                $NEEDS_SUDO apt-get install -y -qq software-properties-common >> "$LOG_FILE" 2>&1
                $NEEDS_SUDO add-apt-repository -y ppa:neovim-ppa/stable >> "$LOG_FILE" 2>&1
                $NEEDS_SUDO apt-get update -qq >> "$LOG_FILE" 2>&1
                $NEEDS_SUDO apt-get install -y -qq neovim >> "$LOG_FILE" 2>&1
            else
                pkg_install "neovim" "neovim" "neovim" "neovim" "neovim" "neovim"
            fi
            success "neovim installed"; n=$((n+1))
        fi
    fi

    # nvm
    if [[ "$(cfg_tool nvm)" == "true" ]]; then
        if [[ -d "$HOME/.nvm" ]]; then success "nvm already installed"
        elif confirm "Install nvm?"; then
            curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash >> "$LOG_FILE" 2>&1
            success "nvm installed"; n=$((n+1))
        fi
    fi

    # homebrew
    if [[ "$(cfg_tool homebrew)" == "true" ]]; then
        if command_exists brew; then success "Homebrew already installed: $(brew --version | head -1)"
        elif confirm "Install Homebrew?"; then
            info "Installing Homebrew (this may take a few minutes)..."
            NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" >> "$LOG_FILE" 2>&1
            # Source shellenv immediately so brew is available for the rest of this session
            if [[ -x "/home/linuxbrew/.linuxbrew/bin/brew" ]]; then
                eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
            elif [[ -x "$HOME/.linuxbrew/bin/brew" ]]; then
                eval "$($HOME/.linuxbrew/bin/brew shellenv)"
            fi
            if command_exists brew; then
                success "Homebrew installed: $(brew --version | head -1)"; n=$((n+1))
            else
                warn "Homebrew install may have failed; check $LOG_FILE"
            fi
        fi
    fi

    # rust
    if [[ "$(cfg_tool rust)" == "true" ]]; then
        if command_exists rustup || command_exists cargo; then success "Rust already installed"
        elif confirm "Install Rust?"; then
            curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y >> "$LOG_FILE" 2>&1
            success "Rust installed"; n=$((n+1))
        fi
    fi

    # xclip
    if [[ "$(cfg_tool xclip)" == "true" ]]; then
        if command_exists xclip || command_exists xsel || command_exists wl-copy; then
            success "Clipboard tool available"
        elif confirm "Install xclip?"; then
            pkg_install "xclip" "xclip" "xclip" "xclip" "xclip" "xclip"
            success "xclip installed"; n=$((n+1))
        fi
    fi

    # tree
    if [[ "$(cfg_tool tree)" == "true" ]]; then
        if command_exists tree; then success "tree already installed"
        elif confirm "Install tree?"; then
            pkg_install "tree" "tree" "tree" "tree" "tree" "tree"
            success "tree installed"; n=$((n+1))
        fi
    fi

    # nerd font
    if [[ "$(cfg_tool nerd_font)" == "true" ]]; then
        local font_dir="$HOME/.local/share/fonts"
        if ls "$font_dir"/*Nerd* &>/dev/null 2>&1; then
            success "Nerd Font already installed"
        elif confirm "Install JetBrainsMono Nerd Font?"; then
            mkdir -p "$font_dir"
            curl -fsSL "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz" \
                | tar xJ -C "$font_dir" >> "$LOG_FILE" 2>&1
            command_exists fc-cache && fc-cache -f "$font_dir" >> "$LOG_FILE" 2>&1
            success "JetBrainsMono Nerd Font installed"
            info "Set your terminal font to 'JetBrainsMono Nerd Font'"; n=$((n+1))
        fi
    fi

    echo ""
    success "Tools setup complete ($n newly installed)"
}

install_eza_from_github() {
    local arch; arch=$(uname -m)
    [[ "$arch" == "aarch64" ]] || arch="x86_64"
    local ver
    ver=$(curl -fsSL "https://api.github.com/repos/eza-community/eza/releases/latest" | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
    curl -fsSL "https://github.com/eza-community/eza/releases/download/v${ver}/eza_${arch}-unknown-linux-gnu.tar.gz" \
        | tar xz -C /tmp >> "$LOG_FILE" 2>&1
    $NEEDS_SUDO mv /tmp/eza /usr/local/bin/eza 2>> "$LOG_FILE"
    $NEEDS_SUDO chmod +x /usr/local/bin/eza 2>> "$LOG_FILE"
}

# ═════════════════════════════════════════════════════════════════════════════
# Parse bashrc — extract only aliases & exports
# ═════════════════════════════════════════════════════════════════════════════
parse_bashrc() {
    step "Scanning bash config for aliases & exports"

    BASH_ALIASES_FILE=$(mktemp /tmp/b2z_aliases.XXXXXX)
    BASH_EXPORTS_FILE=$(mktemp /tmp/b2z_exports.XXXXXX)

    local files_found=()
    [[ -f "$HOME/.bashrc" ]]       && files_found+=("$HOME/.bashrc")
    [[ -f "$HOME/.bash_profile" ]] && files_found+=("$HOME/.bash_profile")
    [[ -f "$HOME/.bash_aliases" ]] && files_found+=("$HOME/.bash_aliases")

    if [[ ${#files_found[@]} -eq 0 ]]; then
        info "No bash config files found"
        return
    fi

    local ac=0 ec=0
    for file in "${files_found[@]}"; do
        info "Scanning $file..."
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "${line// /}" ]] && continue
            [[ "$line" =~ ^[[:space:]]*# ]] && continue

            if [[ "$line" =~ ^[[:space:]]*alias[[:space:]] ]]; then
                echo "$line" >> "$BASH_ALIASES_FILE"
                ac=$((ac + 1))
            elif [[ "$line" =~ ^[[:space:]]*export[[:space:]] ]]; then
                # Skip bash-specific
                [[ "$line" =~ (HISTCONTROL|HISTSIZE|HISTFILESIZE|PROMPT_COMMAND|BASH_) ]] && continue
                [[ "$line" =~ ^[[:space:]]*export[[:space:]]+PATH= ]] && continue
                echo "$line" >> "$BASH_EXPORTS_FILE"
                ec=$((ec + 1))
            fi
        done < "$file"
    done

    if [[ $ac -gt 0 || $ec -gt 0 ]]; then
        success "Found $ac aliases and $ec exports in bash config"
    else
        info "No aliases or exports found in bash config"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# Generate .zshrc from config.yaml
# ═════════════════════════════════════════════════════════════════════════════
generate_zshrc() {
    step "Generating .zshrc"

    local zshrc="$HOME/.zshrc"
    local theme editor
    theme=$(cfg_get "theme")
    theme="${theme:-robbyrussell}"
    editor=$(cfg_get "editor")
    editor="${editor:-vim}"

    # Resolve theme name for oh-my-zsh
    local omz_theme="$theme"
    [[ "$theme" == "powerlevel10k" ]] && omz_theme="powerlevel10k/powerlevel10k"

    # Build plugins string
    local plugins_str=""
    while IFS= read -r p; do
        [[ -n "$p" ]] && plugins_str+="$p "
    done < <(cfg_list "plugins")
    plugins_str="${plugins_str% }"  # trim trailing space

    # Detect clipboard
    local clip_copy="xclip -selection clipboard"
    local clip_paste="xclip -selection clipboard -o"
    command_exists wl-copy && { clip_copy="wl-copy"; clip_paste="wl-paste"; }

    # ── Write the file ──
    cat > "$zshrc" << ZSHRC_HEADER
# ============================================================================
# .zshrc — generated by bash2zsh v${SCRIPT_VERSION} on $(date '+%Y-%m-%d %H:%M')
# Config: ${CONFIG_FILE}
# ============================================================================

# ── Oh My Zsh ────────────────────────────────────────────────────────────────
export ZSH="\$HOME/.oh-my-zsh"
ZSH_THEME="${omz_theme}"
plugins=(${plugins_str})
source \$ZSH/oh-my-zsh.sh

# ── PATH ─────────────────────────────────────────────────────────────────────
export PATH="\$HOME/.local/bin:\$PATH"
ZSHRC_HEADER

    # Extra PATH entries from config
    while IFS= read -r p; do
        [[ -n "$p" ]] && echo "export PATH=\"${p}:\$PATH\"" >> "$zshrc"
    done < <(cfg_list "extra_paths")

    # Editor
    echo "" >> "$zshrc"
    echo "# ── Editor ───────────────────────────────────────────────────────────────" >> "$zshrc"
    echo "export EDITOR=${editor}" >> "$zshrc"
    if [[ "$editor" == "nvim" ]] && command_exists nvim; then
        echo "alias vim='nvim'" >> "$zshrc"
    fi

    # Auto-generated tool aliases
    echo "" >> "$zshrc"
    echo "# ── Tool Aliases (auto-detected) ───────────────────────────────────────────" >> "$zshrc"
    command_exists eza && echo 'alias ls="eza --color=always --long --no-filesize --icons=always --no-time --no-user --no-permissions"' >> "$zshrc"
    if command_exists fd && command_exists fzf; then
        echo 'alias find="fd . | fzf --exact"' >> "$zshrc"
    elif command_exists fdfind && command_exists fzf; then
        echo 'alias find="fdfind . | fzf --exact"' >> "$zshrc"
    fi
    command_exists batcat && ! command_exists bat && echo 'alias bat="batcat"' >> "$zshrc"

    # Clipboard aliases
    echo "" >> "$zshrc"
    echo "# ── Clipboard ────────────────────────────────────────────────────────────────" >> "$zshrc"
    echo "alias pbcopy=\"${clip_copy}\"" >> "$zshrc"
    echo "alias pbpaste=\"${clip_paste}\"" >> "$zshrc"

    # SSH term fix
    echo "alias ssh='TERM=xterm-256color ssh'" >> "$zshrc"

    # Exports from config
    local config_exports
    config_exports=$(cfg_map "exports")
    if [[ -n "$config_exports" ]]; then
        echo "" >> "$zshrc"
        echo "# ── Environment Variables ──────────────────────────────────────────────────" >> "$zshrc"
        echo "$config_exports" | while IFS='=' read -r key val; do
            [[ -n "$key" && -n "$val" ]] && echo "export ${key}=\"${val}\"" >> "$zshrc"
        done
    fi

    # Aliases from config
    local config_aliases
    config_aliases=$(cfg_map "aliases")
    if [[ -n "$config_aliases" ]]; then
        echo "" >> "$zshrc"
        echo "# ── Aliases ──────────────────────────────────────────────────────────────────" >> "$zshrc"
        echo "$config_aliases" | while IFS='=' read -r key val; do
            [[ -n "$key" && -n "$val" ]] && echo "alias ${key}=\"${val}\"" >> "$zshrc"
        done
    fi

    # NVM
    [[ -d "$HOME/.nvm" ]] && {
        echo "" >> "$zshrc"
        echo "# ── NVM ──────────────────────────────────────────────────────────────────────" >> "$zshrc"
        echo 'export NVM_DIR="$HOME/.nvm"' >> "$zshrc"
        echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> "$zshrc"
        echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"' >> "$zshrc"
    }

    # Cargo
    { [[ -f "$HOME/.cargo/env" ]] || command_exists cargo; } && {
        echo "" >> "$zshrc"
        echo "# ── Rust ─────────────────────────────────────────────────────────────────────" >> "$zshrc"
        echo '[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"' >> "$zshrc"
    }

    # Homebrew
    if [[ -x "/home/linuxbrew/.linuxbrew/bin/brew" ]] || [[ -x "$HOME/.linuxbrew/bin/brew" ]]; then
        {
            echo ""
            echo "# ── Homebrew ─────────────────────────────────────────────────────────────────"
            echo '[[ -x "/home/linuxbrew/.linuxbrew/bin/brew" ]] && eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'
            echo '[[ -x "$HOME/.linuxbrew/bin/brew" ]] && eval "$($HOME/.linuxbrew/bin/brew shellenv)"'
        } >> "$zshrc"
    fi

    # Zoxide
    { command_exists zoxide || [[ -f "$HOME/.local/bin/zoxide" ]]; } && {
        echo "" >> "$zshrc"
        echo "# ── Zoxide ─────────────────────────────────────────────────────────────────" >> "$zshrc"
        echo 'eval "$(zoxide init zsh)"' >> "$zshrc"
    }

    # fzf
    [[ -f "$HOME/.fzf.zsh" ]] && {
        echo "" >> "$zshrc"
        echo '[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh' >> "$zshrc"
    }

    # Alias manager (aa)
    if command_exists fzf || [[ -f "$HOME/.fzf/bin/fzf" ]]; then
        cat >> "$zshrc" << 'AA_FUNC'

# ── Alias Manager (type 'aa' to browse aliases with fzf) ────────────────────
aa() {
  if ! command -v fzf &>/dev/null; then echo "fzf required"; return 1; fi
  local selected=$(grep "^alias " ~/.zshrc | sed 's/alias //' | awk -F= '{printf "%-20s -> %s\n", $1, $2}' | fzf --height 40% --reverse --border=rounded --prompt="Aliases: " --preview 'echo {}' --preview-window=up:1)
  if [[ -n "$selected" ]]; then
    local alias_name=$(echo "$selected" | awk '{print $1}')
    local alias_cmd=$(alias "$alias_name" | sed "s/^[^=]*=//;s/^'//;s/'$//")
    echo "\nCommand: $alias_cmd\n"
    echo "Press 'r' to RUN, 'c' to COPY, or any other key to cancel"
    read -k1 choice; echo
    case "$choice" in
      r|R) eval "$alias_cmd" ;;
      c|C) echo "$alias_cmd" | pbcopy && echo "Copied to clipboard!" ;;
      *) echo "Cancelled" ;;
    esac
  fi
}
AA_FUNC
    fi

    # Powerlevel10k config
    [[ "$theme" == "powerlevel10k" ]] && {
        echo "" >> "$zshrc"
        echo '# Load p10k config if it exists' >> "$zshrc"
        echo '[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh' >> "$zshrc"
    }

    # Extra zshrc from config
    local extra
    extra=$(cfg_block "extra_zshrc")
    if [[ -n "${extra// /}" ]]; then
        echo "" >> "$zshrc"
        echo "# ── Extra (from config.yaml) ────────────────────────────────────────────────" >> "$zshrc"
        echo "$extra" >> "$zshrc"
    fi

    # Migrated bash aliases & exports (LAST = highest priority)
    local has_bash=false
    [[ -s "$BASH_EXPORTS_FILE" || -s "$BASH_ALIASES_FILE" ]] && has_bash=true

    if $has_bash; then
        echo "" >> "$zshrc"
        echo "# ── Migrated from .bashrc (highest priority — overrides duplicates) ────────" >> "$zshrc"
        [[ -s "$BASH_EXPORTS_FILE" ]] && { echo ""; cat "$BASH_EXPORTS_FILE"; } >> "$zshrc"
        [[ -s "$BASH_ALIASES_FILE" ]] && { echo ""; cat "$BASH_ALIASES_FILE"; } >> "$zshrc"
        echo "" >> "$zshrc"
    fi

    success ".zshrc generated"
}

generate_zshenv() {
    cat > "$HOME/.zshenv" << 'EOF'
# Sourced on every zsh invocation. Keep minimal.
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
EOF
    success ".zshenv generated"
}

# ═════════════════════════════════════════════════════════════════════════════
# Bash history migration
# ═════════════════════════════════════════════════════════════════════════════
migrate_history() {
    step "Bash history migration"
    local bash_hist="$HOME/.bash_history"
    [[ ! -f "$bash_hist" ]] && { info "No .bash_history found"; return; }

    local lines
    lines=$(wc -l < "$bash_hist" | tr -d ' ')
    info "Found $lines lines in .bash_history"

    if confirm "Migrate bash history to zsh?"; then
        local ts counter=0
        ts=$(date +%s)
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            if [[ "$line" =~ ^#([0-9]+)$ ]]; then ts="${BASH_REMATCH[1]}"; continue; fi
            echo ": ${ts}:${counter};${line}"
            counter=$((counter + 1)); ts=$((ts + 1))
        done < "$bash_hist" >> "$HOME/.zsh_history"
        success "Migrated $counter history entries"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════
print_summary() {
    local theme
    theme=$(cfg_get "theme")
    theme="${theme:-robbyrussell}"

    echo ""
    echo -e "${GREEN}${BOLD}============================================================${NC}"
    echo -e "${GREEN}${BOLD}  bash2zsh setup complete!${NC}"
    echo -e "${GREEN}${BOLD}============================================================${NC}"
    echo ""
    echo -e "  ${BOLD}Shell:${NC}      zsh + Oh My Zsh"
    echo -e "  ${BOLD}Theme:${NC}      $theme"
    echo -e "  ${BOLD}Plugins:${NC}    $(cfg_list plugins | tr '\n' ' ')"
    echo ""
    echo -e "  ${BOLD}Tools:${NC}"
    command_exists fzf    && echo -e "    ${GREEN}+${NC} fzf       (fuzzy finder)"
    command_exists fd     && echo -e "    ${GREEN}+${NC} fd        (fast find)"
    command_exists rg     && echo -e "    ${GREEN}+${NC} ripgrep   (fast grep)"
    command_exists eza    && echo -e "    ${GREEN}+${NC} eza       (modern ls)"
    command_exists zoxide && echo -e "    ${GREEN}+${NC} zoxide    (smart cd)"
    { command_exists bat || command_exists batcat; } && echo -e "    ${GREEN}+${NC} bat       (syntax cat)"
    command_exists nvim   && echo -e "    ${GREEN}+${NC} neovim    (editor)"
    [[ -d "$HOME/.nvm" ]]&& echo -e "    ${GREEN}+${NC} nvm       (node manager)"
    command_exists cargo  && echo -e "    ${GREEN}+${NC} rust      (cargo)"
    echo ""
    echo -e "  ${BOLD}Files:${NC}"
    echo -e "    ${DIM}Config:${NC}  $CONFIG_FILE"
    echo -e "    ${DIM}zshrc:${NC}   ~/.zshrc"
    echo -e "    ${DIM}Backup:${NC}  $BACKUP_DIR"
    echo -e "    ${DIM}Log:${NC}     $LOG_FILE"
    echo ""
    echo -e "  ${BOLD}Shortcuts:${NC}"
    echo -e "    ${CYAN}aa${NC}         Browse aliases with fzf"
    command_exists zoxide && echo -e "    ${CYAN}z <dir>${NC}    Smart cd with zoxide"
    echo -e "    ${CYAN}Ctrl+R${NC}     Fuzzy history search"
    echo -e "    ${CYAN}Ctrl+T${NC}     Fuzzy file search"
    echo ""
    echo -e "  ${YELLOW}Start zsh now:${NC}  ${BOLD}exec zsh${NC}"
    echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
# Cleanup & Main
# ═════════════════════════════════════════════════════════════════════════════
cleanup() { rm -f "$BASH_ALIASES_FILE" "$BASH_EXPORTS_FILE" 2>/dev/null; }
trap cleanup EXIT

main() {
    echo ""
    echo -e "${MAGENTA}${BOLD}  bash2zsh v${SCRIPT_VERSION}${NC} — migrate bash to zsh"
    if $INTERACTIVE; then
        echo -e "${DIM}  Mode: interactive${NC}"
    else
        echo -e "${DIM}  Mode: automatic (use --interactive to choose)${NC}"
    fi
    echo ""

    # Validate config
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "Config file not found: $CONFIG_FILE"
        error "Run from the bash2zsh directory, or use: --config /path/to/config.yaml"
        exit 1
    fi
    success "Config loaded: $CONFIG_FILE"

    detect_system
    backup_configs
    pkg_update
    install_zsh
    install_oh_my_zsh
    install_custom_plugins
    install_theme
    install_cli_tools
    parse_bashrc
    generate_zshrc
    generate_zshenv
    migrate_history
    print_summary
}

main "$@"
