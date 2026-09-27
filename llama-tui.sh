#!/usr/bin/env bash
# =============================================================================
#  llama-tui.sh - Lançador TUI para o llama-server (llama.cpp)
#
#  Uso rápido:
#    ./llama-tui.sh                 abre a interface (TUI)
#    ./llama-tui.sh run   <perfil>  roda o servidor em primeiro plano (Ctrl+C para)
#    ./llama-tui.sh start <perfil>  inicia em segundo plano
#    ./llama-tui.sh stop            para o servidor em execução
#    ./llama-tui.sh help            ajuda completa
#
#  Compatível com bash 3.2 (macOS) e Linux. A TUI requer "dialog".
# =============================================================================

VERSION="1.0.0"
PROG="$(basename "$0")"

# ----------------------------------------------------------------------------
# Diretórios (seguem o padrão XDG; podem ser sobrescritos por variáveis de ambiente)
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
APP_LOG_MAX_BYTES=$((5 * 1024 * 1024))   # acima disso o log é arquivado (nunca apagado)

mkdir -p "$PROFILE_DIR" "$LOG_DIR" 2>/dev/null || {
    echo "ERRO: não foi possível criar $PROFILE_DIR ou $LOG_DIR" >&2
    exit 1
}
chmod 700 "$CONFIG_DIR" 2>/dev/null

# ----------------------------------------------------------------------------
# Log do programa: sempre em modo append; rotação por renomeação com data/hora
# ----------------------------------------------------------------------------
rotate_app_log() {
    [ -f "$APP_LOG" ] || return 0
    local size
    size=$(wc -c <"$APP_LOG" 2>/dev/null | tr -d ' ')
    if [ -n "$size" ] && [ "$size" -gt "$APP_LOG_MAX_BYTES" ]; then
        mv "$APP_LOG" "$LOG_DIR/llama-tui-$(date +%Y%m%d-%H%M%S).log"
    fi
}

log() {  # log NIVEL mensagem...
    local level="$1"; shift
    printf '%s [%-5s] [pid %s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$$" "$*" >>"$APP_LOG"
}
log_info()  { log INFO  "$@"; }
log_warn()  { log WARN  "$@"; }
log_error() { log ERROR "$@"; }

rotate_app_log

# ----------------------------------------------------------------------------
# Definição dos parâmetros
#   Cada parâmetro: chave | tipo | flag do llama-server | rótulo | ajuda curta | documentação
#   Tipos: text, int, float, bool, choice:<op1>,<op2>,...
#   Valor vazio = parâmetro NÃO é passado (o llama-server usa o padrão dele)
# ----------------------------------------------------------------------------
P_KEYS=();  P_TYPE=(); P_FLAG=(); P_LABEL=(); P_SHORT=(); P_DOC=()

defparam() {
    P_KEYS+=("$1"); P_TYPE+=("$2"); P_FLAG+=("$3"); P_LABEL+=("$4"); P_SHORT+=("$5"); P_DOC+=("$6")
}

defparam PORT int "--port" "Porta" \
 "Porta TCP do servidor (ex.: 8080)." \
"Porta TCP em que o servidor escuta (--port).

Depois de iniciado, acesse http://<ip>:<porta> no navegador para a
interface web, ou use http://<ip>:<porta>/v1 como endpoint compatível
com a API da OpenAI.

A porta precisa estar livre. Portas abaixo de 1024 exigem root.
Padrão do llama-server: 8080"

defparam CTX int "-c" "Contexto (tokens)" \
 "Tamanho da janela de contexto em tokens (-c / --ctx-size)." \
"Tamanho máximo do contexto em tokens (-c / --ctx-size).

É quanto texto (prompt + resposta + histórico) o modelo consegue
\"lembrar\" de uma vez. Valores maiores usam MUITO mais memória
(RAM/VRAM) por causa do KV cache.

Exemplos: 4096, 8192, 16384, 32768.
0 = usa o valor de treino do modelo (pode ser enorme!).
Com --parallel N, o contexto é dividido entre os N slots."

defparam NGL int "-ngl" "Camadas na GPU" \
 "Quantas camadas do modelo vão para a GPU (-ngl). 99 = todas." \
"Número de camadas do modelo carregadas na GPU (-ngl / --n-gpu-layers).

  99 (ou maior que o nº de camadas) -> tudo na GPU (mais rápido).
  0  -> tudo na CPU.
  Valor intermediário -> divide entre GPU e CPU quando o modelo
  não cabe inteiro na VRAM.

No macOS (Apple Silicon/Metal) normalmente use 99.
Se aparecer erro de memória (out of memory), diminua este valor."

defparam THREADS int "-t" "Threads CPU" \
 "Nº de threads de CPU para geração (-t). Vazio = automático." \
"Número de threads de CPU usadas na geração (-t / --threads).

Vazio = o llama-server escolhe automaticamente.
Normalmente o ideal é o número de núcleos FÍSICOS (não lógicos).
Tem pouco efeito quando todas as camadas estão na GPU."

defparam BATCH int "-b" "Batch size" \
 "Tamanho lógico do lote de processamento do prompt (-b)." \
"Tamanho lógico máximo do lote (-b / --batch-size).

Afeta a velocidade de processamento do prompt (prefill).
Vazio = padrão do llama-server (2048). Valores maiores podem
acelerar prompts longos mas usam mais memória."

defparam UBATCH int "-ub" "Micro-batch" \
 "Tamanho físico do lote (-ub / --ubatch-size)." \
"Tamanho físico máximo do lote (-ub / --ubatch-size).

Deve ser menor ou igual ao batch size.
Vazio = padrão do llama-server (512). Aumentar (ex.: 1024, 2048)
pode acelerar o prefill em GPUs com bastante memória."

defparam PARALLEL int "-np" "Slots paralelos" \
 "Quantas requisições simultâneas o servidor atende (-np)." \
"Número de slots de processamento paralelo (-np / --parallel).

Cada slot atende uma conversa/requisição ao mesmo tempo.
ATENÇÃO: o contexto (-c) é dividido entre os slots. Ex.: -c 16384
com -np 4 dá 4096 tokens para cada requisição.
Vazio = padrão do llama-server."

defparam FLASH "choice:,auto,on,off" "-fa" "Flash Attention" \
 "Ativa Flash Attention (-fa). Economiza memória e acelera." \
"Flash Attention (-fa / --flash-attn).

  (vazio) -> não passa o parâmetro (padrão do llama-server).
  auto    -> o llama-server decide se usa.
  on      -> força ligado. Reduz uso de memória e costuma acelerar.
  off     -> força desligado.

É necessário para quantizar o KV cache em V (cache-type-v).
Em versões antigas do llama-server o parâmetro não aceita valor;
este programa detecta isso e se adapta automaticamente."

defparam CTK "choice:,f16,q8_0,q4_0" "-ctk" "Tipo do KV cache (K)" \
 "Quantização do cache K (-ctk). q8_0 economiza memória." \
"Tipo de dado do KV cache para K (-ctk / --cache-type-k).

  (vazio) -> padrão (f16).
  q8_0    -> metade da memória, perda de qualidade quase nula.
  q4_0    -> 1/4 da memória, alguma perda de qualidade.

Útil para caber contextos grandes na memória."

defparam CTV "choice:,f16,q8_0,q4_0" "-ctv" "Tipo do KV cache (V)" \
 "Quantização do cache V (-ctv). Requer Flash Attention." \
"Tipo de dado do KV cache para V (-ctv / --cache-type-v).

Mesmas opções do cache K. Quantizar o V normalmente exige
Flash Attention ligado (-fa on)."

defparam MLOCK bool "--mlock" "Travar na RAM (mlock)" \
 "Impede o sistema de mandar o modelo para o swap." \
"--mlock: força o sistema a manter o modelo na RAM, sem swap.

