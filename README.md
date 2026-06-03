# eva — AI Shell Assistant

**eva** predicts your next shell command in real-time using AI (DeepSeek v4 Pro).
Type naturally — eva shows the prediction in grey. Press **Tab** to accept.

```
$ git com█                    # You type
$ git commit -m "fix bug"█   # eva predicts in grey, Tab accepts
```

## How it works

```
Keystroke → ZSH Plugin → Unix Socket → eva Daemon → DeepSeek API → Prediction → Grey text
```

- **ZSH plugin**: hooks into the line editor, captures each keystroke
- **eva daemon**: background process, debounces requests, calls the LLM
- **eva bridge**: async subprocess so ZSH never blocks

## Install

```bash
git clone https://github.com/yourname/eva.git
cd eva
bash install.sh
```

Open a new terminal and start typing!

## Requirements

- **Python 3.8+** with `openai` package (auto-installed)
- **ZSH 5.0+** (your default shell)
- **Linux** (Unix domain sockets)

## Usage

| Action | Key |
|--------|-----|
| See prediction | Just type — appears automatically in grey |
| Accept full prediction | **Tab** |
| Accept next word | **Alt+Tab** |
| Ignore prediction | Keep typing — it updates |

## Commands

```bash
eva-status                    # Check if daemon is running
eva-restart                   # Restart the bridge process
python3 ~/.eva/daemon.py stop    # Stop daemon
python3 ~/.eva/daemon.py status  # Daemon status
```

## Files

```
~/.eva/
├── predictor.py      # DeepSeek API client
├── daemon.py         # Unix socket server
├── eva-bridge        # ZSH ↔ daemon bridge
├── eva.plugin.zsh    # ZSH plugin (sourced from .zshrc)
├── apikey            # Your API key
├── eva.sock          # Unix socket (runtime)
├── eva.pid           # Daemon PID (runtime)
└── eva.log           # Log file (runtime)
```

## Configuration

| Env var | Default | Description |
|---------|---------|-------------|
| `EVA_API_KEY` | (built-in) | DeepSeek API key |
| `EVA_API_BASE` | `https://api.deepseek.com/v1` | API endpoint |
| `EVA_MODEL` | `deepseek-chat` | Model name |
| `EVA_HOME` | `~/.eva` | Install directory |
| `EVA_DEBOUNCE_MS` | `200` | Min ms between API calls |

## Project structure

```
eva/
├── src/
│   ├── predictor.py     # LLM client
│   └── daemon.py        # Background server
├── shell/
│   ├── eva.plugin.zsh   # ZSH integration
│   └── eva-bridge       # Async bridge
├── install.sh           # One-command installer
└── README.md
```
