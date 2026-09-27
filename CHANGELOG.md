# Changelog

Todas as mudanças relevantes deste projeto são registradas aqui.
O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/) e o projeto usa [Versionamento Semântico](https://semver.org/lang/pt-BR/).

## [1.0.0] - 2026-09-26

### Adicionado
- Interface TUI (`dialog`) para escolher o modelo `.gguf`, configurar parâmetros e controlar o `llama-server`
- Busca de modelos nas pastas configuradas, por filtro de nome, por navegador de arquivos ou por caminho digitado
- 18 parâmetros com ajuda detalhada, mais um campo de argumentos extras
- Validação antes de iniciar: executável, modelo, números, porta livre e avisos de segurança
- Iniciar, acompanhar ao vivo e parar o servidor sem sair do programa
- Perfis salvos em `~/.config/llama-tui/profiles/` e restauração da última sessão
- Comandos de terminal: `run`, `start`, `stop`, `restart`, `status`, `list`, `show`, `logs`, `applog`
- Log do programa com rotação por renomeação e um log novo por execução do servidor
- Detecção automática da sintaxe de `--flash-attn` conforme a versão do llama.cpp
