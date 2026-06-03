#
# eva.plugin.zsh — ZSH plugin for AI-powered shell command prediction
#
# Shows grey prediction text as you type. Tab to accept.
# Requires the eva daemon to be running (~/.eva/eva.sock).
#
# Installation: source this file in your .zshrc
#

# --- Load required zsh modules ---
zmodload zsh/zpty  2>/dev/null || { echo "eva: zsh/zpty module not available" >&2; return 1; }
zmodload zsh/sched 2>/dev/null || { echo "eva: zsh/sched module not available" >&2; return 1; }

# --- Config ---
: ${EVA_HOME:="$HOME/.eva"}
: ${EVA_DEBOUNCE_MS:=200}       # min ms between prediction requests
: ${EVA_POLL_INTERVAL:=1}        # seconds between zpty reads

# --- State ---
typeset -g _EVA_SEQ=0           # latest request sequence number
typeset -g _EVA_LAST_SEQ=0      # sequence number that produced current POSTDISPLAY
typeset -g _EVA_BRIDGE_OK=false # whether the zpty bridge is alive
typeset -g _EVA_LAST_REQ=0.0    # timestamp of last request (for debounce)
typeset -g _EVA_PENDING=false   # whether a request is in flight
typeset -g _EVA_POLLING=false   # whether poll loop is active

# Highlight style: use ZSH autosuggest color if available, else grey
typeset -g EVA_HIGHLIGHT_FG
EVA_HIGHLIGHT_FG="${ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE:-fg=240}"


# --- Bridge lifecycle ---
_eva_start_bridge() {
    # Kill existing bridge if any
    zpty -d eva-bridge 2>/dev/null

    local bridge_py="$EVA_HOME/eva-bridge"
    if [[ ! -f "$bridge_py" ]]; then
        return 1
    fi

    zpty -b eva-bridge "python3 $bridge_py"
    if [[ $? -eq 0 ]]; then
        _EVA_BRIDGE_OK=true
    fi
}

_eva_ensure_bridge() {
    if [[ "$_EVA_BRIDGE_OK" != "true" ]]; then
        _eva_start_bridge
    fi
}

# --- Polling: read responses from bridge ---
_eva_poll() {
    [[ "$_EVA_POLLING" != "true" ]] && return

    if [[ "$_EVA_BRIDGE_OK" != "true" ]]; then
        sched +$EVA_POLL_INTERVAL _eva_poll_cb
        return
    fi

    local response
    if zpty -r eva-bridge response 2>/dev/null && [[ -n "$response" ]]; then
        local seq="${response%%$'\t'*}"
        local pred="${response#*$'\t'}"

        # Only accept the latest prediction
        if (( seq >= _EVA_LAST_SEQ )); then
            _EVA_LAST_SEQ=seq
            _EVA_PENDING=false

            if [[ -n "$pred" ]]; then
                POSTDISPLAY="$pred"
                region_highlight=("P 0 $((#BUFFER + #POSTDISPLAY + 1)) $EVA_HIGHLIGHT_FG")
            else
                POSTDISPLAY=""
                region_highlight=()
            fi
            zle -R
        fi
    fi

    sched +$EVA_POLL_INTERVAL _eva_poll_cb
}

_eva_poll_cb() {
    _eva_poll
}

_eva_start_polling() {
    if [[ "$_EVA_POLLING" != "true" ]]; then
        _EVA_POLLING=true
        _eva_poll
    fi
}