Evita lentidão por paginação, mas exige RAM suficiente e em alguns
Linux pode precisar aumentar o limite (ulimit -l)."

defparam NOMMAP bool "--no-mmap" "Desativar mmap" \
 "Carrega o modelo inteiro na memória em vez de mapear o arquivo." \
"--no-mmap: desativa o mapeamento do arquivo em memória.

Com mmap (padrão) o modelo carrega mais rápido e compartilha páginas
com o cache do sistema. Desativar pode ajudar se o disco for lento
ou em alguns casos de GPU parcial, mas o carregamento fica mais lento."

defparam JINJA bool "--jinja" "Template Jinja" \
 "Usa o chat template Jinja do modelo (necessário p/ tool calling)." \
"--jinja: usa o template de chat embutido no GGUF (formato Jinja).

Recomendado para modelos modernos e OBRIGATÓRIO para usar
function/tool calling pela API OpenAI."

defparam ALIAS text "--alias" "Alias do modelo" \
 "Nome do modelo exibido na API (/v1/models)." \
"--alias: nome com que o modelo aparece na API (/v1/models) e que
os clientes podem usar no campo \"model\".

Vazio = o llama-server usa o caminho/nome do arquivo."

defparam APIKEY text "--api-key" "API Key" \
 "Chave exigida dos clientes (recomendado para acesso remoto)." \
"--api-key: exige que os clientes enviem esta chave no cabeçalho
Authorization: Bearer <chave>.

FORTEMENTE recomendado: o servidor fica acessível por toda a sua rede.
A interface web também pedirá a chave.
Obs.: a chave fica salva em texto no perfil (arquivo com permissão 600)."

defparam MMPROJ text "--mmproj" "Projetor multimodal" \
 "Arquivo mmproj*.gguf para modelos com visão (imagens)." \
"--mmproj: caminho do arquivo de projeção multimodal (mmproj-*.gguf).

Necessário apenas para modelos de visão (que entendem imagens).
O arquivo normalmente vem junto do modelo no Hugging Face.
Vazio = não usa."

defparam TEMP float "--temp" "Temperatura padrão" \
 "Criatividade padrão das respostas (0.0 a 2.0)." \
"--temp: temperatura de amostragem padrão.

  Baixa (0.1-0.4) -> respostas mais determinísticas/precisas.
  Média (0.6-0.8) -> equilíbrio (bom para chat).
  Alta (>1.0)     -> mais criativo e menos coerente.

Os clientes podem sobrescrever em cada requisição.
Vazio = padrão do llama-server (0.8)."

defparam EXTRA text "" "Argumentos extras" \
 "Qualquer outro argumento do llama-server, como na linha de comando." \
"Argumentos extras passados literalmente ao llama-server.

Use para qualquer opção que não está nesta lista. Exemplos:
  --top-k 40 --top-p 0.9
  --cont-batching --metrics
  --rope-scaling yarn --rope-scale 4
  --chat-template chatml
  --override-tensor \"exps=CPU\"

Aspas são respeitadas. Veja todas as opções em:
  llama-server --help"

# Valores iniciais (padrão ao abrir pela primeira vez)
MODEL=""
PORT="8080"; CTX="4096"; NGL="99"; THREADS=""; BATCH=""; UBATCH=""
PARALLEL=""; FLASH=""; CTK=""; CTV=""; MLOCK=""; NOMMAP=""; JINJA="1"; ALIAS=""
APIKEY=""; MMPROJ=""; TEMP=""; EXTRA=""
CURRENT_PROFILE=""

# Configurações gerais (settings.conf)
LLAMA_BIN=""
MODEL_DIRS="$HOME/models:$HOME/llama.cpp/models:$HOME/.cache/llama.cpp:$HOME/.cache/huggingface/hub:$HOME/.lmstudio/models"
STARTUP_TIMEOUT="300"

PROFILE_KEYS="MODEL ${P_KEYS[*]}"
LEGACY_KEYS="HOST"   # chaves de versões antigas: aceitas nos perfis e ignoradas

# O servidor sempre escuta em todas as interfaces (0.0.0.0) para permitir acesso
# remoto. O IP não é um parâmetro: é detectado da máquina e apenas exibido.
BIND_HOST="0.0.0.0"
SETTINGS_KEYS="LLAMA_BIN MODEL_DIRS STARTUP_TIMEOUT"

# ----------------------------------------------------------------------------
# Leitura/gravação de arquivos KEY=valor (sem "source": só chaves permitidas)
# ----------------------------------------------------------------------------
load_kv_file() {  # load_kv_file arquivo "CHAVES PERMITIDAS"
    local file="$1" allowed=" $2 " line key val n=0
    [ -r "$file" ] || { log_warn "Arquivo não encontrado/ilegível: $file"; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        key="${line%%=*}"; val="${line#*=}"
        case " $LEGACY_KEYS " in *" $key "*) continue ;; esac
        case "$allowed" in
            *" $key "*) eval "$key=\$val"; n=$((n + 1)) ;;
            *) log_warn "Chave desconhecida ignorada em $file: $key" ;;
        esac
    done <"$file"
    log_info "Carregado $file ($n chaves)"
    return 0
}

save_kv_file() {  # save_kv_file arquivo "CHAVES" "comentário"
    local file="$1" keys="$2" comment="$3" k tmp
    tmp="$file.tmp.$$"
    {
        echo "# $comment"
        echo "# Gerado por llama-tui $VERSION em $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# Formato: CHAVE=valor (vazio = não passar o parâmetro)"
        for k in $keys; do
            eval "printf '%s=%s\n' \"\$k\" \"\${$k}\""
        done
    } >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file"
    local rc=$?
    if [ $rc -eq 0 ]; then log_info "Salvo $file"; else log_error "Falha ao salvar $file (rc=$rc)"; rm -f "$tmp"; fi
    return $rc
}

reset_params() {
    MODEL=""; PORT="8080"; CTX="4096"; NGL="99"; THREADS=""; BATCH=""
    UBATCH=""; PARALLEL=""; FLASH=""; CTK=""; CTV=""; MLOCK=""; NOMMAP=""; JINJA="1"
    ALIAS=""; APIKEY=""; MMPROJ=""; TEMP=""; EXTRA=""
}

