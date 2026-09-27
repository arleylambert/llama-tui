# llama-tui

Um painel de terminal (TUI) para iniciar, acompanhar e parar o **`llama-server`** do [llama.cpp](https://github.com/ggml-org/llama.cpp) sem precisar editar scripts toda vez que você troca de modelo ou de parâmetros.

- Escolha o modelo `.gguf` navegando ou buscando no seu disco
- Ajuste os principais parâmetros do servidor, cada um com uma explicação
- Inicie o servidor e acompanhe a saída ao vivo, com os endereços para acesso remoto
- Pare o servidor, troque o modelo e inicie de novo sem sair do programa
- Salve configurações como **perfis** e rode direto pelo terminal, sem abrir a TUI
- Logs detalhados que nunca são sobrescritos

Um único arquivo em bash, compatível com **macOS** (bash 3.2 nativo) e **Linux**.

---

## Sumário

- [Requisitos](#requisitos)
- [Instalação](#instalação)
- [Uso rápido](#uso-rápido)
- [A interface (TUI)](#a-interface-tui)
- [Parâmetros disponíveis](#parâmetros-disponíveis)
- [Perfis](#perfis)
- [Linha de comando (sem TUI)](#linha-de-comando-sem-tui)
- [Acesso remoto](#acesso-remoto)
- [Logs](#logs)
- [Arquivos e pastas](#arquivos-e-pastas)
- [Solução de problemas](#solução-de-problemas)
- [Licença](#licença)

---

## Requisitos

| Dependência | Obrigatória? | Para quê |
|---|---|---|
| `bash` 3.2+ | Sim | Já vem no macOS e no Linux |
| [`llama-server`](https://github.com/ggml-org/llama.cpp) | Sim | O servidor que será iniciado |
| `dialog` | Só para a TUI | Desenha a interface. Os comandos de terminal funcionam sem ele |
| `curl` | Recomendado | Verifica quando o modelo terminou de carregar (`/health`) |

Instalando o `dialog`:

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

Se ainda não tem o `llama-server`, no macOS o jeito mais simples é `brew install llama.cpp`. Também é possível [compilar o llama.cpp](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md) a partir do código.

## Instalação

```bash
git clone https://github.com/<seu-usuario>/llama-tui.git
cd llama-tui
chmod +x llama-tui.sh
```

Opcional: deixar o comando `llama-tui` disponível em qualquer pasta:

```bash
mkdir -p ~/.local/bin
ln -s "$(pwd)/llama-tui.sh" ~/.local/bin/llama-tui
```

> Confirme que `~/.local/bin` está no seu `PATH` (`echo $PATH`). Se não estiver, adicione `export PATH="$HOME/.local/bin:$PATH"` ao seu `~/.zshrc` ou `~/.bashrc`.

## Uso rápido

```bash
./llama-tui.sh
```

1. **Selecionar modelo**: escolha o arquivo `.gguf`
2. **Configurar parâmetros**: ajuste contexto, camadas na GPU, porta etc.
3. **Salvar configuração atual como perfil** (opcional)
4. **INICIAR servidor**: aguarde o carregamento e anote os endereços exibidos
5. **Ver saída do servidor** para acompanhar as requisições
6. **PARAR servidor** quando quiser trocar de modelo

Na próxima vez que abrir, a última configuração usada é restaurada.

## A interface (TUI)

Navegação: **setas** ou **Tab** para mover, **Enter** para confirmar, **Esc** para voltar. Nas listas de opções, **Espaço** marca o item.

O topo do painel mostra se o servidor está rodando, o modelo selecionado, o endereço, o contexto e as camadas na GPU.

| Opção | O que faz |
|---|---|
| Selecionar modelo | Lista os `.gguf` das pastas de busca, filtra por nome, abre um navegador de arquivos ou aceita um caminho colado |
| Configurar parâmetros | Edita cada parâmetro. A linha de baixo explica o item selecionado; ao editar aparece a explicação completa. A opção `?` mostra a ajuda de todos |
| Carregar perfil salvo | Carrega um perfil. Também permite excluir perfis |
| Salvar configuração atual como perfil | Grava modelo e parâmetros com um nome |
| Ver comando gerado | Mostra o comando exato que será executado, para copiar |
| INICIAR servidor | Valida a configuração, inicia em segundo plano e mostra o carregamento ao vivo |
| Ver saída do servidor | Acompanha o log ao vivo. Enter ou Esc volta ao menu sem parar o servidor |
| PARAR servidor | Encerra o servidor (SIGTERM; SIGKILL se não responder em 15 s) |
| Status e endereços | PID, tempo no ar, modelo, estado (`ok` ou `loading`) e URLs de acesso |
| Logs | Mostra o log do programa ou qualquer log de execução anterior |
| Configurações | Caminho do `llama-server`, pastas de busca e tempo máximo de espera no carregamento |

**Busca de modelos.** As pastas padrão são `~/models`, `~/llama.cpp/models`, `~/.cache/llama.cpp`, `~/.cache/huggingface/hub` e `~/.lmstudio/models`. A busca é recursiva e segue links simbólicos. Arquivos `mmproj-*` e as partes 2 em diante de modelos divididos (`-00002-of-00003.gguf`) são ocultados; basta escolher a primeira parte.

**Validação antes de iniciar.** O programa verifica se o `llama-server` existe, se o modelo existe e pode ser lido, se os campos numéricos são válidos e se a porta está livre. Também avisa sobre combinações arriscadas, como host `0.0.0.0` sem API key.

**Ao sair com o servidor rodando**, você escolhe entre **parar e sair** ou **deixar rodando** em segundo plano. Nesse caso, pare depois com `llama-tui stop`.

## Parâmetros disponíveis

**Campo vazio significa que o parâmetro não é passado** e o `llama-server` usa o padrão dele.

| Campo | Flag | Descrição |
|---|---|---|
| Host / interface | `--host` | `127.0.0.1` = só esta máquina; `0.0.0.0` = acessível pela rede. Padrão do llama-tui: `0.0.0.0` |
| Porta | `--port` | Porta TCP. Padrão: `8080` |
| Contexto (tokens) | `-c` | Tamanho da janela de contexto. Valores maiores usam bem mais memória. Padrão do llama-tui: `4096` |
| Camadas na GPU | `-ngl` | `99` = tudo na GPU; `0` = só CPU. Diminua se faltar memória. Padrão do llama-tui: `99` |
| Threads CPU | `-t` | Normalmente o número de núcleos físicos |
| Batch size | `-b` | Tamanho lógico do lote do prompt |
| Micro-batch | `-ub` | Tamanho físico do lote (≤ batch) |
| Slots paralelos | `-np` | Requisições simultâneas. **O contexto é dividido entre os slots** |
| Flash Attention | `-fa` | `auto` / `on` / `off`. Economiza memória e costuma acelerar |
| Tipo do KV cache (K) | `-ctk` | `f16` / `q8_0` / `q4_0` |
| Tipo do KV cache (V) | `-ctv` | `f16` / `q8_0` / `q4_0` (geralmente exige Flash Attention `on`) |
| Travar na RAM | `--mlock` | Impede que o modelo vá para o swap |
| Desativar mmap | `--no-mmap` | Carrega o arquivo inteiro na memória |
| Template Jinja | `--jinja` | Usa o chat template do modelo; necessário para tool calling. Padrão do llama-tui: ligado |
| Alias do modelo | `--alias` | Nome exibido em `/v1/models` |
| API Key | `--api-key` | Chave exigida dos clientes. **Recomendada para acesso remoto** |
| Projetor multimodal | `--mmproj` | Arquivo `mmproj-*.gguf` para modelos de visão |
| Temperatura padrão | `--temp` | `0.1`–`0.4` mais preciso; `0.6`–`0.8` equilibrado |
| Argumentos extras | — | Qualquer outra opção, como na linha de comando. Aspas são respeitadas. Ex.: `--top-k 40 --metrics` |

> **Versões do llama.cpp.** Nas versões recentes, `-fa` recebe um valor (`on|off|auto`); nas antigas é só uma flag. O llama-tui consulta o `llama-server --help` e se adapta sozinho.

Para ver todas as opções do seu `llama-server`: `llama-server --help`.

## Perfis

Um perfil é um arquivo de texto simples com o modelo e os parâmetros. Fica em:

```
~/.config/llama-tui/profiles/<nome>.conf
```

Exemplo (veja também [`examples/qwen3-8b.conf`](examples/qwen3-8b.conf)):

```ini
MODEL=/Users/voce/models/Qwen3-8B-Q4_K_M.gguf
HOST=0.0.0.0
PORT=8080
CTX=16384
NGL=99
FLASH=on
CTK=q8_0
CTV=q8_0
JINJA=1
ALIAS=qwen3-8b
APIKEY=minha-chave-secreta
EXTRA=--top-k 40 --top-p 0.9
```

- Formato `CHAVE=valor`, um por linha; linhas começando com `#` são comentários
- Valor vazio significa que o parâmetro não é passado
- Parâmetros liga/desliga (`MLOCK`, `NOMMAP`, `JINJA`): `1` = ligado, vazio = desligado
- O arquivo **não é executado** como script; só chaves conhecidas são lidas
- Os perfis são gravados com permissão `600`, porque podem conter a API key

Você pode criar perfis pela TUI, editar à mão, copiar entre máquinas ou passar o caminho de um `.conf` diretamente nos comandos.

## Linha de comando (sem TUI)

```bash
llama-tui run   <perfil>    # primeiro plano: saída na tela e no log; Ctrl+C para
llama-tui start <perfil>    # segundo plano: aguarda carregar e mostra os endereços
llama-tui stop              # para o servidor iniciado pelo llama-tui
llama-tui restart <perfil>  # para (se houver) e inicia com o perfil
llama-tui status            # está rodando? PID, modelo, endereços
llama-tui list              # lista os perfis salvos
llama-tui show  <perfil>    # mostra o comando que seria executado
llama-tui logs              # últimas linhas do log do servidor
llama-tui logs -f           # acompanha o log do servidor ao vivo
llama-tui applog            # acompanha o log do próprio programa
llama-tui help              # ajuda
```

`<perfil>` pode ser o nome de um perfil salvo ou o caminho de um arquivo `.conf`.

**Códigos de saída:** `0` ok · `1` erro · `2` já existe servidor em execução · `3` nenhum servidor em execução. Úteis para scripts:

```bash
llama-tui status >/dev/null || llama-tui start qwen3-8b
```

A TUI e a linha de comando compartilham o mesmo estado: um servidor iniciado com `start` aparece na TUI, e um servidor deixado rodando pela TUI pode ser parado com `llama-tui stop`. Apenas um servidor gerenciado roda por vez.

## Acesso remoto

1. Use **Host** `0.0.0.0`
2. Defina uma **API Key**
3. Inicie e veja os endereços na tela final ou em **Status** (ex.: `http://192.168.0.10:8080`)

Pelo navegador de outro computador, acesse `http://<ip>:<porta>` para a interface web do llama.cpp.

Como API compatível com OpenAI, use `http://<ip>:<porta>/v1`:

```bash
curl http://192.168.0.10:8080/v1/chat/completions \
  -H "Authorization: Bearer minha-chave-secreta" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-8b","messages":[{"role":"user","content":"Olá!"}]}'
```

> Se não conseguir conectar de outra máquina, verifique o firewall (no macOS: Ajustes do Sistema → Rede → Firewall) e se as duas máquinas estão na mesma rede. Para acesso pela internet, prefira uma VPN (Tailscale, WireGuard) em vez de abrir a porta no roteador.

## Logs

Todos os logs ficam em `~/.local/state/llama-tui/logs/`:

| Arquivo | Conteúdo |
|---|---|
| `llama-tui.log` | Tudo que o programa fez: data, hora, nível (`INFO`/`WARN`/`ERROR`), PID, ações, comandos executados, falhas de validação, início e parada do servidor |
| `llama-tui-AAAAMMDD-HHMMSS.log` | Logs antigos do programa. Ao passar de 5 MB, o log é **renomeado**, nunca apagado |
| `server-AAAAMMDD-HHMMSS-<modelo>.log` | Um arquivo **novo a cada execução** do servidor, começando com data, perfil, modelo e o comando exato, seguido de toda a saída do `llama-server` |

A API key nunca é gravada nos logs; aparece como `********`.

Se algo der errado, comece por:

```bash
llama-tui logs          # saída do último servidor
tail -n 50 ~/.local/state/llama-tui/logs/llama-tui.log
```

## Arquivos e pastas

| Caminho | Conteúdo |
|---|---|
| `~/.config/llama-tui/profiles/` | Perfis (`<nome>.conf`) |
| `~/.config/llama-tui/settings.conf` | Caminho do `llama-server`, pastas de busca, tempo de espera |
| `~/.config/llama-tui/last-session.conf` | Última configuração usada na TUI |
| `~/.local/state/llama-tui/logs/` | Logs |
| `~/.local/state/llama-tui/server.pid` / `server.info` | Estado do servidor em execução |

As pastas respeitam `XDG_CONFIG_HOME` e `XDG_STATE_HOME`, e podem ser trocadas com as variáveis `LLAMA_TUI_CONFIG_DIR` e `LLAMA_TUI_STATE_DIR`.

**Desinstalar:** apague o script, o link em `~/.local/bin/llama-tui` (se criou) e as pastas `~/.config/llama-tui` e `~/.local/state/llama-tui`.

## Solução de problemas

| Problema | O que fazer |
|---|---|
| `A interface TUI precisa do programa 'dialog'` | Instale o `dialog` (veja [Requisitos](#requisitos)) |
| `llama-server não encontrado` | Informe o caminho em **Configurações**, ou coloque o executável no `PATH`. Locais verificados automaticamente: `PATH`, `~/llama.cpp/build/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` |
| `A porta X já está em uso` | Escolha outra porta, ou veja quem usa: `lsof -iTCP:8080 -sTCP:LISTEN` |
| O servidor encerra durante o carregamento | Geralmente falta memória: diminua **Contexto** ou **Camadas na GPU**, ou use KV cache `q8_0`. A tela de erro mostra as últimas linhas do log |
| `error: invalid argument` no log | Seu `llama-server` não conhece algum parâmetro. Atualize o llama.cpp ou limpe o campo correspondente |
| Nenhum modelo encontrado | Adicione a pasta dos seus modelos em **Selecionar modelo → Gerenciar pastas de busca** |
| Caracteres estranhos na TUI | Use um terminal com UTF-8 (`echo $LANG` deve terminar em `UTF-8`) |
| O carregamento passou do tempo limite | O servidor continua carregando; acompanhe em **Ver saída do servidor**. Aumente o tempo em **Configurações** |

## Licença

[MIT](LICENSE)

---

Projeto independente, sem ligação oficial com o llama.cpp.
