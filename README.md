# statusline do Claude Code

Statusline pessoal, global para todas as contas/perfis. Este diretório é um **repo git
próprio** — script, docs, testes e backups juntos; o histórico de edições é o git.

```
command.sh    ← o script ativo (settings.json global e dos perfis apontam pra cá)
CLAUDE.md     ← regras e invariantes para agentes que forem editar
ADR.md        ← registros de decisão (revisões 8–11) e post-mortems
tests/run.sh  ← harness hermético (44 checagens); rodar após QUALQUER edição
backups/      ← snapshots pontuais pré-mudança (o git é o histórico principal)
```

## O que o script faz

Bash lido via stdin (JSON do Claude Code), monta uma linha:

```
USER_NAME | Fable 5 - high | my-project | main | 5h[ ######---- ]59% (4h12m) - 7d[ ##-------- ]21% (32m) - ↻4s | ctx:78%
```

As barras de rate-limit (5h/7d) combinam **duas fontes**, decididas por recência:

1. o snapshot que cada sessão recebe via stdin (só atualiza quando *aquela* sessão fala
   com o modelo), compartilhado entre terminais num cache por conta
   (`$CLAUDE_CONFIG_DIR/rate-limit-cache.json`);
2. um **fetch em background da API OAuth de usage** (a mesma fonte do painel `/usage`),
   cache em `$CLAUDE_CONFIG_DIR/usage-api-cache.json`, competindo no merge como
   pseudo-sessão `__api__`. Só dispara em **inatividade real**: se qualquer sessão
   confirmou dado novo via stdin há menos de `API_TTL` (constante única no script,
   padrão 600s), nenhuma chamada é feita — uso ativo custa zero chamadas; ocioso é
   1 chamada a cada `API_TTL` por conta (lock anti-stampede entre terminais).

O `↻` mostra há quanto tempo os números exibidos foram confirmados com o servidor.
O countdown corre porque os `settings.json` têm `statusLine.refreshInterval: 3`
(por perfil — o global não vale para perfis isolados).

## Isolamento por conta (`ai-profile`)

O script é único, mas roda isolado por conta via `CLAUDE_CONFIG_DIR` (sistema
`ai-profile` em nushell: `~/Library/Application Support/nushell/modules/ai_profiles/`).
Caches, nome de conta exibido e credenciais (Keychain
`Claude Code-credentials-<sha256(config_dir)[0:8]>`) são todos por conta — nunca cruzam.
Detalhes e invariantes: `CLAUDE.md` e `ADR.md` aqui; revisões 8–10 também citadas no
`adr.md` do ai-profile.

## Testes

```sh
bash tests/run.sh
```

Hermético: cada cenário usa um `CLAUDE_CONFIG_DIR` temporário — não toca cache real nem
faz chamada de rede (os dirs de teste não têm credencial). Cobre: crescimento, baseline
descendo (aumento de limite), recência ativa×ociosa, rollover (stdin e API), cache
corrompido (dos dois caches), ISO-8601, isolamento entre contas, janela expirada `(0m)`,
poda TTL, schemas legados, sem `session_id`, sem `rate_limits`, API×sessão (fresca e
velha), indicador `↻`, `ctx:0%`, tolerância de `resets_at` entre fontes (API ±1s vs.
cache e `resets_at` nulo em janela de uso 0).

## FAQ — perguntas já respondidas (com prova nos testes)

**Por que a barra ficava desatualizada, se o `/usage` mostrava certo?**
O stdin da statusLine só atualiza quando *aquela* sessão fala com o modelo. Sessão
parada nunca fica sabendo do uso feito em outro terminal ou dispositivo (claude.ai,
app desktop). E desde o Claude Code 2.1.191 o `/usage` é client-side — não gera evento
de statusLine. Por isso o fetch da API existe (revisão 10).

**Com 10 terminais abertos, são 10 chamadas à API?**
Não — no máximo 1 por `API_TTL` por conta. O cache é por conta e o lock (`mkdir`
atômico) faz os concorrentes desistirem e lerem o resultado do vencedor. Comprovado:
20 renders simultâneos com `curl` instrumentado = 1 chamada (e testes T/U).

**Chamar `api.anthropic.com/api/oauth/usage` direto pode dar problema de rate limit?**
Não. É endpoint de *metadados* de uso — não passa pelo rate limit dos modelos e não
consome nada do plano; é a mesma chamada que o app faz ao abrir `/usage`. E desde a
revisão 12 só é feita em inatividade real (uso ativo = zero chamadas).

**Se alguém manda mensagem num terminal do perfil, os outros parados atualizam?**
Sim, sem chamada de API: o ativo grava o dado fresco do stdin no cache compartilhado
da conta; os parados releem a cada tick (3s) e a recência faz o valor dele vencer —
o `↻` volta a `0s` em todos. Isso também fecha o portão da API (a confirmação via
stdin conta). Testes B e M.

**E se ficar tudo parado (ou o uso vier de outro dispositivo)?**
Aí entra a API: 1 chamada a cada `API_TTL` (padrão 10min) por conta; todos os terminais
da conta atualizam no tick seguinte ao fetch. Testes S e U.

**Atualiza entre contas/perfis diferentes?**
Não, de propósito: cada perfil (`CLAUDE_CONFIG_DIR`) tem caches e credencial próprios —
nunca cruzam (senão a barra de um perfil mostraria o uso de outra conta). Teste G.

**Race conditions conhecidas (e por que são aceitas):**
1. Dois terminais gravando o cache de sessões no mesmo instante → um pode perder a
   escrita do outro **por um tick**; se auto-corrige em 3s porque cada sessão se
   re-reporta a cada render. Nenhum valor errado chega à tela.
2. Lock de fetch após sleep do macOS → no pior caso uma chamada extra à API. Escrita
   continua atômica (`tmp` + `mv`).

**Como mudar a frequência da API?** `API_TTL` (segundos), constante única no topo do
bloco de fetch em `command.sh`.

**O countdown não corre / a barra congela quando ocioso?**
Falta `statusLine.refreshInterval` no `settings.json` **do perfil** (o global não vale
para perfis isolados). Exige reiniciar o Claude Code após adicionar.

## Referências

- ADR do sistema de perfis: `~/Library/Application Support/nushell/modules/ai_profiles/adr.md`
- Memórias entre sessões (projetos do Claude Code): `~/.claude/projects/<projeto>/memory/statusline-rate-limit-shared-cache.md`
  e `~/.claude/projects/<projeto>/memory/feedback_statusline.md`
- Backup imutável do original (fora daqui, read-only 444, não mover/apagar):
  `~/pessoal/videos/statusline-command.sh.orig`
- Shim de compatibilidade: `~/.claude/statusline-command.sh` (caminho antigo) só faz
  `exec` deste `command.sh`, para sessões abertas antes da migração.