load_profile() {  # nome ou caminho
    local p="$1" f
    if [ -f "$p" ]; then f="$p"; else f="$PROFILE_DIR/$p.conf"; fi
    [ -f "$f" ] || { log_error "Perfil não encontrado: $p"; return 1; }
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

save_settings() { save_kv_file "$SETTINGS_FILE" "$SETTINGS_KEYS" "Configurações gerais do llama-tui"; }
save_last()     { save_kv_file "$LAST_FILE" "$PROFILE_KEYS" "Última sessão (restaurada ao abrir a TUI)" >/dev/null; }

[ -f "$SETTINGS_FILE" ] && load_kv_file "$SETTINGS_FILE" "$SETTINGS_KEYS"

# ----------------------------------------------------------------------------
# Utilitários
# ----------------------------------------------------------------------------
param_index() {  # retorna índice de uma chave em P_KEYS
    local i
    for i in "${!P_KEYS[@]}"; do
        [ "${P_KEYS[$i]}" = "$1" ] && { echo "$i"; return 0; }
    done
    return 1
}

get_var() { eval "printf '%s' \"\${$1}\""; }

human_size() {  # bytes -> texto
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

local_ips() {  # todos os IPv4 da máquina, exceto loopback
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

primary_ip() {  # IPv4 principal (interface da rota padrão); fallback: primeiro IPv4 encontrado
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

port_in_use() {  # 0 = porta ocupada
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

split_args() {  # split_args "string" -> preenche array SPLIT (respeita aspas)
    SPLIT=()
    local a
    [ -z "${1//[[:space:]]/}" ] && return 0
    while IFS= read -r -d '' a; do SPLIT+=("$a"); done < <(printf '%s' "$1" | xargs printf '%s\0' 2>/dev/null)
    return 0
}

quote_cmd() {  # imprime um array como comando shell copiável
    local out="" a
    for a in "$@"; do out="$out $(printf '%q' "$a")"; done
    printf '%s' "${out# }"
}

mask_cmd() {  # esconde o valor da API key em textos exibidos
    local s="$1"
    local q; q="$(printf '%q' "$APIKEY")"
    [ -n "$APIKEY" ] && s="${s//"$q"/********}"
    printf '%s' "$s"
}

# ----------------------------------------------------------------------------
# Localização do llama-server
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

flash_takes_value() {  # versões novas: -fa on|off|auto ; antigas: -fa (sem valor)
    llama_help | grep -E -- '--flash-attn' | grep -Eq 'on\|off|auto'
}

# ----------------------------------------------------------------------------
# Montagem e validação do comando
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
validate_config() {  # retorna 1 se houver erro bloqueante
    VALIDATION_ERRORS=""; VALIDATION_WARNINGS=""
    local i key type val bin
    if ! bin="$(find_llama_bin)"; then
        VALIDATION_ERRORS="${VALIDATION_ERRORS}- llama-server não encontrado. Configure o caminho em 'Configurações' ou coloque-o no PATH.\n"
    fi
    if [ -z "$MODEL" ]; then
        VALIDATION_ERRORS="${VALIDATION_ERRORS}- Nenhum modelo selecionado.\n"
    elif [ ! -f "$MODEL" ]; then
        VALIDATION_ERRORS="${VALIDATION_ERRORS}- Arquivo do modelo não existe: $MODEL\n"
    elif [ ! -r "$MODEL" ]; then
        VALIDATION_ERRORS="${VALIDATION_ERRORS}- Sem permissão de leitura no modelo: $MODEL\n"
    fi
    for i in "${!P_KEYS[@]}"; do
        key="${P_KEYS[$i]}"; type="${P_TYPE[$i]}"; val="$(get_var "$key")"
        [ -z "$val" ] && continue
        case "$type" in
            int)   [[ "$val" =~ ^-?[0-9]+$ ]] || VALIDATION_ERRORS="${VALIDATION_ERRORS}- ${P_LABEL[$i]} deve ser um número inteiro (atual: '$val').\n" ;;
            float) [[ "$val" =~ ^[0-9]*\.?[0-9]+$ ]] || VALIDATION_ERRORS="${VALIDATION_ERRORS}- ${P_LABEL[$i]} deve ser um número (ex.: 0.7) (atual: '$val').\n" ;;
        esac
    done
    if [ -n "$PORT" ] && [[ "$PORT" =~ ^[0-9]+$ ]]; then
        if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            VALIDATION_ERRORS="${VALIDATION_ERRORS}- Porta deve estar entre 1 e 65535.\n"
        elif ! server_pid >/dev/null && port_in_use "$PORT"; then
            VALIDATION_ERRORS="${VALIDATION_ERRORS}- A porta $PORT já está em uso por outro programa. Escolha outra porta ou feche o programa que a usa.\n"
        fi
    fi
    if [ -n "$MMPROJ" ] && [ ! -f "$MMPROJ" ]; then
        VALIDATION_ERRORS="${VALIDATION_ERRORS}- Arquivo mmproj não existe: $MMPROJ\n"
    fi
    if [ -z "$APIKEY" ]; then
        VALIDATION_WARNINGS="${VALIDATION_WARNINGS}- Sem API Key: qualquer pessoa na sua rede poderá usar o servidor.\n"
    fi
    if [ -n "$CTV" ] && [ "$CTV" != "f16" ] && { [ -z "$FLASH" ] || [ "$FLASH" = "off" ]; }; then
        VALIDATION_WARNINGS="${VALIDATION_WARNINGS}- Cache V quantizado ($CTV) geralmente exige Flash Attention = on.\n"
    fi
    [ -n "$VALIDATION_ERRORS" ] && { log_warn "Validação falhou: $(printf '%b' "$VALIDATION_ERRORS" | tr '\n' ' ')"; return 1; }
    return 0
}

# ----------------------------------------------------------------------------
# Controle do processo do servidor
# ----------------------------------------------------------------------------
server_pid() {  # imprime o PID se o servidor gerenciado estiver vivo
    local pid
    [ -f "$PID_FILE" ] || return 1
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "$pid"; return 0
    fi
    log_info "PID file obsoleto removido (pid=$pid)"
    rm -f "$PID_FILE"
    return 1
}

runinfo_get() {  # runinfo_get CHAVE
    [ -f "$RUNINFO_FILE" ] || return 1
    sed -n "s/^$1=//p" "$RUNINFO_FILE" | head -n 1
}

last_server_log() {
    local l; l="$(runinfo_get LOG)"
    if [ -n "$l" ] && [ -f "$l" ]; then echo "$l"; return 0; fi
    ls -1t "$LOG_DIR"/server-*.log 2>/dev/null | head -n 1
}

health_status() {  # health_status porta -> ok | loading | down
    local port="$1" code
    command -v curl >/dev/null 2>&1 || { port_in_use "$port" && echo ok || echo down; return; }
    code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$port/health" 2>/dev/null)"
    case "$code" in
        200) echo ok ;;
        503) echo loading ;;
        *)   echo down ;;
    esac
}

# Inicia em segundo plano. Define SERVER_LOG. Retorna 0 se o processo subiu.
SERVER_LOG=""
start_server_bg() {
    local pid safe_name
    if pid="$(server_pid)"; then
        log_warn "Tentativa de iniciar com servidor já ativo (pid=$pid)"
        echo "Já existe um servidor em execução (PID $pid). Pare-o primeiro." >&2
        return 2
    fi
    build_cmd
    safe_name="$(printf %s "$(basename "$MODEL" .gguf)" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-60)"
    SERVER_LOG="$LOG_DIR/server-$(date +%Y%m%d-%H%M%S)-$safe_name.log"
    {
        echo "=================================================================="
        echo " llama-tui $VERSION - início: $(date '+%Y-%m-%d %H:%M:%S')"
        echo " Perfil : ${CURRENT_PROFILE:-(sem perfil)}"
        echo " Modelo : $MODEL"
        echo " Comando: $(mask_cmd "$(quote_cmd "${CMD[@]}")")"
        echo "=================================================================="
    } >>"$SERVER_LOG"
    log_info "Iniciando servidor: $(mask_cmd "$(quote_cmd "${CMD[@]}")")"
    log_info "Log do servidor: $SERVER_LOG"

    nohup "${CMD[@]}" >>"$SERVER_LOG" 2>&1 </dev/null &
    pid=$!
    echo "$pid" >"$PID_FILE"
    {
        echo "PID=$pid"; echo "LOG=$SERVER_LOG"; echo "IP=$(primary_ip)"; echo "PORT=${PORT:-8080}"
        echo "MODEL=$MODEL"; echo "PROFILE=$CURRENT_PROFILE"; echo "STARTED=$(date '+%Y-%m-%d %H:%M:%S')"
    } >"$RUNINFO_FILE"
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        log_error "Servidor encerrou imediatamente (pid=$pid). Veja $SERVER_LOG"
        rm -f "$PID_FILE"
        return 1
    fi
    log_info "Servidor iniciado (pid=$pid)"
    return 0
}

