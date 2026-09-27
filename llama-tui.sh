#!/usr/bin/env bash
# =============================================================================
#  llama-tui.sh - TUI launcher for llama-server (llama.cpp)
#
#  Quick usage:
#    ./llama-tui.sh                  open the interface (TUI)
#    ./llama-tui.sh run   <profile>  run the server in the foreground (Ctrl+C stops)
#    ./llama-tui.sh start <profile>  start in the background
#    ./llama-tui.sh stop             stop the running server
#    ./llama-tui.sh help             full help
#
#  Works with bash 3.2 (macOS) and Linux. The TUI requires "dialog".
# =============================================================================

VERSION="1.2.0"
PROG="$(basename "$0")"

# ----------------------------------------------------------------------------
# Directories (follow XDG; can be overridden with environment variables)
# ----------------------------------------------------------------------------
CONFIG_DIR="${LLAMA_TUI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/llama-tui}"
STATE_DIR="${LLAMA_TUI_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/llama-tui}"
PROFILE_DIR="$CONFIG_DIR/profiles"
LOG_DIR="$STATE_DIR/logs"
SETTINGS_FILE="$CONFIG_DIR/settings.conf"
LAST_FILE="$CONFIG_DIR/last-session.conf"
PID_FILE="$STATE_DIR/server.pid"
RUNINFO_FILE="$STATE_DIR/server.info"
APP_LOG="$LOG_DIR/llama-tui.log"
APP_LOG_MAX_BYTES=$((5 * 1024 * 1024))   # above this the log is archived (never deleted)

mkdir -p "$PROFILE_DIR" "$LOG_DIR" 2>/dev/null || {
    echo "ERROR: could not create $PROFILE_DIR or $LOG_DIR" >&2
    exit 1
}
chmod 700 "$CONFIG_DIR" 2>/dev/null

# ----------------------------------------------------------------------------
# Application log: always appended; rotated by renaming with a timestamp
# ----------------------------------------------------------------------------
rotate_app_log() {
    [ -f "$APP_LOG" ] || return 0
    local size
    size=$(wc -c <"$APP_LOG" 2>/dev/null | tr -d ' ')
    if [ -n "$size" ] && [ "$size" -gt "$APP_LOG_MAX_BYTES" ]; then
        mv "$APP_LOG" "$LOG_DIR/llama-tui-$(date +%Y%m%d-%H%M%S).log"
    fi
}

log() {  # log LEVEL message...
    local level="$1"; shift
    printf '%s [%-5s] [pid %s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$$" "$*" >>"$APP_LOG"
}
log_info()  { log INFO  "$@"; }
log_warn()  { log WARN  "$@"; }
log_error() { log ERROR "$@"; }

rotate_app_log

# ----------------------------------------------------------------------------
# Parameter definitions
#   Each parameter: key | type | llama-server flag | label | short help | documentation
#   Types: text, int, float, bool, choice:<opt1>,<opt2>,...
#   Empty value = the parameter is NOT passed (llama-server uses its own default)
# ----------------------------------------------------------------------------
P_KEYS=();  P_TYPE=(); P_FLAG=(); P_LABEL=(); P_SHORT=(); P_DOC=()

defparam() {
    P_KEYS+=("$1"); P_TYPE+=("$2"); P_FLAG+=("$3"); P_LABEL+=("$4"); P_SHORT+=("$5"); P_DOC+=("$6")
}

defparam PORT int "--port" "Port" \
 "Server TCP port (e.g. 8080)." \
"TCP port the server listens on (--port).

Once started, open http://<ip>:<port> in a browser for the web UI,
or use http://<ip>:<port>/v1 as an OpenAI-compatible API endpoint.

The port must be free. Ports below 1024 require root.
llama-server default: 8080"

defparam CTX int "-c" "Context (tokens)" \
 "Context window size in tokens (-c / --ctx-size)." \
"Maximum context size in tokens (-c / --ctx-size).

This is how much text (prompt + reply + history) the model can
\"remember\" at once. Larger values use MUCH more memory
(RAM/VRAM) because of the KV cache.

Examples: 4096, 8192, 16384, 32768.
0 = use the model's training value (can be huge!).
With --parallel N, the context is split across the N slots."

defparam NGL int "-ngl" "GPU layers" \
 "How many model layers go to the GPU (-ngl). 99 = all." \
"Number of model layers loaded on the GPU (-ngl / --n-gpu-layers).

  99 (or more than the layer count) -> everything on the GPU (fastest).
  0  -> everything on the CPU.
  In between -> split between GPU and CPU when the model does not
  fit entirely in VRAM.

On macOS (Apple Silicon/Metal) you normally use 99.
If you get an out-of-memory error, lower this value."

defparam THREADS int "-t" "CPU threads" \
 "CPU threads used for generation (-t). Empty = automatic." \
"Number of CPU threads used for generation (-t / --threads).

Empty = llama-server picks automatically.
The best value is usually the number of PHYSICAL (not logical) cores.
Has little effect when all layers are on the GPU."

defparam BATCH int "-b" "Batch size" \
 "Logical batch size for prompt processing (-b)." \
"Maximum logical batch size (-b / --batch-size).

Affects prompt processing (prefill) speed.
Empty = llama-server default (2048). Larger values can speed up
long prompts but use more memory."

defparam UBATCH int "-ub" "Micro-batch" \
 "Physical batch size (-ub / --ubatch-size)." \
"Maximum physical batch size (-ub / --ubatch-size).

Must be less than or equal to the batch size.
Empty = llama-server default (512). Raising it (e.g. 1024, 2048)
can speed up prefill on GPUs with plenty of memory."

defparam PARALLEL int "-np" "Parallel slots" \
 "How many requests the server handles at once (-np)." \
"Number of parallel processing slots (-np / --parallel).

Each slot serves one conversation/request at a time.
WARNING: the context (-c) is split across slots. E.g. -c 16384
with -np 4 gives each request 4096 tokens.
Empty = llama-server default."

defparam FLASH "choice:,auto,on,off" "-fa" "Flash Attention" \
 "Enables Flash Attention (-fa). Saves memory and speeds things up." \
"Flash Attention (-fa / --flash-attn).

  (empty) -> the parameter is not passed (llama-server default).
  auto    -> llama-server decides.
  on      -> forced on. Reduces memory use and is usually faster.
  off     -> forced off.

Required to quantize the V part of the KV cache (cache-type-v).
Older llama-server versions take no value for this flag;
this program detects that and adapts automatically."

defparam CTK "choice:,f16,q8_0,q4_0" "-ctk" "KV cache type (K)" \
 "K cache quantization (-ctk). q8_0 saves memory." \
"KV cache data type for K (-ctk / --cache-type-k).

  (empty) -> default (f16).
  q8_0    -> half the memory, almost no quality loss.
  q4_0    -> a quarter of the memory, some quality loss.

Useful to fit large contexts in memory."

defparam CTV "choice:,f16,q8_0,q4_0" "-ctv" "KV cache type (V)" \
 "V cache quantization (-ctv). Requires Flash Attention." \
"KV cache data type for V (-ctv / --cache-type-v).

Same options as the K cache. Quantizing V usually requires
Flash Attention to be on (-fa on)."

defparam MLOCK bool "--mlock" "Lock in RAM (mlock)" \
 "Prevents the OS from swapping the model out." \
"--mlock: forces the OS to keep the model in RAM, never in swap.

Avoids slowdowns from paging, but needs enough RAM, and on some
Linux systems you may need to raise the limit (ulimit -l)."

defparam NOMMAP bool "--no-mmap" "Disable mmap" \
 "Loads the whole model into memory instead of mapping the file." \
"--no-mmap: disables memory-mapping the model file.

With mmap (default) the model loads faster and shares pages with
the OS file cache. Disabling it can help with slow disks or some
partial-GPU setups, but loading becomes slower."

