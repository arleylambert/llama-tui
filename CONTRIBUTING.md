# Contributing

Suggestions and fixes are welcome! Please open an *issue* describing the problem or idea before sending large changes.

## Reporting a problem

Please include:
- Operating system and version (`uname -a`)
- bash version (`bash --version`) and dialog version (`dialog --version`)
- llama.cpp version (`llama-server --version`)
- The relevant lines from `~/.local/state/llama-tui/logs/llama-tui.log` and from the server log (`llama-tui logs`)

Review the logs before pasting and remove any paths or personal details you don't want to share.

## Changing the code

- Keep compatibility with **bash 3.2** (the one on macOS): no associative arrays (`declare -A`), `mapfile`, `${var,,}` or `local -n`
- Inside one `local` statement, don't reference a variable declared earlier in that same statement (bash expands every word first); split it into two `local` lines
- Run `bash -n llama-tui.sh` and, if possible, [`shellcheck`](https://www.shellcheck.net/) `llama-tui.sh`
- Test on macOS and Linux when you can
- New server parameters are declared with `defparam` (key, type, flag, label, short help, documentation); the TUI, validation, profiles and command adapt automatically
- Record the change in [CHANGELOG.md](CHANGELOG.md)