stop_server() {  # para o servidor; retorna 0 se parou
    local pid i
    pid="$(server_pid)" || { log_info "Stop solicitado, mas nenhum servidor ativo"; return 3; }
    log_info "Parando servidor (pid=$pid) com SIGTERM"
    kill -TERM "$pid" 2>/dev/null
    for i in $(seq 1 30); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        log_warn "Servidor não respondeu ao SIGTERM em 15s; enviando SIGKILL (pid=$pid)"
        kill -KILL "$pid" 2>/dev/null
        sleep 1
    fi
    if kill -0 "$pid" 2>/dev/null; then
        log_error "Falha ao parar o servidor (pid=$pid)"
        return 1
    fi
    local l; l="$(runinfo_get LOG)"
    [ -n "$l" ] && echo "=== Servidor parado pelo llama-tui em $(date '+%Y-%m-%d %H:%M:%S') ===" >>"$l"
    rm -f "$PID_FILE"
    log_info "Servidor parado (pid=$pid)"
    return 0
}

access_urls() {  # imprime as URLs de acesso para a porta
    local port="${1:-8080}" main ip
    main="$(primary_ip)"
    echo "  Rede (principal): http://$main:$port"
    for ip in $(local_ips); do
        [ "$ip" != "$main" ] && echo "  Rede (outra)    : http://$ip:$port"
    done
    echo "  Esta máquina    : http://127.0.0.1:$port"
}

# =============================================================================
#  MODO CLI (sem TUI)
# =============================================================================
cli_help() {
cat <<EOF
llama-tui $VERSION - lançador para o llama-server (llama.cpp)

USO
  $PROG                     Abre a interface TUI (requer 'dialog')
  $PROG run   <perfil>      Executa em primeiro plano, saída na tela + log (Ctrl+C para)
  $PROG start <perfil>      Inicia em segundo plano e aguarda ficar pronto
  $PROG stop                Para o servidor iniciado pelo llama-tui
  $PROG restart <perfil>    Para (se houver) e inicia com o perfil
  $PROG status              Mostra se o servidor está rodando e os endereços
  $PROG list                Lista os perfis salvos
  $PROG show  <perfil>      Mostra o comando que seria executado
  $PROG logs  [-f]          Mostra (ou acompanha com -f) o log do último servidor
  $PROG applog              Acompanha o log do próprio programa
  $PROG ip                  Mostra o IPv4 desta máquina (usado para acesso remoto)
  $PROG help                Esta ajuda

  <perfil> pode ser o nome de um perfil salvo ou o caminho de um arquivo .conf

ARQUIVOS
  Perfis        : $PROFILE_DIR/<nome>.conf
  Configurações : $SETTINGS_FILE
  Log programa  : $APP_LOG   (append; arquivado ao passar de 5 MB)
  Logs servidor : $LOG_DIR/server-<data>-<modelo>.log  (um por execução)

CÓDIGOS DE SAÍDA
  0 ok | 1 erro | 2 servidor já em execução | 3 nenhum servidor em execução
EOF
}

cli_require_profile() {
    [ -n "$1" ] || { echo "ERRO: informe o nome do perfil. Perfis disponíveis:" >&2; list_profiles | sed 's/^/  /' >&2; exit 1; }
    load_profile "$1" || { echo "ERRO: perfil '$1' não encontrado em $PROFILE_DIR" >&2; exit 1; }
}

cli_validate() {
    if ! validate_config; then
        echo "ERRO: configuração inválida:" >&2
        printf '%b' "$VALIDATION_ERRORS" >&2
        exit 1
    fi
    [ -n "$VALIDATION_WARNINGS" ] && { echo "AVISO:" >&2; printf '%b' "$VALIDATION_WARNINGS" >&2; }
}

cli_wait_ready() {
    local port="$1" pid="$2" t=0 st
    printf 'Aguardando o modelo carregar'
    while [ "$t" -lt "$STARTUP_TIMEOUT" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo; echo "ERRO: o servidor encerrou durante o carregamento. Últimas linhas do log:" >&2
            tail -n 25 "$SERVER_LOG" >&2
            echo "Log completo: $SERVER_LOG" >&2
            rm -f "$PID_FILE"
            log_error "Servidor morreu durante o carregamento (pid=$pid)"
            return 1
        fi
        st="$(health_status "$port")"
        [ "$st" = "ok" ] && { echo " pronto! (${t}s)"; log_info "Servidor pronto em ${t}s"; return 0; }
        printf '.'; sleep 2; t=$((t + 2))
    done
    echo; echo "AVISO: tempo limite de ${STARTUP_TIMEOUT}s atingido; o servidor continua carregando. Acompanhe com: $PROG logs -f"
    log_warn "Timeout de inicialização (${STARTUP_TIMEOUT}s)"
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
            [ $n -eq 0 ] && echo "Nenhum perfil salvo em $PROFILE_DIR"
            ;;
        show)
            cli_require_profile "$1"; build_cmd
            quote_cmd "${CMD[@]}"; echo
            ;;
        run)
            cli_require_profile "$1"; cli_validate; build_cmd
            if server_pid >/dev/null; then echo "ERRO: já existe um servidor em execução (PID $(server_pid))." >&2; exit 2; fi
            local safe; safe="$(printf %s "$(basename "$MODEL" .gguf)" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-60)"
            SERVER_LOG="$LOG_DIR/server-$(date +%Y%m%d-%H%M%S)-$safe.log"
            {
                echo "=================================================================="
                echo " llama-tui $VERSION (run/foreground) - início: $(date '+%Y-%m-%d %H:%M:%S')"
                echo " Perfil : $CURRENT_PROFILE"
                echo " Comando: $(mask_cmd "$(quote_cmd "${CMD[@]}")")"
                echo "=================================================================="
            } | tee -a "$SERVER_LOG"
            echo "Endereços de acesso:"; access_urls "${PORT:-8080}"
            echo "Log: $SERVER_LOG   (Ctrl+C para parar)"
            log_info "Run (foreground): $(mask_cmd "$(quote_cmd "${CMD[@]}")")"
            trap ':' INT   # o Ctrl+C encerra o llama-server; o script continua para registrar o fim
            "${CMD[@]}" 2>&1 | tee -i -a "$SERVER_LOG"
            local rc=${PIPESTATUS[0]}
            echo "=== Encerrado em $(date '+%Y-%m-%d %H:%M:%S') (código $rc) ===" | tee -a "$SERVER_LOG"
            log_info "Run (foreground) terminou com código $rc"
            exit "$rc"
            ;;
        start)
            cli_require_profile "$1"; cli_validate
            start_server_bg; local rc=$?
            [ $rc -eq 2 ] && exit 2
            if [ $rc -ne 0 ]; then
                echo "ERRO: o servidor não iniciou. Últimas linhas:" >&2; tail -n 25 "$SERVER_LOG" >&2
                echo "Log completo: $SERVER_LOG" >&2; exit 1
            fi
            echo "Servidor iniciado (PID $(cat "$PID_FILE")). Log: $SERVER_LOG"
            cli_wait_ready "${PORT:-8080}" "$(cat "$PID_FILE")" || exit 1
            echo "Endereços de acesso:"; access_urls "${PORT:-8080}"
            echo "Para parar: $PROG stop"
            ;;
        stop)
            stop_server; case $? in
                0) echo "Servidor parado." ;;
                3) echo "Nenhum servidor do llama-tui em execução."; exit 3 ;;
                *) echo "ERRO: não foi possível parar o servidor. Veja $APP_LOG" >&2; exit 1 ;;
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
                echo "Servidor RODANDO (PID $pid) - estado: $(health_status "$p")"
                echo "  Desde : $(runinfo_get STARTED)"
                echo "  Perfil: $(runinfo_get PROFILE)"
                echo "  Modelo: $(runinfo_get MODEL)"
                echo "  Log   : $(runinfo_get LOG)"
                access_urls "$p"
            else
                echo "Nenhum servidor do llama-tui em execução. IP desta máquina: $(primary_ip)"; exit 3
            fi
            ;;
        logs)
            local l; l="$(last_server_log)"
            [ -n "$l" ] || { echo "Nenhum log de servidor encontrado."; exit 1; }
            echo "==> $l"
            if [ "$1" = "-f" ]; then tail -n 50 -f "$l"; else tail -n 100 "$l"; fi
            ;;
        applog) tail -n 50 -f "$APP_LOG" ;;
        ip) primary_ip ;;
        *) echo "Comando desconhecido: $cmd" >&2; echo "Use: $PROG help" >&2; exit 1 ;;
    esac
}