defparam JINJA bool "--jinja" "Jinja template" \
 "Uses the model's Jinja chat template (needed for tool calling)." \
"--jinja: uses the chat template embedded in the GGUF (Jinja format).

Recommended for modern models and REQUIRED for function/tool
calling through the OpenAI API."

defparam ALIAS text "--alias" "Model alias" \
 "Model name shown by the API (/v1/models)." \
"--alias: name the model is listed under in the API (/v1/models),
which clients can use in the \"model\" field.

Empty = llama-server uses the file path/name."

defparam APIKEY text "--api-key" "API key" \
 "Key clients must send (recommended for remote access)." \
"--api-key: requires clients to send this key in the header
Authorization: Bearer <key>.

STRONGLY recommended: the server is reachable from your whole network.
The web UI will also ask for the key.
Note: the key is stored as plain text in the profile (file mode 600)."

defparam MMPROJ text "--mmproj" "Multimodal projector" \
 "mmproj*.gguf file for vision models (images)." \
"--mmproj: path to the multimodal projector file (mmproj-*.gguf).

Only needed for vision models (models that understand images).
The file usually ships alongside the model on Hugging Face.
Empty = not used."

defparam TEMP float "--temp" "Default temperature" \
 "Default response creativity (0.0 to 2.0)." \
"--temp: default sampling temperature.

  Low (0.1-0.4)    -> more deterministic/precise answers.
  Medium (0.6-0.8) -> balanced (good for chat).
  High (>1.0)      -> more creative and less coherent.

Clients can override it on each request.
Empty = llama-server default (0.8)."

defparam EXTRA text "" "Extra arguments" \
 "Any other llama-server argument, as on the command line." \
"Extra arguments passed verbatim to llama-server.

Use it for any option not in this list. Examples:
  --top-k 40 --top-p 0.9
  --cont-batching --metrics
  --rope-scaling yarn --rope-scale 4
  --chat-template chatml
  --override-tensor \"exps=CPU\"

Quotes are respected. See every option with:
  llama-server --help"

# Initial values (defaults on first launch)
MODEL=""
PORT="8080"; CTX="4096"; NGL="99"; THREADS=""; BATCH=""; UBATCH=""
PARALLEL=""; FLASH=""; CTK=""; CTV=""; MLOCK=""; NOMMAP=""; JINJA="1"; ALIAS=""
APIKEY=""; MMPROJ=""; TEMP=""; EXTRA=""
CURRENT_PROFILE=""

# General settings (settings.conf)
LLAMA_BIN=""
MODEL_DIRS="$HOME/models:$HOME/llama.cpp/models:$HOME/.cache/llama.cpp:$HOME/.cache/huggingface/hub:$HOME/.lmstudio/models"
STARTUP_TIMEOUT="300"

PROFILE_KEYS="MODEL ${P_KEYS[*]}"
LEGACY_KEYS="HOST"   # keys from older versions: accepted in profiles and ignored

# The server always listens on all interfaces (0.0.0.0) to allow remote access.
# The IP is not a parameter: it is detected from the machine and only displayed.
BIND_HOST="0.0.0.0"
SETTINGS_KEYS="LLAMA_BIN MODEL_DIRS STARTUP_TIMEOUT"

# ----------------------------------------------------------------------------
# Reading/writing KEY=value files (no "source": only allowed keys are read)
# ----------------------------------------------------------------------------
load_kv_file() {  # load_kv_file file "ALLOWED KEYS"
    local file="$1" allowed=" $2 " line key val n=0
    [ -r "$file" ] || { log_warn "File not found/unreadable: $file"; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        key="${line%%=*}"; val="${line#*=}"
        case " $LEGACY_KEYS " in *" $key "*) continue ;; esac
        case "$allowed" in
            *" $key "*) eval "$key=\$val"; n=$((n + 1)) ;;
            *) log_warn "Unknown key ignored in $file: $key" ;;
        esac
    done <"$file"
    log_info "Loaded $file ($n keys)"
    return 0
}

save_kv_file() {  # save_kv_file file "KEYS" "comment"
    local file="$1" keys="$2" comment="$3" k tmp
    tmp="$file.tmp.$$"
    {
        echo "# $comment"
        echo "# Generated by llama-tui $VERSION on $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# Format: KEY=value (empty = do not pass the parameter)"
        for k in $keys; do
            eval "printf '%s=%s\n' \"\$k\" \"\${$k}\""
        done
    } >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file"
    local rc=$?
    if [ $rc -eq 0 ]; then log_info "Saved $file"; else log_error "Failed to save $file (rc=$rc)"; rm -f "$tmp"; fi
    return $rc
}

reset_params() {
    MODEL=""; PORT="8080"; CTX="4096"; NGL="99"; THREADS=""; BATCH=""
    UBATCH=""; PARALLEL=""; FLASH=""; CTK=""; CTV=""; MLOCK=""; NOMMAP=""; JINJA="1"
    ALIAS=""; APIKEY=""; MMPROJ=""; TEMP=""; EXTRA=""
}

load_profile() {  # name or path
    local p="$1" f
    if [ -f "$p" ]; then f="$p"; else f="$PROFILE_DIR/$p.conf"; fi
    [ -f "$f" ] || { log_error "Profile not found: $p"; return 1; }
    reset_params
    load_kv_file "$f" "$PROFILE_KEYS" || return 1
    CURRENT_PROFILE="$(basename "$f" .conf)"
}

