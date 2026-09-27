# Changelog

Todas as mudanças relevantes deste projeto são registradas aqui.
O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/) e o projeto usa [Versionamento Semântico](https://semver.org/lang/pt-BR/).

## [1.1.0] - 2026-09-26

### Corrigido
- Editar um parâmetro alterava sempre "Argumentos extras" em vez do parâmetro escolhido, e o campo abria vazio (variável `i` expandida antes de ser declarada)
- Textos de ajuda apareciam embaralhados porque o `dialog` juntava as quebras de linha (agora usa `--cr-wrap`)
- Digitar números de dois dígitos (10, 11...) nos menus levava ao item errado; os itens agora usam letras
- A lista de parâmetros ficava uma linha maior que a tela em terminais de 24 linhas

### Alterado
- O IP deixou de ser parâmetro: o servidor sempre escuta em `0.0.0.0` e o IPv4 da máquina é detectado e exibido como informação. A chave `HOST` de perfis antigos é ignorada
- Tela de edição compacta (flag, descrição curta, valor atual) com botão **Ajuda** para a explicação completa
- Liga/desliga e múltipla escolha passam a ser listas simples (setas + Enter), sem precisar marcar com Espaço
- Valor inválido mantém a tela aberta com o que foi digitado, em vez de descartar
- Botões em português e tecla Esc mais rápida (250 ms)

### Adicionado
- Comando `llama-tui ip`

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