# =============================================================================
#  MODO TUI (dialog)
# =============================================================================
BACKTITLE="llama-tui $VERSION  |  Setas/Tab navegam, Enter confirma, Esc volta"

term_size() {
    TL=$(tput lines 2>/dev/null || echo 24); TC=$(tput cols 2>/dev/null || echo 80)
    [ "$TL" -lt 20 ] && TL=20; [ "$TC" -lt 70 ] && TC=70
}

# d: executa o dialog e devolve a escolha em $REPLY; retorno = código do dialog
d() {
    local rc
    # --cr-wrap: respeita as quebras de linha dos textos; rótulos padrão em português
    REPLY="$(dialog --backtitle "$BACKTITLE" --colors --cr-wrap \
        --ok-label "OK" --cancel-label "Cancelar" --yes-label "Sim" --no-label "Não" \
        --help-label "Ajuda" --exit-label "Voltar" "$@" 2>&1 >/dev/tty)"
    rc=$?
    [ $rc -eq 255 ] && [ -n "$REPLY" ] && log_error "dialog: $REPLY"
    return $rc
}

msg()  { term_size; d --title "$1" --msgbox "$2" $((TL - 4)) $((TC - 6)); }
info() { d --title "${2:-Aguarde}" --infobox "$1" 7 60; }
ask()  { term_size; d --title "$1" --yesno "$2" $((TL > 22 ? 20 : TL - 4)) $((TC - 10)); }

status_line() {
    local pid
    if pid="$(server_pid)"; then
        echo "\\Z2\\ZbSERVIDOR RODANDO\\Zn (PID $pid, porta $(runinfo_get PORT))"
    else
        echo "\\Z1Servidor parado\\Zn"
    fi
}

model_label() {
    if [ -n "$MODEL" ]; then
        local s=""; [ -f "$MODEL" ] && s=" ($(human_size "$(file_size "$MODEL")"))"
        echo "$(basename "$MODEL")$s"
    else
        echo "(nenhum)"
    fi
}

# ---------------- Seleção de modelo ----------------
FOUND_MODELS=()
scan_models() {  # scan_models [filtro]
    local filter="$1" dir f old_ifs="$IFS"
    FOUND_MODELS=()
    IFS=':'
    for dir in $MODEL_DIRS; do
        IFS="$old_ifs"
        dir="${dir/#\~/$HOME}"
        [ -d "$dir" ] || continue
        while IFS= read -r f; do
            case "$f" in
                *-0000[2-9]-of-*|*-000[1-9][0-9]-of-*) continue ;;   # partes 2+ de modelos divididos
                */mmproj*|*mmproj-*) continue ;;
            esac
            if [ -n "$filter" ]; then
                echo "$f" | grep -qi -- "$filter" || continue
            fi
            FOUND_MODELS+=("$f")
        done < <(find -L "$dir" -type f -iname '*.gguf' 2>/dev/null | sort)
    done
    IFS="$old_ifs"
    log_info "Busca de modelos (filtro='$filter'): ${#FOUND_MODELS[@]} encontrados em $MODEL_DIRS"
}

pick_from_found() {
    local items=() i f
    if [ ${#FOUND_MODELS[@]} -eq 0 ]; then
        msg "Nenhum modelo" "Nenhum arquivo .gguf foi encontrado nas pastas de busca:\n\n$(echo "$MODEL_DIRS" | tr ':' '\n')\n\nDicas:\n - Adicione a pasta dos seus modelos em 'Pastas de busca'.\n - Ou use 'Navegar no sistema de arquivos' / 'Digitar caminho'."
        return 1
    fi
    for i in "${!FOUND_MODELS[@]}"; do
        f="${FOUND_MODELS[$i]}"
        items+=("$((i + 1))" "$(human_size "$(file_size "$f")")  $(basename "$f")" "$f")
    done
    term_size
    d --title "Modelos encontrados (${#FOUND_MODELS[@]})" --item-help \
      --menu "Escolha o modelo. O caminho completo aparece na linha inferior." \
      $((TL - 4)) $((TC - 6)) $((TL - 12)) "${items[@]}" || return 1
    MODEL="${FOUND_MODELS[$((REPLY - 1))]}"
    log_info "Modelo selecionado: $MODEL"
    return 0
}

menu_model() {
    while true; do
        term_size
        d --title "Selecionar modelo" --cancel-label "Voltar" --menu \
"Modelo atual: \\Zb$(model_label)\\Zn\n\nO modelo é um arquivo .gguf. Escolha como localizá-lo:" \
          $((TL - 4)) $((TC - 6)) 7 \
          1 "Listar todos os .gguf das pastas de busca" \
          2 "Buscar por nome (filtro)" \
          3 "Navegar no sistema de arquivos" \
          4 "Digitar/colar o caminho do arquivo" \
          5 "Gerenciar pastas de busca" || return
        case "$REPLY" in
            1) info "Procurando arquivos .gguf..."; scan_models ""; pick_from_found && return ;;
            2) d --title "Filtro" --inputbox "Parte do nome do modelo (sem diferenciar maiúsculas).\nEx.: qwen, llama-3, Q4_K_M" 10 60 "" || continue
               info "Procurando '$REPLY'..."; scan_models "$REPLY"; pick_from_found && return ;;
            3) local start="${MODEL%/*}"; [ -d "$start" ] || start="$HOME/"
               msg "Como navegar" "No explorador a seguir:\n\n - TAB alterna entre a lista de pastas, a de arquivos e o campo de caminho.\n - Setas movem; ESPAÇO entra na pasta / seleciona o arquivo.\n - Você também pode editar o caminho diretamente no campo inferior.\n - Enter (OK) confirma o arquivo selecionado."
               term_size
               d --title "Escolha o arquivo .gguf" --fselect "${start%/}/" $((TL - 10)) $((TC - 8)) || continue
               if [ -f "$REPLY" ]; then
                   case "$REPLY" in *.gguf|*.GGUF) ;; *) ask "Aviso" "O arquivo não termina em .gguf:\n$REPLY\n\nUsar mesmo assim?" || continue ;; esac
                   MODEL="$REPLY"; log_info "Modelo selecionado (fselect): $MODEL"; return
               else
                   msg "Arquivo inválido" "O caminho selecionado não é um arquivo:\n\n$REPLY\n\nNavegue até o arquivo e selecione-o com ESPAÇO antes de confirmar."
               fi ;;
            4) d --title "Caminho do modelo" --inputbox "Caminho completo do arquivo .gguf (~ é aceito):" 9 $((TC - 10)) "$MODEL" || continue
               local p="${REPLY/#\~/$HOME}"
               if [ -f "$p" ]; then MODEL="$p"; log_info "Modelo selecionado (manual): $MODEL"; return
               else msg "Arquivo não encontrado" "Não existe arquivo em:\n\n$p"; fi ;;
            5) d --title "Pastas de busca" --inputbox \
"Pastas onde procurar modelos, separadas por ':' (dois-pontos).\nA busca é recursiva e segue links simbólicos.\n\nExemplo: ~/models:/mnt/ssd/gguf" 12 $((TC - 10)) "$MODEL_DIRS" || continue
               MODEL_DIRS="$REPLY"; save_settings ;;
        esac
    done
}