list_profiles() {
    local f
    for f in "$PROFILE_DIR"/*.conf; do
        [ -f "$f" ] && basename "$f" .conf
    done
}

save_settings() { save_kv_file "$SETTINGS_FILE" "$SETTINGS_KEYS" "llama-tui general settings"; }
save_last()     { save_kv_file "$LAST_FILE" "$PROFILE_KEYS" "Last session (restored when the TUI opens)" >/dev/null; }

[ -f "$SETTINGS_FILE" ] && load_kv_file "$SETTINGS_FILE" "$SETTINGS_KEYS"

# ----------------------------------------------------------------------------
# Utilities
# ----------------------------------------------------------------------------
param_index() {  # prints the index of a key in P_KEYS
    local i
    for i in "${!P_KEYS[@]}"; do
        [ "${P_KEYS[$i]}" = "$1" ] && { echo "$i"; return 0; }
    done
    return 1
}

get_var() { eval "printf '%s' \"\${$1}\""; }

human_size() {  # bytes -> text
    awk -v b="$1" 'BEGIN{ split("B KB MB GB TB",u," "); i=1; while (b>=1024 && i<5){b/=1024;i++} printf (i==1?"%d %s":"%.1f %s"), b, u[i] }'
}

file_size() { wc -c <"$1" 2>/dev/null | tr -d ' '; }

cpu_count() {
    getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "?"
}

is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
        [ "$o" -le 255 ] || return 1
    done
    return 0
}

local_ips() {  # every IPv4 address of this machine, except loopback
    {
        if command -v ip >/dev/null 2>&1; then
            ip -4 -o addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}'
        fi
        if command -v ifconfig >/dev/null 2>&1; then
            ifconfig 2>/dev/null | awk '$1=="inet"{ip=$2; sub("addr:","",ip); print ip}'
        fi
    } | while IFS= read -r ip; do
        case "$ip" in 127.*|169.254.*|'') continue ;; esac
        is_ipv4 "$ip" && echo "$ip"
    done | awk '!seen[$0]++'
}

primary_ip() {  # main IPv4 (default route interface); fallback: first IPv4 found
    local ip="" ifc
    if command -v ip >/dev/null 2>&1; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')"
    fi
    if [ -z "$ip" ] && command -v route >/dev/null 2>&1 && command -v ipconfig >/dev/null 2>&1; then
        ifc="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
        [ -n "$ifc" ] && ip="$(ipconfig getifaddr "$ifc" 2>/dev/null)"
    fi
    is_ipv4 "$ip" || ip="$(local_ips | head -n 1)"
    if is_ipv4 "$ip"; then echo "$ip"; else echo "127.0.0.1"; return 1; fi
}

port_in_use() {  # 0 = port is taken
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

split_args() {  # split_args "string" -> fills the SPLIT array (respects quotes)
    SPLIT=()
    local a
    [ -z "${1//[[:space:]]/}" ] && return 0
    while IFS= read -r -d '' a; do SPLIT+=("$a"); done < <(printf '%s' "$1" | xargs printf '%s\0' 2>/dev/null)
    return 0
}

quote_cmd() {  # prints an array as a copy-pasteable shell command
    local out="" a
    for a in "$@"; do out="$out $(printf '%q' "$a")"; done
    printf '%s' "${out# }"
}

mask_cmd() {  # hides the API key value in displayed text
    local s="$1"
    local q; q="$(printf '%q' "$APIKEY")"
    [ -n "$APIKEY" ] && s="${s//"$q"/********}"
    printf '%s' "$s"
}

# ----------------------------------------------------------------------------
# Locating llama-server
# ----------------------------------------------------------------------------
find_llama_bin() {
    local c
    if [ -n "$LLAMA_BIN" ] && [ -x "$LLAMA_BIN" ]; then echo "$LLAMA_BIN"; return 0; fi
    c="$(command -v llama-server 2>/dev/null)" && [ -n "$c" ] && { echo "$c"; return 0; }
    for c in "$HOME/llama.cpp/build/bin/llama-server" "$HOME/llama.cpp/llama-server" \
             "$HOME/src/llama.cpp/build/bin/llama-server" "/opt/homebrew/bin/llama-server" \
             "/usr/local/bin/llama-server" "$HOME/.local/bin/llama-server"; do
        [ -x "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

LLAMA_HELP_CACHE=""
llama_help() {
    if [ -z "$LLAMA_HELP_CACHE" ]; then
        local bin; bin="$(find_llama_bin)" || return 1
        LLAMA_HELP_CACHE="$("$bin" --help 2>&1)"
    fi
    printf '%s' "$LLAMA_HELP_CACHE"
}

flash_takes_value() {  # newer versions: -fa on|off|auto ; older: -fa (no value)
    llama_help | grep -E -- '--flash-attn' | grep -Eq 'on\|off|auto'
}

# ----------------------------------------------------------------------------
# Building and validating the command
# ----------------------------------------------------------------------------
CMD=()
build_cmd() {
    local bin i key type flag val
    bin="$(find_llama_bin)" || bin="llama-server"
    CMD=("$bin" -m "$MODEL" --host "$BIND_HOST")
    for i in "${!P_KEYS[@]}"; do
        key="${P_KEYS[$i]}"; type="${P_TYPE[$i]}"; flag="${P_FLAG[$i]}"
        val="$(get_var "$key")"
        [ -z "$val" ] && continue
        case "$key" in
            EXTRA) split_args "$val"; [ ${#SPLIT[@]} -gt 0 ] && CMD+=("${SPLIT[@]}"); continue ;;
            FLASH)
                if flash_takes_value; then CMD+=("$flag" "$val")
                elif [ "$val" = "on" ]; then CMD+=("$flag")
                fi
                continue ;;
        esac
        case "$type" in
            bool) CMD+=("$flag") ;;
            *)    CMD+=("$flag" "$val") ;;
        esac
    done
}

VALIDATION_ERRORS=""; VALIDATION_WARNINGS=""
validate_config() {  # returns 1 on a blocking error
    VALIDATION_ERRORS=""; VALIDATION_WARNINGS=""
    local i key type val bin
    if ! bin="$(find_llama_bin)"; then
        VALIDATION_ERRORS="${VALIDATION_ERRORS}- llama-server not found. Set its path in 'Settings' or put it on your PATH.\n"
    fi
    if [ -z "$MODEL" ]; then
        VALIDATION_ERRORS="${VALIDATION_ERRORS}- No model selected.\n"
    elif [ ! -f "$MODEL" ]; then
        VALIDATION_ERRORS="${VALIDATION_ERRORS}- Model file does not exist: $MODEL\n"
    elif [ ! -r "$MODEL" ]; then
        VALIDATION_ERRORS="${VALIDATION_ERRORS}- No read permission on the model: $MODEL\n"
    fi
    for i in "${!P_KEYS[@]}"; do
        key="${P_KEYS[$i]}"; type="${P_TYPE[$i]}"; val="$(get_var "$key")"
        [ -z "$val" ] && continue
        case "$type" in
            int)   [[ "$val" =~ ^-?[0-9]+$ ]] || VALIDATION_ERRORS="${VALIDATION_ERRORS}- ${P_LABEL[$i]} must be a whole number (current: '$val').\n" ;;
            float) [[ "$val" =~ ^[0-9]*\.?[0-9]+$ ]] || VALIDATION_ERRORS="${VALIDATION_ERRORS}- ${P_LABEL[$i]} must be a number (e.g. 0.7) (current: '$val').\n" ;;
        esac
    done
    if [ -n "$PORT" ] && [[ "$PORT" =~ ^[0-9]+$ ]]; then
        if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            VALIDATION_ERRORS="${VALIDATION_ERRORS}- Port must be between 1 and 65535.\n"
        elif ! server_pid >/dev/null && port_in_use "$PORT"; then
            VALIDATION_ERRORS="${VALIDATION_ERRORS}- Port $PORT is already in use by another program. Pick another port or close the program using it.\n"
        fi
    fi
    if [ -n "$MMPROJ" ] && [ ! -f "$MMPROJ" ]; then
        VALIDATION_ERRORS="${VALIDATION_ERRORS}- mmproj file does not exist: $MMPROJ\n"
    fi
    if [ -z "$APIKEY" ]; then
        VALIDATION_WARNINGS="${VALIDATION_WARNINGS}- No API key: anyone on your network will be able to use the server.\n"
    fi
    if [ -n "$CTV" ] && [ "$CTV" != "f16" ] && { [ -z "$FLASH" ] || [ "$FLASH" = "off" ]; }; then
        VALIDATION_WARNINGS="${VALIDATION_WARNINGS}- Quantized V cache ($CTV) usually requires Flash Attention = on.\n"
    fi
    [ -n "$VALIDATION_ERRORS" ] && { log_warn "Validation failed: $(printf '%b' "$VALIDATION_ERRORS" | tr '\n' ' ')"; return 1; }
    return 0
}

# ----------------------------------------------------------------------------
# Server process control
# ----------------------------------------------------------------------------
server_pid() {  # prints the PID if the managed server is alive
    local pid
    [ -f "$PID_FILE" ] || return 1
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "$pid"; return 0
    fi
    log_info "Removed stale PID file (pid=$pid)"
    rm -f "$PID_FILE"
    return 1
}

runinfo_get() {  # runinfo_get KEY
    [ -f "$RUNINFO_FILE" ] || return 1
    sed -n "s/^$1=//p" "$RUNINFO_FILE" | head -n 1
}

last_server_log() {
    local l; l="$(runinfo_get LOG)"
    if [ -n "$l" ] && [ -f "$l" ]; then echo "$l"; return 0; fi
    ls -1t "$LOG_DIR"/server-*.log 2>/dev/null | head -n 1
}

health_status() {  # health_status port -> ok | loading | down
    local port="$1" code
    command -v curl >/dev/null 2>&1 || { port_in_use "$port" && echo ok || echo down; return; }
    code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$port/health" 2>/dev/null)"
    case "$code" in
        200) echo ok ;;
        503) echo loading ;;
        *)   echo down ;;
    esac
}

# Starts in the background. Sets SERVER_LOG. Returns 0 if the process came up.
SERVER_LOG=""
start_server_bg() {
    local pid safe_name
    if pid="$(server_pid)"; then
        log_warn "Start attempted while a server is already running (pid=$pid)"
        echo "A server is already running (PID $pid). Stop it first." >&2
        return 2
    fi
    build_cmd
    safe_name="$(printf %s "$(basename "$MODEL" .gguf)" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-60)"
    SERVER_LOG="$LOG_DIR/server-$(date +%Y%m%d-%H%M%S)-$safe_name.log"
    {
        echo "=================================================================="
        echo " llama-tui $VERSION - started: $(date '+%Y-%m-%d %H:%M:%S')"
        echo " Profile: ${CURRENT_PROFILE:-(no profile)}"
        echo " Model  : $MODEL"
        echo " Command: $(mask_cmd "$(quote_cmd "${CMD[@]}")")"
        echo "=================================================================="
    } >>"$SERVER_LOG"
    log_info "Starting server: $(mask_cmd "$(quote_cmd "${CMD[@]}")")"
    log_info "Server log: $SERVER_LOG"

    nohup "${CMD[@]}" >>"$SERVER_LOG" 2>&1 </dev/null &
    pid=$!
    echo "$pid" >"$PID_FILE"
    {
        echo "PID=$pid"; echo "LOG=$SERVER_LOG"; echo "IP=$(primary_ip)"; echo "PORT=${PORT:-8080}"
        echo "MODEL=$MODEL"; echo "PROFILE=$CURRENT_PROFILE"; echo "STARTED=$(date '+%Y-%m-%d %H:%M:%S')"
    } >"$RUNINFO_FILE"
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        log_error "Server exited immediately (pid=$pid). See $SERVER_LOG"
        rm -f "$PID_FILE"
        return 1
    fi
    log_info "Server started (pid=$pid)"
    return 0
}

stop_server() {  # stops the server; returns 0 if it stopped
    local pid i
    pid="$(server_pid)" || { log_info "Stop requested, but no server is running"; return 3; }
    log_info "Stopping server (pid=$pid) with SIGTERM"
    kill -TERM "$pid" 2>/dev/null
    for i in $(seq 1 30); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        log_warn "Server did not respond to SIGTERM within 15s; sending SIGKILL (pid=$pid)"
        kill -KILL "$pid" 2>/dev/null
        sleep 1
    fi
    if kill -0 "$pid" 2>/dev/null; then
        log_error "Failed to stop the server (pid=$pid)"
        return 1
    fi
    local l; l="$(runinfo_get LOG)"
    [ -n "$l" ] && echo "=== Server stopped by llama-tui on $(date '+%Y-%m-%d %H:%M:%S') ===" >>"$l"
    rm -f "$PID_FILE"
    log_info "Server stopped (pid=$pid)"
    return 0
}

access_urls() {  # prints the access URLs for the port
    local port="${1:-8080}" main ip
    main="$(primary_ip)"
    echo "  Network (main) : http://$main:$port"
    for ip in $(local_ips); do
        [ "$ip" != "$main" ] && echo "  Network (other): http://$ip:$port"
    done
    echo "  This machine   : http://127.0.0.1:$port"
}

# =============================================================================
#  CLI MODE (no TUI)
# =============================================================================
cli_help() {
cat <<EOF
llama-tui $VERSION - launcher for llama-server (llama.cpp)

USAGE
  $PROG                      Open the TUI (requires 'dialog')
  $PROG run   <profile>      Run in the foreground, output on screen + log (Ctrl+C stops)
  $PROG start <profile>      Start in the background and wait until ready
  $PROG stop                 Stop the server started by llama-tui
  $PROG restart <profile>    Stop (if running) and start with the profile
  $PROG status               Show whether the server is running and its addresses
  $PROG list                 List saved profiles
  $PROG show  <profile>      Show the command that would be run
  $PROG logs  [-f]           Show (or follow with -f) the latest server log
  $PROG applog               Follow the program's own log
  $PROG ip                   Show this machine's IPv4 (used for remote access)
  $PROG help                 This help

  <profile> can be the name of a saved profile or the path to a .conf file

FILES
  Profiles    : $PROFILE_DIR/<name>.conf
  Settings    : $SETTINGS_FILE
  App log     : $APP_LOG   (append-only; archived past 5 MB)
  Server logs : $LOG_DIR/server-<date>-<model>.log  (one per run)

EXIT CODES
  0 ok | 1 error | 2 server already running | 3 no server running
EOF
}

cli_require_profile() {
    [ -n "$1" ] || { echo "ERROR: give a profile name. Available profiles:" >&2; list_profiles | sed 's/^/  /' >&2; exit 1; }
    load_profile "$1" || { echo "ERROR: profile '$1' not found in $PROFILE_DIR" >&2; exit 1; }
}

cli_validate() {
    if ! validate_config; then
        echo "ERROR: invalid configuration:" >&2
        printf '%b' "$VALIDATION_ERRORS" >&2
        exit 1
    fi
    [ -n "$VALIDATION_WARNINGS" ] && { echo "WARNING:" >&2; printf '%b' "$VALIDATION_WARNINGS" >&2; }
}

cli_wait_ready() {
    local port="$1" pid="$2" t=0 st
    printf 'Waiting for the model to load'
    while [ "$t" -lt "$STARTUP_TIMEOUT" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo; echo "ERROR: the server exited while loading. Last log lines:" >&2
            tail -n 25 "$SERVER_LOG" >&2
            echo "Full log: $SERVER_LOG" >&2
            rm -f "$PID_FILE"
            log_error "Server died while loading (pid=$pid)"
            return 1
        fi
        st="$(health_status "$port")"
        [ "$st" = "ok" ] && { echo " ready! (${t}s)"; log_info "Server ready in ${t}s"; return 0; }
        printf '.'; sleep 2; t=$((t + 2))
    done
    echo; echo "WARNING: ${STARTUP_TIMEOUT}s timeout reached; the server is still loading. Follow it with: $PROG logs -f"
    log_warn "Startup timeout (${STARTUP_TIMEOUT}s)"
    return 0
}

cli_main() {
    local cmd="$1"; shift
    log_info "CLI: $cmd $*"
    case "$cmd" in
        help|-h|--help) cli_help ;;
        version|-v|--version) echo "llama-tui $VERSION" ;;
        list)
            local p n=0
            for p in $(list_profiles); do
                printf '  %-25s %s\n' "$p" "$(sed -n 's/^MODEL=//p' "$PROFILE_DIR/$p.conf" | head -n 1)"; n=$((n + 1))
            done
            [ $n -eq 0 ] && echo "No saved profiles in $PROFILE_DIR"
            ;;
        show)
            cli_require_profile "$1"; build_cmd
            quote_cmd "${CMD[@]}"; echo
            ;;
        run)
            cli_require_profile "$1"; cli_validate; build_cmd
            if server_pid >/dev/null; then echo "ERROR: a server is already running (PID $(server_pid))." >&2; exit 2; fi
            local safe; safe="$(printf %s "$(basename "$MODEL" .gguf)" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-60)"
            SERVER_LOG="$LOG_DIR/server-$(date +%Y%m%d-%H%M%S)-$safe.log"
            {
                echo "=================================================================="
                echo " llama-tui $VERSION (run/foreground) - started: $(date '+%Y-%m-%d %H:%M:%S')"
                echo " Profile: $CURRENT_PROFILE"
                echo " Command: $(mask_cmd "$(quote_cmd "${CMD[@]}")")"
                echo "=================================================================="
            } | tee -a "$SERVER_LOG"
            echo "Access addresses:"; access_urls "${PORT:-8080}"
            echo "Log: $SERVER_LOG   (Ctrl+C to stop)"
            log_info "Run (foreground): $(mask_cmd "$(quote_cmd "${CMD[@]}")")"
            trap ':' INT   # Ctrl+C stops llama-server; the script keeps going to log the exit
            "${CMD[@]}" 2>&1 | tee -i -a "$SERVER_LOG"
            local rc=${PIPESTATUS[0]}
            echo "=== Exited on $(date '+%Y-%m-%d %H:%M:%S') (code $rc) ===" | tee -a "$SERVER_LOG"
            log_info "Run (foreground) exited with code $rc"
            exit "$rc"
            ;;
        start)
            cli_require_profile "$1"; cli_validate
            start_server_bg; local rc=$?
            [ $rc -eq 2 ] && exit 2
            if [ $rc -ne 0 ]; then
                echo "ERROR: the server did not start. Last lines:" >&2; tail -n 25 "$SERVER_LOG" >&2
                echo "Full log: $SERVER_LOG" >&2; exit 1
            fi
            echo "Server started (PID $(cat "$PID_FILE")). Log: $SERVER_LOG"
            cli_wait_ready "${PORT:-8080}" "$(cat "$PID_FILE")" || exit 1
            echo "Access addresses:"; access_urls "${PORT:-8080}"
            echo "To stop: $PROG stop"
            ;;
        stop)
            stop_server; case $? in
                0) echo "Server stopped." ;;
                3) echo "No llama-tui server is running."; exit 3 ;;
                *) echo "ERROR: could not stop the server. See $APP_LOG" >&2; exit 1 ;;
            esac
            ;;
        restart)
            cli_require_profile "$1"
            stop_server >/dev/null 2>&1
            cli_main start "$1"
            ;;
        status)
            local pid
            if pid="$(server_pid)"; then
                local p; p="$(runinfo_get PORT)"
                echo "Server RUNNING (PID $pid) - state: $(health_status "$p")"
                echo "  Since  : $(runinfo_get STARTED)"
                echo "  Profile: $(runinfo_get PROFILE)"
                echo "  Model  : $(runinfo_get MODEL)"
                echo "  Log    : $(runinfo_get LOG)"
                access_urls "$p"
            else
                echo "No llama-tui server is running. This machine's IP: $(primary_ip)"; exit 3
            fi
            ;;
        logs)
            local l; l="$(last_server_log)"
            [ -n "$l" ] || { echo "No server log found."; exit 1; }
            echo "==> $l"
            if [ "$1" = "-f" ]; then tail -n 50 -f "$l"; else tail -n 100 "$l"; fi
            ;;
        applog) tail -n 50 -f "$APP_LOG" ;;
        ip) primary_ip ;;
        *) echo "Unknown command: $cmd" >&2; echo "Use: $PROG help" >&2; exit 1 ;;
    esac
}

# =============================================================================
#  TUI MODE (dialog)
# =============================================================================
BACKTITLE="llama-tui $VERSION  |  Arrows/Tab move, Enter confirms, Esc goes back"

term_size() {
    TL=$(tput lines 2>/dev/null || echo 24); TC=$(tput cols 2>/dev/null || echo 80)
    [ "$TL" -lt 20 ] && TL=20; [ "$TC" -lt 70 ] && TC=70
}

# d: runs dialog and returns the choice in $REPLY; return code = dialog's code
d() {
    local rc
    # --cr-wrap: keeps the line breaks in the texts
    REPLY="$(dialog --backtitle "$BACKTITLE" --colors --cr-wrap \
        --ok-label "OK" --cancel-label "Cancel" --yes-label "Yes" --no-label "No" \
        --help-label "Help" --exit-label "Back" "$@" 2>&1 >/dev/tty)"
    rc=$?
    [ $rc -eq 255 ] && [ -n "$REPLY" ] && log_error "dialog: $REPLY"
    return $rc
}

msg()  { term_size; d --title "$1" --msgbox "$2" $((TL - 4)) $((TC - 6)); }
info() { d --title "${2:-Please wait}" --infobox "$1" 7 60; }
ask()  { term_size; d --title "$1" --yesno "$2" $((TL > 22 ? 20 : TL - 4)) $((TC - 10)); }

status_line() {
    local pid
    if pid="$(server_pid)"; then
        echo "\\Z2\\ZbSERVER RUNNING\\Zn (PID $pid, port $(runinfo_get PORT))"
    else
        echo "\\Z1Server stopped\\Zn"
    fi
}

model_label() {
    if [ -n "$MODEL" ]; then
        local s=""; [ -f "$MODEL" ] && s=" ($(human_size "$(file_size "$MODEL")"))"
        echo "$(basename "$MODEL")$s"
    else
        echo "(none)"
    fi
}

# ---------------- Model selection ----------------
FOUND_MODELS=()
scan_models() {  # scan_models [filter]
    local filter="$1" dir f old_ifs="$IFS"
    FOUND_MODELS=()
    IFS=':'
    for dir in $MODEL_DIRS; do
        IFS="$old_ifs"
        dir="${dir/#\~/$HOME}"
        [ -d "$dir" ] || continue
        while IFS= read -r f; do
            case "$f" in
                *-0000[2-9]-of-*|*-000[1-9][0-9]-of-*) continue ;;   # parts 2+ of split models
                */mmproj*|*mmproj-*) continue ;;
            esac
            if [ -n "$filter" ]; then
                echo "$f" | grep -qi -- "$filter" || continue
            fi
            FOUND_MODELS+=("$f")
        done < <(find -L "$dir" -type f -iname '*.gguf' 2>/dev/null | sort)
    done
    IFS="$old_ifs"
    log_info "Model search (filter='$filter'): ${#FOUND_MODELS[@]} found in $MODEL_DIRS"
}

