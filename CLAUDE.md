# Instruções para agentes — statusline do Claude Code

O script ativo é **`command.sh`** (referenciado em `~/.claude/settings.json` e no
`settings.json` de cada perfil do `ai-profile` como
`bash ~/.claude/statusline/command.sh`). Este diretório é um repo git próprio:
toda mudança deve virar commit aqui.

## Regras de edição

- **Edição cirúrgica** (`Edit`, nunca reescrever o arquivo inteiro com `Write`).
  O script foi construído incrementalmente; uma reescrita completa arrisca perder
  comportamento sem ficar óbvio no diff. Regra vem de feedback explícito do usuário.
- **Rodar `tests/run.sh` depois de qualquer edição** — todos os cenários devem passar.
  Cenário novo de bug corrigido entra no harness junto com a correção.
- Registrar decisões e post-mortems no `ADR.md`, e commitar script + docs juntos.
- Sem output em maiúsculas forçadas.
- Backup pontual antes de mudança grande: cópia em `backups/` (além do git).
- **Nenhum dado pessoal em docs, testes ou commits deste repo**: nada de nome real de
  conta/usuário, e-mail, caminho absoluto `/Users/<usuário>` ou ID real de perfil.
  Usar placeholders (`USER_NAME`, `<alias>`, `<projeto>`, `~`) em exemplos. A identidade
  de autor do git é local e neutra (`USER_NAME <user@localhost>`) — não sobrescrever
  com a identidade global.

## Invariantes (não quebrar)

- `CACHE_FILE`, `API_CACHE` e a leitura de `account_name` ancorados em
  `CLAUDE_CONFIG_DIR` — **nunca hardcode `~/.claude`**. É isso que dá o isolamento
  por conta do `ai-profile`.
- **Não reverter para "maior % vence"** — trava a baseline quando a Anthropic aumenta
  o limite no meio da janela (ADR revisão 9).
- **Não omitir janela expirada** — o contador chegando a `0m` (e ficando lá) é como o
  usuário sabe que o limite reiniciou.
- **Poda de sessão por `seen`, nunca por `at`** — `at` fica propositalmente velho
  quando o pct não muda; podar por `at` removeria sessões ativas de pct estável.
- **Nunca extrair campos com `@tsv` + `IFS=$'\t' read`** quando algum campo pode ser
  vazio — tab é IFS-whitespace, campos vazios colapsam e os valores deslizam de
  posição. Sempre um valor por LINHA.
- **Fetch da API de usage**: sempre em background (nunca no caminho do render); nunca
  imprimir/logar o token; nunca renová-lo (rotacionar por fora pode invalidar a sessão
  do CLI); token via `curl -K -` (stdin), nunca em argv; **nunca** usar a credencial da
  conta principal como fallback quando `CLAUDE_CONFIG_DIR` está setado.
- **`__api__` carimbado com `fetched_at`**, nunca com o `now` do render — senão um
  cache velho de API ganharia de sessão viva para sempre.