# ---------------- Edição de parâmetros ----------------
display_value() {  # índice -> valor legível
    local i="$1" v; v="$(get_var "${P_KEYS[$i]}")"
    case "${P_TYPE[$i]}" in
        bool) [ -n "$v" ] && echo "[x] ligado" || echo "[ ] desligado" ;;
        *) if [ -z "$v" ]; then echo "(padrão)"
           elif [ "${P_KEYS[$i]}" = "APIKEY" ]; then echo "********"
           else echo "$v"; fi ;;
    esac
}

pad() {  # pad texto largura  (conta caracteres, não bytes, para alinhar acentos)
    local t="$1"
    while [ ${#t} -lt "$2" ]; do t="$t "; done
    printf '%s' "$t"
}

show_param_doc() {  # índice: mostra a documentação completa (rolável)
    local idx="$1" tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/llama-tui.XXXXXX")"
    printf '%s\n\nFlag: %s\n%s\n' "${P_LABEL[$idx]}" "${P_FLAG[$idx]:-(argumentos livres)}" "${P_DOC[$idx]}" >"$tmp"
    term_size
    d --title "Ajuda: ${P_LABEL[$idx]}" --textbox "$tmp" $((TL - 4)) $((TC - 6))
    rm -f "$tmp"
}

edit_param() {  # índice do parâmetro em P_KEYS
    local idx="$1"
    local key="${P_KEYS[$idx]}" type="${P_TYPE[$idx]}" label="${P_LABEL[$idx]}"
    local flag="${P_FLAG[$idx]:-(livre)}" cur new rc w header opts o items def
    cur="$(get_var "$key")"
    term_size
    w=$((TC - 8)); [ "$w" -gt 76 ] && w=76
    header="Flag: $flag\n${P_SHORT[$idx]}\n\nValor atual: $(display_value "$idx")"

    case "$type" in
        bool)
            [ -n "$cur" ] && def="ligado" || def="desligado"
            while true; do
                d --title "$label" --help-button --default-item "$def" --menu \
                  "$header\n\nEscolha com as setas e confirme com Enter.\n<Ajuda> mostra a explicação completa." \
                  16 "$w" 2 \
                  ligado    "Ligado    (passa $flag)" \
                  desligado "Desligado (não passa)"
                rc=$?
                [ $rc -eq 2 ] && { show_param_doc "$idx"; continue; }
                [ $rc -ne 0 ] && return
                [ "$REPLY" = "ligado" ] && new="1" || new=""
                break
            done ;;
        choice:*)
            opts="${type#choice:}"; items=()
            local old_ifs="$IFS"; IFS=','
            set -f
            for o in $opts; do
                if [ -z "$o" ]; then items+=("padrao" "não passar (padrão do llama-server)")
                else items+=("$o" "$flag $o"); fi
            done
            set +f
            IFS="$old_ifs"
            [ -n "$cur" ] && def="$cur" || def="padrao"
            while true; do
                d --title "$label" --help-button --default-item "$def" --menu \
                  "$header\n\nEscolha com as setas e confirme com Enter.\n<Ajuda> mostra a explicação completa." \
                  $((10 + ${#items[@]} / 2 + 6)) "$w" $((${#items[@]} / 2)) "${items[@]}"
                rc=$?
                [ $rc -eq 2 ] && { show_param_doc "$idx"; continue; }
                [ $rc -ne 0 ] && return
                new="$REPLY"; [ "$new" = "padrao" ] && new=""
                break
            done ;;
        *)
            new="$cur"
            while true; do
                d --title "$label" --help-button --inputbox \
                  "$header\n\nDigite o novo valor e tecle Enter.\nDeixe VAZIO para não passar o parâmetro (usa o padrão do llama-server).\n<Ajuda> mostra a explicação completa." \
                  16 "$w" "$new"
                rc=$?
                [ $rc -eq 2 ] && { show_param_doc "$idx"; continue; }
                [ $rc -ne 0 ] && return
                new="$(printf '%s' "$REPLY" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
                new="${new/#\~/$HOME}"
                case "$type" in
                    int)   if [ -n "$new" ] && ! [[ "$new" =~ ^-?[0-9]+$ ]]; then
                               msg "Valor inválido" "'$label' aceita apenas números inteiros.\n\nValor digitado: '$new'"; continue; fi ;;
                    float) if [ -n "$new" ] && ! [[ "$new" =~ ^[0-9]*\.?[0-9]+$ ]]; then
                               msg "Valor inválido" "'$label' aceita números como 0.7 (use ponto, não vírgula).\n\nValor digitado: '$new'"; continue; fi ;;
                esac
                if [ "$key" = "PORT" ] && [ -n "$new" ] && { [ "$new" -lt 1 ] || [ "$new" -gt 65535 ]; }; then
                    msg "Valor inválido" "A porta deve estar entre 1 e 65535.\n\nValor digitado: '$new'"; continue
                fi
                if [ "$key" = "MMPROJ" ] && [ -n "$new" ] && [ ! -f "$new" ]; then
                    msg "Arquivo não encontrado" "Não existe arquivo em:\n\n$new"; continue
                fi
                break
            done ;;
    esac

    eval "$key=\$new"
    log_info "Parâmetro $key alterado: '$([ "$key" = APIKEY ] && echo '***' || echo "$cur")' -> '$([ "$key" = APIKEY ] && echo '***' || echo "$new")'"
}