pick_from_found() {
    local items=() i f
    if [ ${#FOUND_MODELS[@]} -eq 0 ]; then
        msg "No models" "No .gguf file was found in the search folders:\n\n$(echo "$MODEL_DIRS" | tr ':' '\n')\n\nTips:\n - Add your models folder under 'Manage search folders'.\n - Or use 'Browse the file system' / 'Type or paste the path'."
        return 1
    fi
    for i in "${!FOUND_MODELS[@]}"; do
        f="${FOUND_MODELS[$i]}"
        items+=("$((i + 1))" "$(human_size "$(file_size "$f")")  $(basename "$f")" "$f")
    done
    term_size
    d --title "Models found (${#FOUND_MODELS[@]})" --item-help \
      --menu "Pick the model. The full path is shown on the bottom line." \
      $((TL - 4)) $((TC - 6)) $((TL - 12)) "${items[@]}" || return 1
    MODEL="${FOUND_MODELS[$((REPLY - 1))]}"
    log_info "Model selected: $MODEL"
    return 0
}

menu_model() {
    while true; do
        term_size
        d --title "Select model" --cancel-label "Back" --menu \
"Current model: \\Zb$(model_label)\\Zn\n\nThe model is a .gguf file. Choose how to find it:" \
          $((TL - 4)) $((TC - 6)) 7 \
          1 "List every .gguf in the search folders" \
          2 "Search by name (filter)" \
          3 "Browse the file system" \
          4 "Type or paste the file path" \
          5 "Manage search folders" || return
        case "$REPLY" in
            1) info "Looking for .gguf files..."; scan_models ""; pick_from_found && return ;;
            2) d --title "Filter" --inputbox "Part of the model name (case-insensitive).\nE.g. qwen, llama-3, Q4_K_M" 10 60 "" || continue
               info "Looking for '$REPLY'..."; scan_models "$REPLY"; pick_from_found && return ;;
            3) local start="${MODEL%/*}"; [ -d "$start" ] || start="$HOME/"
               msg "How to browse" "In the file browser that follows:\n\n - TAB switches between the folder list, the file list and the path field.\n - Arrows move; SPACE enters a folder / selects a file.\n - You can also edit the path directly in the bottom field.\n - Enter (OK) confirms the selected file."
               term_size
               d --title "Choose the .gguf file" --fselect "${start%/}/" $((TL - 10)) $((TC - 8)) || continue
               if [ -f "$REPLY" ]; then
                   case "$REPLY" in *.gguf|*.GGUF) ;; *) ask "Warning" "The file does not end in .gguf:\n$REPLY\n\nUse it anyway?" || continue ;; esac
                   MODEL="$REPLY"; log_info "Model selected (fselect): $MODEL"; return
               else
                   msg "Invalid file" "The selected path is not a file:\n\n$REPLY\n\nNavigate to the file and select it with SPACE before confirming."
               fi ;;
            4) d --title "Model path" --inputbox "Full path to the .gguf file (~ is accepted):" 9 $((TC - 10)) "$MODEL" || continue
               local p="${REPLY/#\~/$HOME}"
               if [ -f "$p" ]; then MODEL="$p"; log_info "Model selected (manual): $MODEL"; return
               else msg "File not found" "No file exists at:\n\n$p"; fi ;;
            5) d --title "Search folders" --inputbox \
