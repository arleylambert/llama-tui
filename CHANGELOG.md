# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.2.0] - 2026-09-26

### Changed
- The interface, messages, logs, command-line output and documentation are now in English
- Main menu keys: `S` opens Settings and `Q` quits (previously `C` and `S`)
- Profiles and settings files from earlier versions keep working unchanged

## [1.1.0] - 2026-09-26

### Fixed
- Editing a parameter always changed "Extra arguments" instead of the chosen parameter, and the field opened empty (the `i` variable was expanded before being declared)
- Help texts were jumbled because `dialog` merged line breaks (now uses `--cr-wrap`)
- Typing two-digit numbers (10, 11...) in menus jumped to the wrong item; items now use letters
- The parameter list was one line taller than the screen on 24-line terminals

### Changed
- The IP is no longer a parameter: the server always listens on `0.0.0.0` and the machine's IPv4 is detected and displayed as information. The `HOST` key in older profiles is ignored
- Compact edit screen (flag, short description, current value) with a **Help** button for the full explanation
- On/off and multiple-choice parameters became simple lists (arrows + Enter), no need to mark with Space
- An invalid value keeps the screen open with what was typed instead of discarding it
- Faster Esc key (250 ms)

### Added
- `llama-tui ip` command

## [1.0.0] - 2026-09-26

### Added
- TUI (`dialog`) to pick the `.gguf` model, configure parameters and control `llama-server`
- Model search in the configured folders, by name filter, file browser or typed path
- 18 parameters with detailed help, plus an extra-arguments field
- Validation before starting: executable, model, numbers, free port and security warnings
- Start, watch live and stop the server without leaving the program
- Profiles saved in `~/.config/llama-tui/profiles/` and restoring the last session
- Shell commands: `run`, `start`, `stop`, `restart`, `status`, `list`, `show`, `logs`, `applog`
- Program log with rotation by renaming, and a new log for every server run
- Automatic detection of the `--flash-attn` syntax for the installed llama.cpp version