menu_params() {
    local sel=a items n lw tags="abcdefghijklmnopqrstuvwxyz"
    while true; do
        items=()
        for n in "${!P_KEYS[@]}"; do
            items+=("${tags:$n:1}" "$(pad "${P_LABEL[$n]}" 24) $(display_value "$n")" "${P_FLAG[$n]:+${P_FLAG[$n]}: }${P_SHORT[$n]}")
        done
        items+=("0" "Restaurar valores padrão" "Volta todos os parâmetros aos valores iniciais (mantém o modelo)")
        items+=("?" "Ajuda de todos os parâmetros" "Mostra a explicação completa de cada parâmetro")
        term_size
        lw=$((TL - 12)); [ "$lw" -gt $(( ${#items[@]} / 3 )) ] && lw=$(( ${#items[@]} / 3 ))
        d --title "Parâmetros do servidor" --item-help --cancel-label "Voltar" --default-item "$sel" --menu \
          "Tecle a letra ou use as setas + Enter para editar. A descrição aparece no rodapé.\n(padrão) = não é passado; o llama-server usa o valor dele." \
          $((lw + 8)) $((TC - 6)) "$lw" "${items[@]}" || return
        sel="$REPLY"
        case "$REPLY" in
            0) if ask "Restaurar" "Voltar todos os parâmetros aos valores padrão?\n(O modelo selecionado é mantido.)"; then
                   local m="$MODEL"; reset_params; MODEL="$m"; log_info "Parâmetros restaurados ao padrão"
               fi ;;
            \?) local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/llama-tui.XXXXXX")"
               for n in "${!P_KEYS[@]}"; do
                   printf '=== %s  (%s) ===\n%s\n\n' "${P_LABEL[$n]}" "${P_FLAG[$n]:-livre}" "${P_DOC[$n]}"
               done >"$tmp"
               term_size; d --title "Ajuda dos parâmetros" --textbox "$tmp" $((TL - 4)) $((TC - 6)); rm -f "$tmp" ;;
            [a-z]) n="${tags%%"$REPLY"*}"; edit_param "${#n}" ;;
        esac
    done
}

# ---------------- Perfis ----------------
menu_load_profile() {
    local items=() p m
    for p in $(list_profiles); do
        m="$(sed -n 's/^MODEL=//p' "$PROFILE_DIR/$p.conf" | head -n 1)"
        items+=("$p" "$(basename "$m")")
    done
    [ ${#items[@]} -eq 0 ] && { msg "Perfis" "Nenhum perfil salvo ainda.\n\nConfigure modelo e parâmetros e use 'Salvar perfil'."; return; }
    term_size
    d --title "Carregar perfil" --extra-button --extra-label "Excluir" --cancel-label "Voltar" --menu \
      "Perfis salvos em:\n$PROFILE_DIR\n\nOK carrega o perfil; 'Excluir' apaga o arquivo do perfil." \
      $((TL - 4)) $((TC - 6)) $((TL - 12)) "${items[@]}"
    case $? in
        0) if load_profile "$REPLY"; then
               msg "Perfil carregado" "Perfil '\\Zb$REPLY\\Zn' carregado.\n\nModelo: $(model_label)\n\nDica: execute direto pelo terminal com:\n  $PROG run $REPLY"
           else msg "Erro" "Não foi possível carregar o perfil '$REPLY'. Veja o log:\n$APP_LOG"; fi ;;
        3) local victim="$REPLY"
           if ask "Excluir perfil" "Excluir definitivamente o perfil '$victim'?\n\n$PROFILE_DIR/$victim.conf"; then
               rm -f "$PROFILE_DIR/$victim.conf" && log_info "Perfil excluído: $victim"
               [ "$CURRENT_PROFILE" = "$victim" ] && CURRENT_PROFILE=""
           fi ;;
    esac
}

menu_save_profile() {
    local def="$CURRENT_PROFILE" name
    [ -z "$def" ] && [ -n "$MODEL" ] && def="$(printf %s "$(basename "$MODEL" .gguf)" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-40)"
    d --title "Salvar perfil" --inputbox "Nome do perfil (letras, números, ponto, - e _).\nSe já existir, será sobrescrito." 10 60 "$def" || return
    name="$REPLY"
    if ! [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then msg "Nome inválido" "Use apenas letras, números, ponto, hífen e sublinhado.\nDigitado: '$name'"; return; fi
    if [ -f "$PROFILE_DIR/$name.conf" ] && [ "$name" != "$CURRENT_PROFILE" ]; then
        ask "Sobrescrever?" "Já existe um perfil chamado '$name'. Sobrescrever?" || return
    fi
    if save_kv_file "$PROFILE_DIR/$name.conf" "$PROFILE_KEYS" "Perfil llama-tui: $name"; then
        CURRENT_PROFILE="$name"
        msg "Perfil salvo" "Perfil '\\Zb$name\\Zn' salvo em:\n$PROFILE_DIR/$name.conf\n\nPara rodar sem abrir a TUI:\n  $PROG run $name      (primeiro plano)\n  $PROG start $name    (segundo plano)\n  $PROG stop"
    else
        msg "Erro" "Falha ao salvar o perfil. Veja o log:\n$APP_LOG"
    fi
}

# ---------------- Servidor ----------------
show_command() {
    build_cmd
    local warn=""; validate_config || warn="\n\n\\Z1Problemas encontrados:\\Zn\n$VALIDATION_ERRORS"
    [ -n "$VALIDATION_WARNINGS" ] && warn="$warn\n\\Z3Avisos:\\Zn\n$VALIDATION_WARNINGS"
    msg "Comando gerado" "Este é o comando que será executado (pode copiar e usar no terminal):\n\n$(mask_cmd "$(quote_cmd "${CMD[@]}")")$warn"
}

tui_start() {
    local pid
    if pid="$(server_pid)"; then
        msg "Já em execução" "Já existe um servidor rodando (PID $pid).\n\nPare-o primeiro em 'Parar servidor' para iniciar outro modelo."
        return
    fi
    if ! validate_config; then
        msg "Não é possível iniciar" "Corrija os itens abaixo antes de iniciar:\n\n$VALIDATION_ERRORS"
        return
    fi
    if [ -n "$VALIDATION_WARNINGS" ]; then
        ask "Avisos" "Atenção:\n\n$VALIDATION_WARNINGS\nDeseja iniciar mesmo assim?" || return
    fi
    save_last
    build_cmd
    ask "Iniciar servidor" "Modelo: \\Zb$(model_label)\\Zn\nEndereço: http://$(primary_ip):${PORT:-8080}\n\nComando:\n$(mask_cmd "$(quote_cmd "${CMD[@]}")")\n\nIniciar agora?" || return

    start_server_bg
    if [ $? -ne 0 ]; then
        msg "Falha ao iniciar" "O llama-server encerrou logo após iniciar.\n\nÚltimas linhas do log:\n\n$(tail -n 15 "$SERVER_LOG")\n\nLog completo:\n$SERVER_LOG"
        return
    fi
    pid="$(cat "$PID_FILE")"

    # Aguarda carregar mostrando o progresso; Ctrl+C interrompe apenas a espera
    local t=0 st="" aborted=0
    trap 'aborted=1' INT
    while [ "$t" -lt "$STARTUP_TIMEOUT" ] && [ $aborted -eq 0 ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            trap - INT; rm -f "$PID_FILE"
            log_error "Servidor morreu durante o carregamento (pid=$pid)"
            msg "O servidor encerrou com erro" "O llama-server parou durante o carregamento.\n\nCausas comuns: memória insuficiente (reduza Contexto ou Camadas na GPU), arquivo corrompido, parâmetro não suportado pela sua versão.\n\nÚltimas linhas:\n\n$(tail -n 15 "$SERVER_LOG")\n\nLog completo: $SERVER_LOG"
            return
        fi
        st="$(health_status "${PORT:-8080}")"
        [ "$st" = "ok" ] && break
        term_size
        dialog --backtitle "$BACKTITLE" --cr-wrap --no-collapse --title "Carregando modelo... ${t}s (Ctrl+C para parar de esperar)" \
               --infobox "$(tail -n $((TL - 8)) "$SERVER_LOG" | cut -c1-$((TC - 10)))" $((TL - 4)) $((TC - 6))
        sleep 2; t=$((t + 2))
    done
    trap - INT
    if [ "$st" = "ok" ]; then
        log_info "Servidor pronto em ${t}s"
        msg "Servidor pronto!" "\\Z2\\ZbO servidor está no ar\\Zn (PID $pid, carregou em ${t}s).\n\nAcesse pelo navegador ou use como API OpenAI (/v1):\n$(access_urls "${PORT:-8080}")\n\nUse 'Ver saída do servidor' para acompanhar as requisições.\nLog: $SERVER_LOG"
    else
        log_warn "Servidor ainda carregando após ${t}s (espera encerrada)"
        msg "Ainda carregando" "O servidor continua carregando em segundo plano (PID $pid).\nAcompanhe em 'Ver saída do servidor'."
    fi
}

tui_stop() {
    local pid
    pid="$(server_pid)" || { msg "Parar servidor" "Nenhum servidor em execução."; return; }
    ask "Parar servidor" "Parar o servidor (PID $pid)?\n\nModelo: $(basename "$(runinfo_get MODEL)")\n\nClientes conectados serão desconectados." || return
    info "Parando o servidor (PID $pid)..."
    if stop_server; then
        msg "Servidor parado" "Servidor encerrado.\n\nAgora você pode escolher outro modelo/parâmetros e iniciar novamente."
    else
        msg "Erro" "Não foi possível parar o processo $pid.\nTente manualmente: kill -9 $pid\n\nLog: $APP_LOG"
    fi
}

tui_view_output() {
    local l; l="$(last_server_log)"
    [ -n "$l" ] || { msg "Saída do servidor" "Nenhum log de servidor ainda. Inicie o servidor primeiro."; return; }
    term_size
    if server_pid >/dev/null; then
        d --title "Saída ao vivo: $(basename "$l")  (Enter/Esc para voltar - o servidor continua)" \
          --exit-label "Voltar" --tailbox "$l" $((TL - 3)) $((TC - 4))
    else
        d --title "Último log (servidor parado): $(basename "$l")" --exit-label "Voltar" --textbox "$l" $((TL - 3)) $((TC - 4))
    fi
}

tui_status() {
    local pid txt
    if pid="$(server_pid)"; then
        local p; p="$(runinfo_get PORT)"
        txt="\\Z2\\ZbRODANDO\\Zn - estado: $(health_status "$p")\n\nPID    : $pid\nDesde  : $(runinfo_get STARTED)\nPerfil : $(runinfo_get PROFILE)\nModelo : $(runinfo_get MODEL)\nLog    : $(runinfo_get LOG)\n\nEndereços de acesso:\n$(access_urls "$p")\n\nAPI OpenAI: acrescente /v1 ao endereço (ex.: http://IP:$p/v1)"
    else
        txt="\\Z1Nenhum servidor em execução.\\Zn"
    fi
    txt="$txt\n\nllama-server: $(find_llama_bin || echo 'NÃO ENCONTRADO')\nCPUs: $(cpu_count)   Sistema: $(uname -sm)"
    msg "Status" "$txt"
}

tui_logs() {
    term_size
    d --title "Logs" --cancel-label "Voltar" --menu "Logs ficam em:\n$LOG_DIR\n\nNenhum log é sobrescrito: cada execução do servidor gera um arquivo novo." \
      $((TL - 4)) $((TC - 6)) 4 \
      1 "Log do programa (llama-tui.log) - últimas 500 linhas" \
      2 "Escolher um log de execução do servidor" || return
    case "$REPLY" in
        1) local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/llama-tui.XXXXXX")"; tail -n 500 "$APP_LOG" >"$tmp"
           d --title "llama-tui.log" --exit-label "Voltar" --textbox "$tmp" $((TL - 3)) $((TC - 4)); rm -f "$tmp" ;;
        2) local items=() f
           for f in $(ls -1t "$LOG_DIR"/server-*.log 2>/dev/null | head -n 40); do
               items+=("$(basename "$f")" "$(human_size "$(file_size "$f")")")
           done
           [ ${#items[@]} -eq 0 ] && { msg "Logs" "Nenhum log de servidor ainda."; return; }
           d --title "Logs do servidor (mais recentes primeiro)" --menu "Escolha:" $((TL - 4)) $((TC - 6)) $((TL - 10)) "${items[@]}" || return
           d --title "$REPLY" --exit-label "Voltar" --textbox "$LOG_DIR/$REPLY" $((TL - 3)) $((TC - 4)) ;;
    esac
}

tui_settings() {
    while true; do
        term_size
        d --title "Configurações" --cancel-label "Voltar" --menu "Configurações gerais (salvas em $SETTINGS_FILE)" \
          $((TL - 4)) $((TC - 6)) 4 \
          1 "Caminho do llama-server: $(find_llama_bin || echo 'NÃO ENCONTRADO')" \
          2 "Pastas de busca de modelos" \
          3 "Tempo máximo de espera no carregamento: ${STARTUP_TIMEOUT}s" || return
        case "$REPLY" in
            1) d --title "llama-server" --inputbox "Caminho completo do executável llama-server.\nDeixe vazio para detectar automaticamente (PATH e locais comuns).\n\nEx.: ~/llama.cpp/build/bin/llama-server" 12 $((TC - 10)) "$LLAMA_BIN" || continue
               local b="${REPLY/#\~/$HOME}"
               if [ -n "$b" ] && [ ! -x "$b" ]; then msg "Inválido" "Não é um executável:\n$b"; continue; fi
               LLAMA_BIN="$b"; LLAMA_HELP_CACHE=""; save_settings
               local bin; if bin="$(find_llama_bin)"; then
                   msg "llama-server" "Usando: $bin\n\nVersão:\n$("$bin" --version 2>&1 | head -n 4)"
               fi ;;
            2) d --title "Pastas de busca" --inputbox "Pastas separadas por ':'" 9 $((TC - 10)) "$MODEL_DIRS" || continue
               MODEL_DIRS="$REPLY"; save_settings ;;
            3) d --title "Tempo de espera" --inputbox "Segundos para aguardar o modelo carregar antes de devolver o controle.\n(O servidor continua carregando mesmo depois.)" 10 60 "$STARTUP_TIMEOUT" || continue
               [[ "$REPLY" =~ ^[0-9]+$ ]] && { STARTUP_TIMEOUT="$REPLY"; save_settings; } || msg "Inválido" "Digite apenas números." ;;
        esac
    done
}

