# Contribuindo

Sugestões e correções são bem-vindas! Abra uma *issue* descrevendo o problema ou a ideia antes de enviar mudanças grandes.

## Ao relatar um problema

Inclua:
- Sistema operacional e versão (`uname -a`)
- Versão do bash (`bash --version`) e do dialog (`dialog --version`)
- Versão do llama.cpp (`llama-server --version`)
- As linhas relevantes de `~/.local/state/llama-tui/logs/llama-tui.log` e do log do servidor (`llama-tui logs`)

Revise os logs antes de colar e remova caminhos ou informações pessoais que não queira expor.

## Ao alterar o código

- Mantenha compatibilidade com **bash 3.2** (o do macOS): nada de arrays associativos (`declare -A`), `mapfile`, `${var,,}` ou `local -n`
- Rode `bash -n llama-tui.sh` e, se possível, [`shellcheck`](https://www.shellcheck.net/) `llama-tui.sh`
- Teste no macOS e no Linux quando puder
- Novos parâmetros do servidor são declarados com `defparam` (chave, tipo, flag, rótulo, ajuda curta, documentação); a TUI, a validação, os perfis e o comando se ajustam sozinhos
- Registre a mudança no [CHANGELOG.md](CHANGELOG.md)
