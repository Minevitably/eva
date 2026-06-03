#!/usr/bin/env bash
#
# eva — AI Shell Assistant Installer
#
# One-command setup:
#   curl -fsSL https://.../install.sh | bash
# Or:
#   git clone ... && cd eva && bash install.sh
#

set -euo pipefail

EVA_HOME="${EVA_HOME:-$HOME/.eva}"
API_KEY="${EVA_API_KEY:-sk-b3d18f6fd0b348fd80b19aaa3754b856}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[eva]${NC} $*"; }
warn()  { echo -e "${YELLOW}[eva]${NC} $*"; }
error() { echo -e "${RED}[eva]${NC} $*"; }
step()  { echo -e "${CYAN}==>${NC} $*"; }

# --- Detect script directory ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Check prerequisites ---
check_prereqs() {
    step "Checking prerequisites..."

    if ! command -v python3 &>/dev/null; then
        error "python3 is required but not installed. Install it first:"
        error "  Ubuntu/Debian: sudo apt install python3"
        error "  Fedora:        sudo dnf install python3"
        error "  Arch:          sudo pacman -S python"
        exit 1
    fi

    if ! command -v zsh &>/dev/null; then
        warn "zsh is not installed. eva only supports ZSH."
        warn "Install it: sudo apt install zsh"
    fi

    info "python3: $(python3 --version)"
    info "zsh:     ${ZSH_VERSION:-$(zsh --version 2>/dev/null || echo 'not detected')}"
}

# --- Create EVA_HOME ---
setup_dirs() {
    step "Creating $EVA_HOME..."
    mkdir -p "$EVA_HOME"
}

# --- Install Python dependency ---
install_deps() {
    step "Installing Python dependencies..."

    # Ensure pip is available
    if ! python3 -m pip --version &>/dev/null; then
        warn "pip is not installed."

        # Try ensurepip first
        if python3 -m ensurepip --upgrade 2>/dev/null; then
            info "pip bootstrapped via ensurepip"
        # Auto-install on Debian/Ubuntu
        elif command -v apt &>/dev/null; then
            warn "Installing python3-pip via apt..."
            if [[ $EUID -eq 0 ]]; then
                apt update -qq && apt install -y -qq python3-pip
            elif command -v sudo &>/dev/null; then
                sudo apt update -qq && sudo apt install -y -qq python3-pip
            else
                error "Run: apt install python3-pip  (need root)"
                exit 1
            fi
        # Auto-install on Fedora
        elif command -v dnf &>/dev/null; then
            warn "Installing python3-pip via dnf..."
            if [[ $EUID -eq 0 ]]; then
                dnf install -y -q python3-pip
            elif command -v sudo &>/dev/null; then
                sudo dnf install -y -q python3-pip
            else
                error "Run: dnf install python3-pip  (need root)"
                exit 1
            fi
        # Auto-install on Arch
        elif command -v pacman &>/dev/null; then
            warn "Installing python-pip via pacman..."
            if [[ $EUID -eq 0 ]]; then
                pacman -S --noconfirm python-pip
            elif command -v sudo &>/dev/null; then
                sudo pacman -S --noconfirm python-pip
            else
                error "Run: pacman -S python-pip  (need root)"
                exit 1
            fi
        else
            error "Cannot install pip automatically. Unknown distro."
            error "Please install python3-pip manually and re-run."
            exit 1
        fi
        info "pip installed successfully"
    fi

    python3 -m pip install --user --quiet openai 2>/dev/null || {
        warn "pip install failed, trying with --break-system-packages..."
        python3 -m pip install --user --quiet --break-system-packages openai
    }
    info "openai package installed"
}

# --- Copy files ---
copy_files() {
    step "Copying eva files to $EVA_HOME..."

    # Copy source files
    cp "$SCRIPT_DIR/src/predictor.py" "$EVA_HOME/predictor.py"
    cp "$SCRIPT_DIR/src/daemon.py"    "$EVA_HOME/daemon.py"
    cp "$SCRIPT_DIR/shell/eva-bridge"  "$EVA_HOME/eva-bridge"
    cp "$SCRIPT_DIR/shell/eva.plugin.zsh" "$EVA_HOME/eva.plugin.zsh"

    # Make bridge executable
    chmod +x "$EVA_HOME/eva-bridge"

    # Save API key
    echo "sk-b3d18f6fd0b348fd80b19aaa3754b856" > "$EVA_HOME/apikey"

    info "Files installed to $EVA_HOME"
}

# --- Start daemon ---
start_daemon() {
    step "Starting eva daemon..."

    # Kill existing daemon if running
    if [[ -f "$EVA_HOME/eva.pid" ]]; then
        kill "$(cat "$EVA_HOME/eva.pid")" 2>/dev/null || true
        sleep 0.5
    fi

    # Start daemon in background
    EVA_API_KEY="$API_KEY" nohup python3 "$EVA_HOME/daemon.py" start > "$EVA_HOME/eva.log" 2>&1 &

    # Wait for socket to appear
    local waited=0
    while [[ ! -S "$EVA_HOME/eva.sock" ]] && (( waited < 5 )); do
        sleep 0.5
        waited=$(( waited + 1 ))
    done

    if [[ -S "$EVA_HOME/eva.sock" ]]; then
        info "eva daemon started successfully"
    else
        warn "Daemon may not have started. Check $EVA_HOME/eva.log"
        warn "Last few log lines:"
        tail -5 "$EVA_HOME/eva.log" 2>/dev/null || true
    fi
}

# --- Configure shell ---
configure_shell() {
    step "Configuring ZSH..."

    local source_line="source $EVA_HOME/eva.plugin.zsh"
    local zshrc="$HOME/.zshrc"

    if [[ -f "$zshrc" ]] && grep -q "eva.plugin.zsh" "$zshrc" 2>/dev/null; then
        info "eva already configured in .zshrc"
    else
        cat >> "$zshrc" <<ZSHEOF

# eva — AI Shell Assistant
export EVA_API_KEY="$API_KEY"
export EVA_HOME="$EVA_HOME"
$source_line
ZSHEOF
        info "Added eva to $zshrc"
    fi
}

# --- Print summary ---
print_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   eva installed successfully! 🎉        ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo "  How to use:"
    echo "    1. Open a new terminal (or run: source ~/.zshrc)"
    echo "    2. Start typing any command"
    echo "    3. Grey prediction appears → press Tab to accept"
    echo ""
    echo "  Commands:"
    echo "    eva-status       — check if daemon is responding"
    echo "    eva-restart      — restart the prediction bridge"
    echo "    python3 ~/.eva/daemon.py stop   — stop the daemon"
    echo "    python3 ~/.eva/daemon.py status — check daemon status"
    echo ""
}

# --- Run ---
main() {
    echo ""
    echo -e "${CYAN}  eva — AI Shell Assistant Installer${NC}"
    echo ""

    check_prereqs
    setup_dirs
    copy_files
    install_deps
    start_daemon
    configure_shell
    print_summary
}

main "$@"