"Folders to search for models, separated by ':' (colon).\nThe search is recursive and follows symbolic links.\n\nExample: ~/models:/mnt/ssd/gguf" 12 $((TC - 10)) "$MODEL_DIRS" || continue
               MODEL_DIRS="$REPLY"; save_settings ;;
        esac
    done
}

# ---------------- Parameter editing ----------------
display_value() {  # index -> readable value
    local i="$1" v; v="$(get_var "${P_KEYS[$i]}")"
    case "${P_TYPE[$i]}" in
        bool) [ -n "$v" ] && echo "[x] on" || echo "[ ] off" ;;
        *) if [ -z "$v" ]; then echo "(default)"
           elif [ "${P_KEYS[$i]}" = "APIKEY" ]; then echo "********"
           else echo "$v"; fi ;;
    esac
}

pad() {  # pad text width  (counts characters, not bytes)
    local t="$1"
    while [ ${#t} -lt "$2" ]; do t="$t "; done
    printf '%s' "$t"
}

show_param_doc() {  # index: shows the full documentation (scrollable)
    local idx="$1" tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/llama-tui.XXXXXX")"
    printf '%s\n\nFlag: %s\n%s\n' "${P_LABEL[$idx]}" "${P_FLAG[$idx]:-(free-form arguments)}" "${P_DOC[$idx]}" >"$tmp"
    term_size
    d --title "Help: ${P_LABEL[$idx]}" --textbox "$tmp" $((TL - 4)) $((TC - 6))
    rm -f "$tmp"
}

edit_param() {  # parameter index in P_KEYS
    local idx="$1"
    local key="${P_KEYS[$idx]}" type="${P_TYPE[$idx]}" label="${P_LABEL[$idx]}"
    local flag="${P_FLAG[$idx]:-(free-form)}" cur new rc w header opts o items def
    cur="$(get_var "$key")"
    term_size
    w=$((TC - 8)); [ "$w" -gt 76 ] && w=76
    header="Flag: $flag\n${P_SHORT[$idx]}\n\nCurrent value: $(display_value "$idx")"

    case "$type" in
        bool)
            [ -n "$cur" ] && def="on" || def="off"
            while true; do
                d --title "$label" --help-button --default-item "$def" --menu \
                  "$header\n\nPick with the arrows and confirm with Enter.\n<Help> shows the full explanation." \
                  16 "$w" 2 \
                  on  "On   (passes $flag)" \
                  off "Off  (not passed)"
                rc=$?
                [ $rc -eq 2 ] && { show_param_doc "$idx"; continue; }
                [ $rc -ne 0 ] && return
                [ "$REPLY" = "on" ] && new="1" || new=""
                break
            done ;;
        choice:*)
            opts="${type#choice:}"; items=()
            local old_ifs="$IFS"; IFS=','
            set -f
            for o in $opts; do
                if [ -z "$o" ]; then items+=("default" "do not pass (llama-server default)")
                else items+=("$o" "$flag $o"); fi
            done
            set +f
            IFS="$old_ifs"
            [ -n "$cur" ] && def="$cur" || def="default"
            while true; do
                d --title "$label" --help-button --default-item "$def" --menu \
                  "$header\n\nPick with the arrows and confirm with Enter.\n<Help> shows the full explanation." \
                  $((10 + ${#items[@]} / 2 + 6)) "$w" $((${#items[@]} / 2)) "${items[@]}"
                rc=$?
                [ $rc -eq 2 ] && { show_param_doc "$idx"; continue; }
                [ $rc -ne 0 ] && return
                new="$REPLY"; [ "$new" = "default" ] && new=""
                break
            done ;;
        *)
            new="$cur"
            while true; do
                d --title "$label" --help-button --inputbox \
                  "$header\n\nType the new value and press Enter.\nLeave EMPTY to not pass the parameter (llama-server default).\n<Help> shows the full explanation." \
                  16 "$w" "$new"
                rc=$?
                [ $rc -eq 2 ] && { show_param_doc "$idx"; continue; }
                [ $rc -ne 0 ] && return
                new="$(printf '%s' "$REPLY" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
                new="${new/#\~/$HOME}"
                case "$type" in
                    int)   if [ -n "$new" ] && ! [[ "$new" =~ ^-?[0-9]+$ ]]; then
                               msg "Invalid value" "'$label' only accepts whole numbers.\n\nYou typed: '$new'"; continue; fi ;;
                    float) if [ -n "$new" ] && ! [[ "$new" =~ ^[0-9]*\.?[0-9]+$ ]]; then
                               msg "Invalid value" "'$label' accepts numbers like 0.7 (use a dot, not a comma).\n\nYou typed: '$new'"; continue; fi ;;
                esac
                if [ "$key" = "PORT" ] && [ -n "$new" ] && { [ "$new" -lt 1 ] || [ "$new" -gt 65535 ]; }; then
                    msg "Invalid value" "The port must be between 1 and 65535.\n\nYou typed: '$new'"; continue
                fi
                if [ "$key" = "MMPROJ" ] && [ -n "$new" ] && [ ! -f "$new" ]; then
                    msg "File not found" "No file exists at:\n\n$new"; continue
                fi
                break
            done ;;
    esac

    eval "$key=\$new"
    log_info "Parameter $key changed: '$([ "$key" = APIKEY ] && echo '***' || echo "$cur")' -> '$([ "$key" = APIKEY ] && echo '***' || echo "$new")'"
}

