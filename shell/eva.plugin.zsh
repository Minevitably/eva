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
typeset -g _EVA_SEQ=0
typeset -g _EVA_LAST_SEQ=0
typeset -g _EVA_BRIDGE_OK=false
typeset -g _EVA_LAST_REQ=0.0
typeset -g _EVA_PENDING=false
typeset -g _EVA_POLLING=false
typeset -g _EVA_INITIALIZED=false

# Highlight style
typeset -g EVA_HIGHLIGHT_FG
EVA_HIGHLIGHT_FG="${ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE:-fg=240}"


# --- Bridge lifecycle ---
_eva_start_bridge() {
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

# --- Polling: read responses from bridge ---
_eva_poll() {
    [[ "$_EVA_POLLING" != "true" ]] && return
    [[ "$_EVA_INITIALIZED" != "true" ]] && return

    if [[ "$_EVA_BRIDGE_OK" != "true" ]]; then
        sched +$EVA_POLL_INTERVAL _eva_poll_cb
        return
    fi

    local response
    if zpty -r eva-bridge response 2>/dev/null && [[ -n "$response" ]]; then
        local seq="${response%%$'\t'*}"
        local pred="${response#*$'\t'}"

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

_eva_poll_cb() { _eva_poll }

_eva_start_polling() {
    if [[ "$_EVA_POLLING" != "true" ]]; then
        _EVA_POLLING=true
        _eva_poll
    fi
}

# --- Build request JSON and send ---
_eva_request_predict() {
    [[ "$_EVA_INITIALIZED" != "true" ]] && return
    [[ "$_EVA_BRIDGE_OK" != "true" ]] && { _eva_start_bridge; return; }

    local now=$EPOCHREALTIME
    if (( now - _EVA_LAST_REQ < EVA_DEBOUNCE_MS / 1000.0 )) && [[ -n "$POSTDISPLAY" ]]; then
        return
    fi
    _EVA_LAST_REQ=$now

    (( _EVA_SEQ++ ))
    _EVA_PENDING=true

    local history_json="[]"
    if (( ${#history} > 0 )); then
        history_json=$(fc -l -10 -n 2>/dev/null | python3 -c "
import sys, json
cmds = [line.rstrip('\n') for line in sys.stdin if line.strip()]
print(json.dumps(cmds))
" 2>/dev/null)
    fi
    [[ -z "$history_json" ]] && history_json="[]"

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

    zpty -w eva-bridge "$json" 2>/dev/null
}


# ============================================================
#  Override built-in ZLE widgets (no custom widgets, no bindkey)
# ============================================================

# --- self-insert: type character + request prediction ---
_eva_self_insert() {
    zle .self-insert
    _eva_request_predict
}

# --- backward-delete-char: delete + clear prediction + re-request ---
_eva_backward_delete_char() {
    zle .backward-delete-char
    POSTDISPLAY=""
    region_highlight=()
    _eva_request_predict
}

# --- accept-line: clear prediction before executing command ---
_eva_accept_line() {
    POSTDISPLAY=""
    region_highlight=()
    zle .accept-line
}

# --- expand-or-complete (Tab): accept prediction if present, else fallback to completion ---
_eva_expand_or_complete() {
    if [[ -n "$POSTDISPLAY" ]]; then
        BUFFER+="$POSTDISPLAY"
        CURSOR=$#BUFFER
        POSTDISPLAY=""
        region_highlight=()
        zle -R
    else
        zle .expand-or-complete
    fi
}

# --- Accept next word (Alt+Tab) ---
_eva_accept_word() {
    if [[ -n "$POSTDISPLAY" ]]; then
        local word="${POSTDISPLAY%% *}"
        if [[ "$word" == "$POSTDISPLAY" ]]; then
            BUFFER+="$POSTDISPLAY"
            CURSOR=$#BUFFER
            POSTDISPLAY=""
        else
            BUFFER+="$word "
            CURSOR=$#BUFFER
            POSTDISPLAY="${POSTDISPLAY#$word }"
            POSTDISPLAY="${POSTDISPLAY## }"
        fi
        region_highlight=()
        zle -R
    fi
}

# --- Clear prediction on ESC ---
_eva_clear() {
    POSTDISPLAY=""
    region_highlight=()
    zle -R
}


# --- Deferred init: runs once on first precmd, when ZLE is fully ready ---
_eva_init() {
    # Remove self from precmd
    precmd_functions=("${precmd_functions[@]:#_eva_init}")

    # Override built-in widgets (this is ALL we need — no bindkey!)
    zle -N self-insert _eva_self_insert
    zle -N backward-delete-char _eva_backward_delete_char
    zle -N accept-line _eva_accept_line
    zle -N expand-or-complete _eva_expand_or_complete
    zle -N accept-word _eva_accept_word
    zle -N clear-screen _eva_clear

    # Hook into line-pre-redraw to keep polling alive
    autoload -Uz add-zle-hook-widget
    add-zle-hook-widget line-pre-redraw _eva_start_polling 2>/dev/null || true

    # Ensure EVA_HOME exists
    mkdir -p "$EVA_HOME"

    # Start bridge and polling
    _eva_start_bridge
    _eva_start_polling
    _EVA_INITIALIZED=true
}

# Schedule init for first precmd (ZLE guaranteed ready)
precmd_functions+=(_eva_init)

# --- Public API ---
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

eva-restart() {
    _EVA_BRIDGE_OK=false
    _EVA_SEQ=0
    _EVA_LAST_SEQ=0
    POSTDISPLAY=""
    region_highlight=()
    _eva_start_bridge
    echo "eva bridge restarted"
}
