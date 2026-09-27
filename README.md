# llama-tui

A terminal dashboard (TUI) to start, monitor and stop **`llama-server`** from [llama.cpp](https://github.com/ggml-org/llama.cpp), without editing scripts every time you switch models or parameters.

- Pick the `.gguf` model by browsing or searching your disk
- Tune the main server parameters, each with an explanation
- Start the server and watch its output live, with the addresses for remote access
- Stop the server, switch models and start again without leaving the program
- Save setups as **profiles** and run them straight from the shell, no TUI needed
- Detailed logs that are never overwritten

A single bash file, compatible with **macOS** (stock bash 3.2) and **Linux**.

---

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [The interface (TUI)](#the-interface-tui)
- [Parameters](#parameters)
- [Profiles](#profiles)
- [Command line (no TUI)](#command-line-no-tui)
- [Remote access](#remote-access)
- [Logs](#logs)
- [Files and folders](#files-and-folders)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Requirements

| Dependency | Required? | What for |
|---|---|---|
| `bash` 3.2+ | Yes | Ships with macOS and Linux |
| [`llama-server`](https://github.com/ggml-org/llama.cpp) | Yes | The server being launched |
| `dialog` | TUI only | Draws the interface. The shell commands work without it |
| `curl` | Recommended | Detects when the model has finished loading (`/health`) |

Installing `dialog`:

```bash
# macOS (Homebrew)
brew install dialog

# Debian / Ubuntu
sudo apt install dialog

# Fedora
sudo dnf install dialog

# Arch
sudo pacman -S dialog
```

If you don't have `llama-server` yet, the simplest route on macOS is `brew install llama.cpp`. You can also [build llama.cpp](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md) from source.

## Installation

```bash
git clone https://github.com/<your-username>/llama-tui.git
cd llama-tui
chmod +x llama-tui.sh
```

Optional: make the `llama-tui` command available from any folder:

```bash
mkdir -p ~/.local/bin
ln -s "$(pwd)/llama-tui.sh" ~/.local/bin/llama-tui
```

> Make sure `~/.local/bin` is on your `PATH` (`echo $PATH`). If it isn't, add `export PATH="$HOME/.local/bin:$PATH"` to your `~/.zshrc` or `~/.bashrc`.

## Quick start

```bash
./llama-tui.sh
```

1. **Select model**: pick the `.gguf` file
2. **Configure parameters**: set context, GPU layers, port, etc.
3. **Save current settings as a profile** (optional)
4. **START server**: wait for it to load and note the addresses shown
5. **View server output** to follow requests
6. **STOP server** when you want to switch models

The next time you open it, your last setup is restored.

## The interface (TUI)

Navigation: **arrows** or **Tab** to move, **Enter** to confirm, **Esc** to go back. You can also press an item's key (number or letter) to jump straight to it.

The top of the dashboard shows whether the server is running, the selected model, this machine's IPv4, the port, the context size and the GPU layers.

| Option | What it does |
|---|---|
| Select model | Lists the `.gguf` files in the search folders, filters by name, opens a file browser, or accepts a pasted path |
| Configure parameters | Edits each parameter. The bottom line explains the highlighted item; the edit screen shows the current value, and **Help** opens the full explanation. `?` shows help for all of them |
| Load saved profile | Loads a profile. You can also delete profiles here |
| Save current settings as a profile | Saves the model and parameters under a name |
| View generated command | Shows the exact command that will run, ready to copy |
| START server | Validates the setup, starts it in the background and shows loading progress live |
| View server output | Follows the log live. Enter or Esc returns to the menu without stopping the server |
| STOP server | Shuts the server down (SIGTERM; SIGKILL if it doesn't respond within 15 s) |
| Status and remote access addresses | PID, uptime, model, state (`ok` or `loading`) and access URLs |
| Logs | Shows the program log or any previous run log |
| Settings | `llama-server` path, search folders and maximum wait time while loading |

**Model search.** The default folders are `~/models`, `~/llama.cpp/models`, `~/.cache/llama.cpp`, `~/.cache/huggingface/hub` and `~/.lmstudio/models`. The search is recursive and follows symbolic links. `mmproj-*` files and parts 2+ of split models (`-00002-of-00003.gguf`) are hidden; just pick the first part.

**Validation before starting.** The program checks that `llama-server` exists, that the model exists and is readable, that numeric fields are valid and that the port is free. It also warns about risky setups, such as starting without an API key.

**Quitting while the server is running** lets you choose between **Stop and quit** or **Keep running** in the background. In the latter case, stop it later with `llama-tui stop`.

## Parameters

**An empty field means the parameter is not passed** and `llama-server` uses its own default.

In the list, press the parameter's **letter** (a, b, c...) or use the arrows and Enter. Each edit screen shows the flag, a short description and the current value; the **Help** button opens the full explanation. On/off and multiple-choice parameters are picked from a list, no typing needed.

> **The IP is not a parameter.** The server always listens on every interface (`--host 0.0.0.0`) so it can be reached remotely. llama-tui detects **this machine's IPv4** and only displays it on the dashboard, in Status and on the "Server ready" screen. To check it from the shell: `llama-tui ip`.

| Field | Flag | Description |
|---|---|---|
| Port | `--port` | TCP port. Default: `8080` |
| Context (tokens) | `-c` | Context window size. Larger values use much more memory. llama-tui default: `4096` |
| GPU layers | `-ngl` | `99` = everything on the GPU; `0` = CPU only. Lower it if you run out of memory. llama-tui default: `99` |
| CPU threads | `-t` | Usually the number of physical cores |
| Batch size | `-b` | Logical batch size for the prompt |
| Micro-batch | `-ub` | Physical batch size (≤ batch) |
| Parallel slots | `-np` | Simultaneous requests. **The context is split across slots** |
| Flash Attention | `-fa` | `auto` / `on` / `off`. Saves memory and is usually faster |
| KV cache type (K) | `-ctk` | `f16` / `q8_0` / `q4_0` |
| KV cache type (V) | `-ctv` | `f16` / `q8_0` / `q4_0` (usually requires Flash Attention `on`) |
| Lock in RAM | `--mlock` | Keeps the model out of swap |
| Disable mmap | `--no-mmap` | Loads the whole file into memory |
| Jinja template | `--jinja` | Uses the model's chat template; needed for tool calling. llama-tui default: on |
| Model alias | `--alias` | Name shown in `/v1/models` |
| API key | `--api-key` | Key clients must send. **Recommended for remote access** |
| Multimodal projector | `--mmproj` | `mmproj-*.gguf` file for vision models |
| Default temperature | `--temp` | `0.1`–`0.4` more precise; `0.6`–`0.8` balanced |
| Extra arguments | — | Any other option, as on the command line. Quotes are respected. E.g. `--top-k 40 --metrics` |

> **llama.cpp versions.** In recent versions `-fa` takes a value (`on|off|auto`); in older ones it's a bare flag. llama-tui checks `llama-server --help` and adapts automatically.

To see every option your `llama-server` supports: `llama-server --help`.

## Profiles

A profile is a plain text file with the model and parameters. It lives in:

```
~/.config/llama-tui/profiles/<name>.conf
```

Example (see also [`examples/qwen3-8b.conf`](examples/qwen3-8b.conf)):

```ini
MODEL=/Users/you/models/Qwen3-8B-Q4_K_M.gguf
PORT=8080
CTX=16384
NGL=99
FLASH=on
CTK=q8_0
CTV=q8_0
JINJA=1
ALIAS=qwen3-8b
APIKEY=my-secret-key
EXTRA=--top-k 40 --top-p 0.9
```

- `KEY=value` format, one per line; lines starting with `#` are comments
- An empty value means the parameter is not passed
- On/off parameters (`MLOCK`, `NOMMAP`, `JINJA`): `1` = on, empty = off
- The file is **not executed** as a script; only known keys are read
- Profiles are saved with mode `600` because they may contain the API key

You can create profiles in the TUI, edit them by hand, copy them between machines, or pass the path to a `.conf` directly to the commands.

## Command line (no TUI)

```bash
llama-tui run   <profile>    # foreground: output on screen and in the log; Ctrl+C stops
llama-tui start <profile>    # background: waits until loaded and shows the addresses
llama-tui stop               # stops the server started by llama-tui
llama-tui restart <profile>  # stops (if running) and starts with the profile
llama-tui status             # running? PID, model, addresses
llama-tui list               # lists saved profiles
llama-tui show  <profile>    # shows the command that would run
llama-tui logs               # last lines of the server log
llama-tui logs -f            # follows the server log live
llama-tui applog             # follows the program's own log
llama-tui ip                 # shows this machine's IPv4
llama-tui help               # help
```

`<profile>` can be the name of a saved profile or the path to a `.conf` file.

**Exit codes:** `0` ok · `1` error · `2` a server is already running · `3` no server running. Handy for scripts:

```bash
llama-tui status >/dev/null || llama-tui start qwen3-8b
```

The TUI and the command line share the same state: a server started with `start` shows up in the TUI, and a server left running from the TUI can be stopped with `llama-tui stop`. Only one managed server runs at a time.

## Remote access

The server is reachable from your network out of the box. This machine's IPv4 is shown at the top of the dashboard (and by `llama-tui ip`).

1. Set an **API key**
2. Start the server and read the addresses on the final screen or in **Status** (e.g. `http://192.168.0.10:8080`)

From another computer's browser, open `http://<ip>:<port>` for the llama.cpp web UI.

As an OpenAI-compatible API, use `http://<ip>:<port>/v1`:

```bash
curl http://192.168.0.10:8080/v1/chat/completions \
  -H "Authorization: Bearer my-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-8b","messages":[{"role":"user","content":"Hello!"}]}'
```

> If another machine can't connect, check the firewall (on macOS: System Settings → Network → Firewall) and that both machines are on the same network. For access over the internet, prefer a VPN (Tailscale, WireGuard) over opening the port on your router.

## Logs

All logs live in `~/.local/state/llama-tui/logs/`:

| File | Contents |
|---|---|
| `llama-tui.log` | Everything the program did: date, time, level (`INFO`/`WARN`/`ERROR`), PID, actions, commands run, validation failures, server start and stop |
| `llama-tui-YYYYMMDD-HHMMSS.log` | Older program logs. Past 5 MB the log is **renamed**, never deleted |
| `server-YYYYMMDD-HHMMSS-<model>.log` | A **new file for every** server run, starting with the date, profile, model and exact command, followed by all of `llama-server`'s output |

The API key is never written to the logs; it shows up as `********`.

If something goes wrong, start with:

```bash
llama-tui logs          # output of the last server
tail -n 50 ~/.local/state/llama-tui/logs/llama-tui.log
```

## Files and folders

| Path | Contents |
|---|---|
| `~/.config/llama-tui/profiles/` | Profiles (`<name>.conf`) |
| `~/.config/llama-tui/settings.conf` | `llama-server` path, search folders, wait time |
| `~/.config/llama-tui/last-session.conf` | Last setup used in the TUI |
| `~/.local/state/llama-tui/logs/` | Logs |
| `~/.local/state/llama-tui/server.pid` / `server.info` | State of the running server |

The folders honor `XDG_CONFIG_HOME` and `XDG_STATE_HOME`, and can be changed with the `LLAMA_TUI_CONFIG_DIR` and `LLAMA_TUI_STATE_DIR` variables.

**Uninstall:** delete the script, the `~/.local/bin/llama-tui` link (if you created it) and the `~/.config/llama-tui` and `~/.local/state/llama-tui` folders.

## Troubleshooting

| Problem | What to do |
|---|---|
| `The TUI needs the 'dialog' program` | Install `dialog` (see [Requirements](#requirements)) |
| `llama-server not found` | Set its path in **Settings**, or put the executable on your `PATH`. Locations checked automatically: `PATH`, `~/llama.cpp/build/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` |
| `Port X is already in use` | Pick another port, or see what's using it: `lsof -iTCP:8080 -sTCP:LISTEN` |
| The server exits while loading | Usually not enough memory: lower **Context** or **GPU layers**, or use a `q8_0` KV cache. The error screen shows the last log lines |
| `error: invalid argument` in the log | Your `llama-server` doesn't know one of the parameters. Update llama.cpp or clear that field |
| No models found | Add your models folder under **Select model → Manage search folders** |
| Garbled characters in the TUI | Use a UTF-8 terminal (`echo $LANG` should end in `UTF-8`) |
| Loading exceeded the time limit | The server keeps loading; follow it in **View server output**. Raise the limit in **Settings** |

## License

[MIT](LICENSE)

---

Independent project, not officially affiliated with llama.cpp.