menu_params() {
    local sel=a items n lw tags="abcdefghijklmnopqrstuvwxyz"
    while true; do
        items=()
        for n in "${!P_KEYS[@]}"; do
            items+=("${tags:$n:1}" "$(pad "${P_LABEL[$n]}" 24) $(display_value "$n")" "${P_FLAG[$n]:+${P_FLAG[$n]}: }${P_SHORT[$n]}")
        done
        items+=("0" "Restore defaults" "Resets every parameter to its initial value (keeps the model)")
        items+=("?" "Help for all parameters" "Shows the full explanation of every parameter")
        term_size
        lw=$((TL - 12)); [ "$lw" -gt $(( ${#items[@]} / 3 )) ] && lw=$(( ${#items[@]} / 3 ))
        d --title "Server parameters" --item-help --cancel-label "Back" --default-item "$sel" --menu \
          "Press the letter, or use the arrows + Enter, to edit. The description is shown at the bottom.\n(default) = not passed; llama-server uses its own value." \
          $((lw + 8)) $((TC - 6)) "$lw" "${items[@]}" || return
        sel="$REPLY"
        case "$REPLY" in
            0) if ask "Restore defaults" "Reset every parameter to its default value?\n(The selected model is kept.)"; then
                   local m="$MODEL"; reset_params; MODEL="$m"; log_info "Parameters restored to defaults"
               fi ;;
            \?) local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/llama-tui.XXXXXX")"
               for n in "${!P_KEYS[@]}"; do
                   printf '=== %s  (%s) ===\n%s\n\n' "${P_LABEL[$n]}" "${P_FLAG[$n]:-free-form}" "${P_DOC[$n]}"
               done >"$tmp"
               term_size; d --title "Parameter help" --textbox "$tmp" $((TL - 4)) $((TC - 6)); rm -f "$tmp" ;;
            [a-z]) n="${tags%%"$REPLY"*}"; edit_param "${#n}" ;;
        esac
    done
}

# ---------------- Profiles ----------------
menu_load_profile() {
    local items=() p m
    for p in $(list_profiles); do
        m="$(sed -n 's/^MODEL=//p' "$PROFILE_DIR/$p.conf" | head -n 1)"
        items+=("$p" "$(basename "$m")")
    done
    [ ${#items[@]} -eq 0 ] && { msg "Profiles" "No saved profiles yet.\n\nSet up a model and parameters, then use 'Save current settings as a profile'."; return; }
    term_size
    d --title "Load profile" --extra-button --extra-label "Delete" --cancel-label "Back" --menu \
      "Profiles saved in:\n$PROFILE_DIR\n\nOK loads the profile; 'Delete' removes the profile file." \
      $((TL - 4)) $((TC - 6)) $((TL - 12)) "${items[@]}"
    case $? in
        0) if load_profile "$REPLY"; then
               msg "Profile loaded" "Profile '\\Zb$REPLY\\Zn' loaded.\n\nModel: $(model_label)\n\nTip: run it straight from the terminal with:\n  $PROG run $REPLY"
           else msg "Error" "Could not load profile '$REPLY'. See the log:\n$APP_LOG"; fi ;;
        3) local victim="$REPLY"
           if ask "Delete profile" "Permanently delete profile '$victim'?\n\n$PROFILE_DIR/$victim.conf"; then
               rm -f "$PROFILE_DIR/$victim.conf" && log_info "Profile deleted: $victim"
               [ "$CURRENT_PROFILE" = "$victim" ] && CURRENT_PROFILE=""
           fi ;;
    esac
}

menu_save_profile() {
    local def="$CURRENT_PROFILE" name
    [ -z "$def" ] && [ -n "$MODEL" ] && def="$(printf %s "$(basename "$MODEL" .gguf)" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-40)"
    d --title "Save profile" --inputbox "Profile name (letters, digits, dot, - and _).\nIf it already exists, it will be overwritten." 10 60 "$def" || return
    name="$REPLY"
    if ! [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then msg "Invalid name" "Use only letters, digits, dot, hyphen and underscore.\nYou typed: '$name'"; return; fi
    if [ -f "$PROFILE_DIR/$name.conf" ] && [ "$name" != "$CURRENT_PROFILE" ]; then
        ask "Overwrite?" "A profile named '$name' already exists. Overwrite it?" || return
    fi
    if save_kv_file "$PROFILE_DIR/$name.conf" "$PROFILE_KEYS" "llama-tui profile: $name"; then
        CURRENT_PROFILE="$name"
        msg "Profile saved" "Profile '\\Zb$name\\Zn' saved to:\n$PROFILE_DIR/$name.conf\n\nTo run it without opening the TUI:\n  $PROG run $name      (foreground)\n  $PROG start $name    (background)\n  $PROG stop"
    else
        msg "Error" "Failed to save the profile. See the log:\n$APP_LOG"
    fi
}

# ---------------- Server ----------------
show_command() {
    build_cmd
    local warn=""; validate_config || warn="\n\n\\Z1Problems found:\\Zn\n$VALIDATION_ERRORS"
    [ -n "$VALIDATION_WARNINGS" ] && warn="$warn\n\\Z3Warnings:\\Zn\n$VALIDATION_WARNINGS"
    msg "Generated command" "This is the command that will run (you can copy it and use it in a terminal):\n\n$(mask_cmd "$(quote_cmd "${CMD[@]}")")$warn"
}

tui_start() {
    local pid
    if pid="$(server_pid)"; then
        msg "Already running" "A server is already running (PID $pid).\n\nStop it first with 'Stop server' to start another model."
        return
    fi
    if ! validate_config; then
        msg "Cannot start" "Fix the items below before starting:\n\n$VALIDATION_ERRORS"
        return
    fi
    if [ -n "$VALIDATION_WARNINGS" ]; then
        ask "Warnings" "Attention:\n\n$VALIDATION_WARNINGS\nStart anyway?" || return
    fi
    save_last
    build_cmd
    ask "Start server" "Model: \\Zb$(model_label)\\Zn\nAddress: http://$(primary_ip):${PORT:-8080}\n\nCommand:\n$(mask_cmd "$(quote_cmd "${CMD[@]}")")\n\nStart now?" || return

    start_server_bg
    if [ $? -ne 0 ]; then
        msg "Failed to start" "llama-server exited right after starting.\n\nLast log lines:\n\n$(tail -n 15 "$SERVER_LOG")\n\nFull log:\n$SERVER_LOG"
        return
    fi
    pid="$(cat "$PID_FILE")"

    # Wait for loading while showing progress; Ctrl+C only stops the waiting
    local t=0 st="" aborted=0
    trap 'aborted=1' INT
    while [ "$t" -lt "$STARTUP_TIMEOUT" ] && [ $aborted -eq 0 ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            trap - INT; rm -f "$PID_FILE"
            log_error "Server died while loading (pid=$pid)"
            msg "The server exited with an error" "llama-server stopped while loading.\n\nCommon causes: not enough memory (lower Context or GPU layers), a corrupted file, a parameter your version does not support.\n\nLast lines:\n\n$(tail -n 15 "$SERVER_LOG")\n\nFull log: $SERVER_LOG"
            return
        fi
        st="$(health_status "${PORT:-8080}")"
        [ "$st" = "ok" ] && break
        term_size
        dialog --backtitle "$BACKTITLE" --cr-wrap --no-collapse --title "Loading model... ${t}s (Ctrl+C to stop waiting)" \
               --infobox "$(tail -n $((TL - 8)) "$SERVER_LOG" | cut -c1-$((TC - 10)))" $((TL - 4)) $((TC - 6))
        sleep 2; t=$((t + 2))
    done
    trap - INT
    if [ "$st" = "ok" ]; then
        log_info "Server ready in ${t}s"
        msg "Server ready!" "\\Z2\\ZbThe server is up\\Zn (PID $pid, loaded in ${t}s).\n\nOpen it in a browser or use it as an OpenAI API (/v1):\n$(access_urls "${PORT:-8080}")\n\nUse 'View server output' to follow requests.\nLog: $SERVER_LOG"
    else
        log_warn "Server still loading after ${t}s (stopped waiting)"
        msg "Still loading" "The server is still loading in the background (PID $pid).\nFollow it in 'View server output'."
    fi
}

tui_stop() {
    local pid
    pid="$(server_pid)" || { msg "Stop server" "No server is running."; return; }
    ask "Stop server" "Stop the server (PID $pid)?\n\nModel: $(basename "$(runinfo_get MODEL)")\n\nConnected clients will be disconnected." || return
    info "Stopping the server (PID $pid)..."
    if stop_server; then
        msg "Server stopped" "The server has been shut down.\n\nYou can now pick another model/parameters and start again."
    else
        msg "Error" "Could not stop process $pid.\nTry manually: kill -9 $pid\n\nLog: $APP_LOG"
    fi
}

tui_view_output() {
    local l; l="$(last_server_log)"
    [ -n "$l" ] || { msg "Server output" "No server log yet. Start the server first."; return; }
    term_size
    if server_pid >/dev/null; then
        d --title "Live output: $(basename "$l")  (Enter/Esc to go back - the server keeps running)" \
          --exit-label "Back" --tailbox "$l" $((TL - 3)) $((TC - 4))
    else
        d --title "Last log (server stopped): $(basename "$l")" --exit-label "Back" --textbox "$l" $((TL - 3)) $((TC - 4))
    fi
}

tui_status() {
    local pid txt
    if pid="$(server_pid)"; then
        local p; p="$(runinfo_get PORT)"
        txt="\\Z2\\ZbRUNNING\\Zn - state: $(health_status "$p")\n\nPID     : $pid\nSince   : $(runinfo_get STARTED)\nProfile : $(runinfo_get PROFILE)\nModel   : $(runinfo_get MODEL)\nLog     : $(runinfo_get LOG)\n\nAccess addresses:\n$(access_urls "$p")\n\nOpenAI API: append /v1 to the address (e.g. http://IP:$p/v1)"
    else
        txt="\\Z1No server is running.\\Zn"
    fi
    txt="$txt\n\nllama-server: $(find_llama_bin || echo 'NOT FOUND')\nCPUs: $(cpu_count)   System: $(uname -sm)"
    msg "Status" "$txt"
}

tui_logs() {
    term_size
    d --title "Logs" --cancel-label "Back" --menu "Logs are stored in:\n$LOG_DIR\n\nNo log is ever overwritten: every server run creates a new file." \
      $((TL - 4)) $((TC - 6)) 4 \
      1 "Program log (llama-tui.log) - last 500 lines" \
      2 "Choose a server run log" || return
    case "$REPLY" in
        1) local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/llama-tui.XXXXXX")"; tail -n 500 "$APP_LOG" >"$tmp"
           d --title "llama-tui.log" --exit-label "Back" --textbox "$tmp" $((TL - 3)) $((TC - 4)); rm -f "$tmp" ;;
        2) local items=() f
           for f in $(ls -1t "$LOG_DIR"/server-*.log 2>/dev/null | head -n 40); do
               items+=("$(basename "$f")" "$(human_size "$(file_size "$f")")")
           done
           [ ${#items[@]} -eq 0 ] && { msg "Logs" "No server logs yet."; return; }
           d --title "Server logs (newest first)" --menu "Choose:" $((TL - 4)) $((TC - 6)) $((TL - 10)) "${items[@]}" || return
           d --title "$REPLY" --exit-label "Back" --textbox "$LOG_DIR/$REPLY" $((TL - 3)) $((TC - 4)) ;;
    esac
}

tui_settings() {
    while true; do
        term_size
        d --title "Settings" --cancel-label "Back" --menu "General settings (saved in $SETTINGS_FILE)" \
          $((TL - 4)) $((TC - 6)) 4 \
          1 "llama-server path: $(find_llama_bin || echo 'NOT FOUND')" \
          2 "Model search folders" \
          3 "Maximum wait while loading: ${STARTUP_TIMEOUT}s" || return
        case "$REPLY" in
            1) d --title "llama-server" --inputbox "Full path to the llama-server executable.\nLeave empty to detect it automatically (PATH and common locations).\n\nE.g. ~/llama.cpp/build/bin/llama-server" 12 $((TC - 10)) "$LLAMA_BIN" || continue
               local b="${REPLY/#\~/$HOME}"
               if [ -n "$b" ] && [ ! -x "$b" ]; then msg "Invalid" "Not an executable:\n$b"; continue; fi
               LLAMA_BIN="$b"; LLAMA_HELP_CACHE=""; save_settings
               local bin; if bin="$(find_llama_bin)"; then
                   msg "llama-server" "Using: $bin\n\nVersion:\n$("$bin" --version 2>&1 | head -n 4)"
               fi ;;
            2) d --title "Search folders" --inputbox "Folders separated by ':'" 9 $((TC - 10)) "$MODEL_DIRS" || continue
               MODEL_DIRS="$REPLY"; save_settings ;;
            3) d --title "Wait time" --inputbox "Seconds to wait for the model to load before returning control.\n(The server keeps loading even after that.)" 10 60 "$STARTUP_TIMEOUT" || continue
               [[ "$REPLY" =~ ^[0-9]+$ ]] && { STARTUP_TIMEOUT="$REPLY"; save_settings; } || msg "Invalid" "Type digits only." ;;
        esac
    done
}