tui_quit() {
    local pid
    save_last
    if pid="$(server_pid)"; then
        d --title "Sair" --yes-label "Parar e sair" --no-label "Deixar rodando" --extra-button --extra-label "Cancelar" --yesno \
"O servidor ainda está rodando (PID $pid).\n\n - Parar e sair: encerra o servidor.\n - Deixar rodando: sai e o servidor continua em segundo plano\n   (pare depois com: $PROG stop)" 13 70
        case $? in
            0) info "Parando o servidor..."; stop_server ;;
            1) log_info "Saindo e mantendo servidor ativo (pid=$pid)" ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

tui_main() {
    if ! command -v dialog >/dev/null 2>&1; then
        echo "A interface TUI precisa do programa 'dialog'. Instale com:" >&2
        echo "  macOS : brew install dialog" >&2
        echo "  Debian/Ubuntu: sudo apt install dialog" >&2
        echo "  Fedora: sudo dnf install dialog   |  Arch: sudo pacman -S dialog" >&2
        echo "Os comandos de linha (run/start/stop/...) funcionam sem ele. Veja: $PROG help" >&2
        log_error "dialog não encontrado"
        exit 1
    fi
    [ -t 0 ] && [ -t 1 ] || { echo "A TUI precisa de um terminal interativo." >&2; exit 1; }
    log_info "TUI iniciada (bash $BASH_VERSION, $(uname -sm), dialog $(dialog --version 2>&1 | head -n1), llama-server: $(find_llama_bin || echo 'não encontrado'))"
    trap 'clear; log_info "TUI encerrada"' EXIT
    trap 'log_warn "Recebido sinal de término"; exit 130' TERM HUP

    [ -f "$LAST_FILE" ] && load_kv_file "$LAST_FILE" "$PROFILE_KEYS"

    if ! find_llama_bin >/dev/null; then
        msg "llama-server não encontrado" "Não encontrei o executável 'llama-server' no PATH nem em locais comuns.\n\nInforme o caminho em 'Configurações' antes de iniciar o servidor.\n\n(Compile o llama.cpp ou instale com: brew install llama.cpp)"
    fi

    local sel=1
    while true; do
        term_size
        d --title "llama-server - painel${CURRENT_PROFILE:+ (perfil: $CURRENT_PROFILE)}" --cancel-label "Sair" --default-item "$sel" --menu \
"$(status_line)\nModelo: \\Zb$(model_label)\\Zn\nIP desta máquina: \\Zb$(primary_ip)\\Zn   Porta: ${PORT:-8080}   Contexto: ${CTX:-padrão}   GPU layers: ${NGL:-padrão}" \
          $((TL - 4)) $((TC - 6)) 12 \
          1  "Selecionar modelo (.gguf)" \
          2  "Configurar parâmetros" \
          3  "Carregar perfil salvo" \
          4  "Salvar configuração atual como perfil" \
          5  "Ver comando gerado" \
          6  ">> INICIAR servidor" \
          7  "Ver saída do servidor (ao vivo)" \
          8  "[] PARAR servidor" \
          9  "Status e endereços de acesso remoto" \
          L  "Logs" \
          C  "Configurações (caminho do llama-server, pastas)" \
          S  "Sair"
        [ $? -ne 0 ] && REPLY=S
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
            C) tui_settings ;;
            S) tui_quit && break ;;
        esac
    done
}

# =============================================================================
if [ $# -gt 0 ]; then
    cli_main "$@"
else
    tui_main
fi