# --- Build request JSON and send ---
_eva_request_predict() {
    _eva_ensure_bridge
    [[ "$_EVA_BRIDGE_OK" != "true" ]] && return

    # Debounce: skip if too soon after last request
    local now=$EPOCHREALTIME
    if (( now - _EVA_LAST_REQ < EVA_DEBOUNCE_MS / 1000.0 )) && [[ -n "$POSTDISPLAY" ]]; then
        return
    fi
    _EVA_LAST_REQ=$now

    # Increment seq to invalidate any in-flight requests
    (( _EVA_SEQ++ ))
    _EVA_PENDING=true

    # Get recent history
    local history_json="[]"
    if (( ${#history} > 0 )); then
        # Get last 10 commands as a JSON array via python (safe escaping)
        history_json=$(fc -l -10 -n 2>/dev/null | python3 -c "
import sys, json
cmds = [line.rstrip('\n') for line in sys.stdin if line.strip()]
print(json.dumps(cmds))
" 2>/dev/null)
    fi
    [[ -z "$history_json" ]] && history_json="[]"

    # Build the full request JSON safely via python
    local json
    json=$(python3 -c "
import json, sys
req = {
    'seq': $_EVA_SEQ,
    'buffer': sys.argv[1],
    'cwd': sys.argv[2],
    'history': json.loads(sys.argv[3])
}
print(json.dumps(req))
" "$BUFFER" "$PWD" "$history_json" 2>/dev/null)

    [[ -z "$json" ]] && return

    # Send to bridge via zpty
    zpty -w eva-bridge "$json" 2>/dev/null
}

# --- Keypress handler ---
_eva_self_insert() {
    # Call original self-insert to actually type the character
    zle .self-insert

    # Then request a prediction
    _eva_request_predict
}

# --- Accept prediction ---
_eva_accept() {
    if [[ -n "$POSTDISPLAY" ]]; then
        BUFFER+="$POSTDISPLAY"
        CURSOR=$#BUFFER
        POSTDISPLAY=""
        region_highlight=()
        zle -R
    fi
}

# --- Accept next word of prediction ---
_eva_accept_word() {
    if [[ -n "$POSTDISPLAY" ]]; then
        local word="${POSTDISPLAY%% *}"
        if [[ "$word" == "$POSTDISPLAY" ]]; then
            # Last word — accept full prediction
            _eva_accept
        else
            BUFFER+="$word "
            CURSOR=$#BUFFER
            POSTDISPLAY="${POSTDISPLAY#$word }"
            POSTDISPLAY="${POSTDISPLAY## }"
            zle -R
        fi
    fi
}

# --- Clear prediction ---
_eva_clear() {
    POSTDISPLAY=""
    region_highlight=()
    zle -R
}

# --- Redraw hook (called by ZSH before each redraw) ---
_eva_line_pre_redraw() {
    # Ensure polling is running
    _eva_start_polling
}

# --- Backward delete handler — clear prediction then delete ---
_eva_backward_delete_char() {
    zle .backward-delete-char
    POSTDISPLAY=""
    region_highlight=()
    _eva_request_predict
}

# --- Enter (accept-line) handler — clear prediction before executing ---
_eva_accept_line() {
    POSTDISPLAY=""
    region_highlight=()
    zle .accept-line
}

# --- Setup ---
_eva_setup() {
    # Define widgets
    zle -N eva-self-insert _eva_self_insert
    zle -N eva-accept _eva_accept
    zle -N eva-accept-word _eva_accept_word
    zle -N eva-clear _eva_clear
    zle -N eva-backward-delete-char _eva_backward_delete_char
    zle -N eva-accept-line _eva_accept_line
    zle -N eva-line-pre-redraw _eva_line_pre_redraw

    # Hook into line-pre-redraw (called before each redraw)
    autoload -Uz add-zle-hook-widget
    add-zle-hook-widget line-pre-redraw eva-line-pre-redraw 2>/dev/null || true

    # Ensure EVA_HOME exists
    mkdir -p "$EVA_HOME"

    # Start bridge
    _eva_start_bridge

    # Start polling loop (will self-sustain)
    _eva_start_polling
}

# --- Rebind keys ---
_eva_bind_keys() {
    # Printable characters → our self-insert
    bindkey -M emacs ' ' eva-self-insert
    bindkey -M emacs '^?' eva-backward-delete-char  # Backspace
    bindkey -M emacs '^H' eva-backward-delete-char  # Ctrl+H (alt backspace)
    bindkey -M emacs '^M' eva-accept-line           # Enter
    bindkey -M emacs '^I' eva-accept                # Tab → accept full
    bindkey -M emacs '^[^I' eva-accept-word         # Alt+Tab → accept next word

    # Override all printable ASCII via keymap trick
    # For letters, digits, and symbols, route through eva-self-insert
    local c
    for c in {a..z} {A..Z} {0..9}; do
        bindkey -M emacs "$c" eva-self-insert
    done
    # Common symbols
    for c in '-' '=' '/' '.' ',' '\' '"' "'" ';' ':' '!' '@' '#' '$' '%' '^' '&' '*' '(' ')' '_' '+' '{' '}' '[' ']' '<' '>' '?' '~' '`'; do
        bindkey -M emacs "$c" eva-self-insert
    done
    # Space is already bound above, but bind pipe separately
    bindkey -M emacs '|' eva-self-insert
}

# --- Initialize ---
_eva_init() {
    _eva_setup
    _eva_bind_keys
}

# Auto-initialize when sourced
_eva_init

# --- Public API ---
# eva-status: check if daemon is running
eva-status() {
    if [[ -S "$EVA_HOME/eva.sock" ]]; then
        echo "eva daemon socket found at $EVA_HOME/eva.sock"
        python3 -c "
import socket, json
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(2)
try:
    sock.connect('$EVA_HOME/eva.sock')
    sock.sendall(json.dumps({'seq':0,'buffer':'','cwd':'/','history':[]}).encode()+b'\n')
    print('  → daemon is responding')
except Exception as e:
    print(f'  → daemon not responding: {e}')
finally:
    sock.close()
" 2>/dev/null
    else
        echo "eva daemon socket not found. Start it with: python3 $EVA_HOME/daemon.py start &"
    fi
}

# eva-restart: restart the bridge (useful if it gets stuck)
eva-restart() {
    _EVA_BRIDGE_OK=false
    _EVA_SEQ=0
    _EVA_LAST_SEQ=0
    POSTDISPLAY=""
    region_highlight=()
    _eva_start_bridge
    echo "eva bridge restarted"
}