tui_quit() {
    local pid
    save_last
    if pid="$(server_pid)"; then
        d --title "Quit" --yes-label "Stop and quit" --no-label "Keep running" --extra-button --extra-label "Cancel" --yesno \
"The server is still running (PID $pid).\n\n - Stop and quit: shuts the server down.\n - Keep running: quits and the server keeps running in the background\n   (stop it later with: $PROG stop)" 13 74
        case $? in
            0) info "Stopping the server..."; stop_server ;;
            1) log_info "Quitting and keeping the server running (pid=$pid)" ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

tui_main() {
    if ! command -v dialog >/dev/null 2>&1; then
        echo "The TUI needs the 'dialog' program. Install it with:" >&2
        echo "  macOS : brew install dialog" >&2
        echo "  Debian/Ubuntu: sudo apt install dialog" >&2
        echo "  Fedora: sudo dnf install dialog   |  Arch: sudo pacman -S dialog" >&2
        echo "The command-line commands (run/start/stop/...) work without it. See: $PROG help" >&2
        log_error "dialog not found"
        exit 1
    fi
    [ -t 0 ] && [ -t 1 ] || { echo "The TUI needs an interactive terminal." >&2; exit 1; }
    export ESCDELAY="${ESCDELAY:-250}"   # snappy Esc key (ncurses default: 1s)
    log_info "TUI started (bash $BASH_VERSION, $(uname -sm), dialog $(dialog --version 2>&1 | head -n1), llama-server: $(find_llama_bin || echo 'not found'))"
    trap 'clear; log_info "TUI closed"' EXIT
    trap 'log_warn "Received termination signal"; exit 130' TERM HUP

    [ -f "$LAST_FILE" ] && load_kv_file "$LAST_FILE" "$PROFILE_KEYS"

    if ! find_llama_bin >/dev/null; then
        msg "llama-server not found" "Could not find the 'llama-server' executable on your PATH or in common locations.\n\nSet its path in 'Settings' before starting the server.\n\n(Build llama.cpp or install it with: brew install llama.cpp)"
    fi

    local sel=1
    while true; do
        term_size
        d --title "llama-server - dashboard${CURRENT_PROFILE:+ (profile: $CURRENT_PROFILE)}" --cancel-label "Quit" --default-item "$sel" --menu \
"$(status_line)\nModel: \\Zb$(model_label)\\Zn\nThis machine's IP: \\Zb$(primary_ip)\\Zn   Port: ${PORT:-8080}   Context: ${CTX:-default}   GPU layers: ${NGL:-default}" \
          $((TL - 4)) $((TC - 6)) 12 \
          1  "Select model (.gguf)" \
          2  "Configure parameters" \
          3  "Load saved profile" \
          4  "Save current settings as a profile" \
          5  "View generated command" \
          6  ">> START server" \
          7  "View server output (live)" \
          8  "[] STOP server" \
          9  "Status and remote access addresses" \
          L  "Logs" \
          S  "Settings (llama-server path, folders)" \
          Q  "Quit"
        [ $? -ne 0 ] && REPLY=Q
        sel="$REPLY"
        case "$REPLY" in
            1) menu_model; save_last ;;
            2) menu_params; save_last ;;
            3) menu_load_profile ;;
            4) menu_save_profile ;;
            5) show_command ;;
            6) tui_start ;;
            7) tui_view_output ;;
            8) tui_stop ;;
            9) tui_status ;;
            L) tui_logs ;;
            S) tui_settings ;;
            Q) tui_quit && break ;;
        esac
    done
}

# =============================================================================
if [ $# -gt 0 ]; then
    cli_main "$@"
else
    tui_main
fi
