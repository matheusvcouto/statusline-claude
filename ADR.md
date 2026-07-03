# ADR — statusline do Claude Code

Registros de decisão de `command.sh`. Uma seção por revisão; post-mortem quando algo
quebrou. A numeração continua a do ADR do `ai-profile`
(`~/Library/Application Support/nushell/modules/ai_profiles/adr.md`), onde as revisões
8 e 9 nasceram — as revisões 1–7 de lá não tratam da statusline.

## Revisão 8 — nome de conta errado com perfis isolados

**Sintoma**: rodando um perfil isolado (`ai-profile claude run <alias>`), a statusLine
mostrava o nome da conta principal em vez do nome da conta do perfil.

**Causa**: o script lia `$HOME/.claude.json` hardcoded, ignorando que o processo já
tinha `CLAUDE_CONFIG_DIR` setado para o dir do perfil.

**Fix**: trocar por `${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json`. Puramente cosmético —
não afeta autenticação nem Keychain (o isolamento real já funcionava; só o texto exibido
estava errado).

## Revisão 9 — cache de rate-limit trava a baseline (não desce)

**Sintoma** (2026-07-02): a barra de uso de 5h ficou presa em 5% por horas enquanto o
uso real (visto em `/usage` e no app desktop) era 1–2%.

**Causa raiz**: a primeira versão do cache guardava o **maior** `used_percentage` visto
por janela, assumindo *"uso só cresce até resetar"*. Essa premissa quebra quando a
Anthropic **aumenta o limite no meio da janela**: `used_percentage` = uso ÷ limite; se o
limite sobe, o mesmo uso vira um % **menor** na mesma janela (`resets_at` idêntico) — e
o max-clamp trava no valor velho.

**Insight**: staleness (terminal ocioso mostra valor velho/baixo) e aumento-de-limite
(valor real caiu) são o **mesmo problema com sinais opostos**. Os dois só se resolvem
sabendo **qual reporte é mais recente**, não qual número é maior.

**Correção — recência-por-sessão**: o cache passou a guardar, por janela, um mapa
`sessions[<session_id>] = {pct, at, seen}`:
- `at` = epoch da última vez que o `pct` **mudou** para aquela sessão. Decide **quem é
  exibido** (a sessão com `at` mais recente venceu — foi quem falou com o servidor por
  último).
- `seen` = epoch do último reporte, mude o pct ou não. Decide **poda por TTL** (6h) —
  sessões de terminais fechados somem do arquivo sem afetar o valor exibido.

Regra por tick: se o `pct` do stdin difere do guardado para a sessão → grava e carimba
`at=agora`; se é igual → mantém `at` antigo (o terminal ocioso "envelhece" e nunca
ganha). Rollover (`resets_at` novo) zera o mapa da janela.

No mesmo edit: cache corrompido se auto-repara (antes, um JSON inválido deixava o
cache morto até deleção manual); `resets_at` em formato inesperado (ex.: ISO-8601)
degrada sem derrubar o script.

### Post-mortem do mesmo dia — regressão na primeira tentativa de correção

A primeira implementação da revisão 9 (por um agente) introduziu dois defeitos novos.
Diagnosticado, revertido para o backup pré-correção e reaplicado corretamente. Lições:

1. **Nunca ler campos tab-separados com `IFS=$'\t' read` quando algum campo pode ser
   vazio.** Tab é *IFS whitespace* no bash — campos vazios à esquerda colapsam e todos os
   valores deslizam de posição. Sintoma real: a janela 5h expirou e foi omitida do
   `@tsv`; o pct/reset da janela **semanal** vazou para dentro do segmento 5h (`5h[...]7%
   (6h49m restantes)` — matematicamente impossível para uma janela de 5 horas). Correção:
   extrair um valor por **linha** (`read` por linha preserva campos vazios), nunca
   `@tsv` + `IFS=tab` quando há campos opcionais.
2. **Não omitir a janela expirada da exibição.** O usuário quer ver o contador chegar a
   `0m` e ficar lá — é assim que ele sabe que o limite reiniciou. Omitir a janela
   expirada quebrava essa expectativa de UX (além de ter disparado o bug 1).
3. **Poda por TTL deve usar `seen` (último reporte), nunca `at` (última mudança).**
   `at` fica propositalmente parado quando o pct não muda; podar por `at` removeria
   sessões **ativas** com pct estável (a janela semanal muda devagar).

Snapshot da versão defeituosa: `backups/statusline-command.sh.bak-broken-20260702-151800`.

## Revisão 10 — dados frescos via API OAuth + countdown correndo (2026-07-02)

**Sintoma**: a barra mostrava 33% enquanto o `/status` real dizia 88%. Causa: o stdin da
statusLine só atualiza quando *a própria sessão* fala com o modelo — uma sessão ociosa
nunca fica sabendo do uso feito em outros dispositivos (claude.ai, app desktop; é conta
compartilhada). E desde o Claude Code 2.1.191 o `/usage` é client-side e não gera evento
de statusLine. Sintoma 2: o countdown ficava congelado no perfil isolado.

**Correções**:

1. **Fetch da API de usage em background** — a mesma fonte do painel `/usage`:
   `GET https://api.anthropic.com/api/oauth/usage` com `Authorization: Bearer` +
   `anthropic-beta: oauth-2025-04-20`. Resposta: `five_hour/seven_day.utilization`
   (escala 0–100) e `resets_at` ISO-8601 UTC (normalizado para epoch no fetcher, o
   merge só entende epoch). Detalhes de robustez:
   - **Nunca bloqueia o render**: subshell com `&` e fds redirecionados; o resultado
     aparece no tick seguinte.
   - **TTL 60s por conta** (mtime do `usage-api-cache.json`) + **lock por `mkdir`**
     (atômico) com reclaim após 120s — N terminais abertos geram **1 chamada/min por
     conta**, não N (comprovado no harness e num teste de 20 renders simultâneos com
     `curl` instrumentado: 1 chamada).
   - Falha de fetch faz `touch` no cache (respeita o TTL em vez de re-tentar a cada 3s)
     e **mantém** o conteúdo velho (dado velho > dado nenhum).
   - Credenciais **da conta certa**: `$CLAUDE_CONFIG_DIR/.credentials.json` se existir;
     senão Keychain `Claude Code-credentials-<sha256(CLAUDE_CONFIG_DIR)[0:8]>` (com
     `CLAUDE_CONFIG_DIR` setado) ou `Claude Code-credentials` (conta principal).
     **Nunca** cair para o item da conta principal quando um perfil está ativo — isso
     mostraria o uso de outra conta. Token expirado ⇒ pula em silêncio (**nunca**
     renovar o token aqui: rotacionar por fora pode invalidar a sessão do próprio CLI).
     Token viaja via `curl -K -` (config por stdin), nunca em argv (visível no `ps`).
   - O resultado entra no merge como pseudo-sessão **`__api__`**, com timestamp do
     **momento do fetch** (não do render) — API velha nunca ganha de sessão viva. Mesmo
     filtro jq das sessões normais ⇒ rollover e TTL idênticos.
2. **Indicador de frescor `↻`** — `↻37s`/`↻5m`/`↻2h` desde a última confirmação com o
   servidor (max entre `at` de qualquer sessão e `seen` do `__api__`; nunca o `seen` de
   sessão comum — sessão ociosa se re-reporta a cada tick sem trazer dado novo).
3. **Countdown correndo**: o `settings.json` **do perfil** não tinha
   `statusLine.refreshInterval` (só o global tinha, e `CLAUDE_CONFIG_DIR` substitui o
   diretório inteiro — perfil não herda o global). Sem ele a linha só re-renderiza em
   evento e o relógio congela. Adicionado `refreshInterval: 3` ao perfil; perfis novos
   devem incluir o campo.
4. **Limpezas**: parse do stdin em 1 chamada jq (eram 8), `LC_ALL=C` (printf `%.0f`
   aceitaria só vírgula em locale pt_BR), `now_epoch` único por render, GC de tmps
   órfãos (>10min), `ctx:0%` passou a ser exibido (o `// empty` escondia o zero).
5. **Layout**: `(1h58m)` sem "restantes", `-` entre 5h/7d/`↻` (grupo de rate-limit) e
   `|` entre os demais segmentos — formato pedido pelo usuário.

## Revisão 11 — consolidação em ~/.claude/statusline/ com git (2026-07-02)

O script morava solto em `~/.claude/statusline-command.sh`, com docs espalhadas
(um repo de projeto do usuário, ADR do ai-profile, memórias) e backups na raiz de
`~/.claude`. Consolidado tudo neste diretório, versionado com git:
`command.sh` + `CLAUDE.md` (regras/invariantes para agentes) + `ADR.md` (este arquivo) +
`tests/run.sh` (harness hermético, 31 checagens) + `backups/`. O git substitui a
convenção manual de "copiar atual → previous". O caminho antigo virou um shim
(`exec bash ~/.claude/statusline/command.sh`) para sessões abertas antes da migração;
os `settings.json` (global e perfil) apontam para o caminho novo. O backup imutável
original permanece fora: `~/pessoal/videos/statusline-command.sh.orig`
(read-only 444, não mover nem apagar).

## Revisão 12 — fetch da API só em inatividade + knob único `API_TTL` (2026-07-02)

A revisão 10 buscava da API a cada 60s sempre. Pedido do usuário: não precisa ser 1
minuto — o stdin já mantém tudo fresco enquanto há uso ativo (o `↻` volta a `0s` a cada
mudança de pct); a API só é necessária na inatividade / uso em outro dispositivo. E a
frequência deve ser uma constante óbvia de editar.

**Mudança**: `API_TTL=300` (knob único, em segundos) e a decisão de fetch movida para
**depois do merge**, com dois portões que precisam estar abertos ao mesmo tempo:

1. `mtime` do `usage-api-cache.json` mais velho que `API_TTL` (o `touch` em falha
   continua absorvendo retries);
2. `m_ls` (última confirmação com o servidor — mudança de pct de qualquer sessão OU
   `seen` do `__api__`) mais velho que `API_TTL`.

Resultado: **uso ativo = zero chamadas** (o portão 2 fica fechado pelo próprio stdin);
ocioso = 1 chamada a cada 5min por conta. O subshell de fetch virou a função
`spawn_usage_fetch()` — corpo idêntico ao da revisão 10.

Custo/risco de chamadas avaliado: o endpoint é de metadados (não consome rate limit de
modelo; é o mesmo que o app chama no `/usage`); mesmo o 1×/min da revisão 10 (~1.440
GET/dia no pior caso) não causava problema — a mudança é higiene/economia, não correção.

Testes novos no harness: T (sessão ativa ⇒ 0 chamadas, via shim de `curl` que conta
invocações) e U (ociosa ⇒ exatamente 1 chamada, resultado exibido no render seguinte,
sem re-chamada dentro do TTL). Total: 35 checagens.

## Post-mortem — push ao GitHub antes da sanitização (2026-07-02)

O repo foi publicado (privado) no GitHub **antes** da limpeza de dados pessoais: os
commits originais subiram com nome real de autor e exemplos com nome de conta/caminhos
`/Users/<usuário>`. A sanitização local foi feita re-iniciando o `.git` (identidade
neutra + arquivos limpos) e um `push --force` substituiu o `main` remoto. Lições:

1. **Sanitizar ANTES do primeiro push.** Auditoria mínima:
   `grep -rniE '<nome>|<conta>|/Users/' --exclude-dir=.git .` + conferir
   `git log --format='%an <%ae>'`.
2. **`rm -rf .git` apaga junto a config do remote** — por isso o `origin` "sumiu"
   depois da re-inicialização; foi preciso `git remote add` de novo.
3. **`push --force` não apaga os commits antigos do servidor**: eles ficam órfãos mas
   acessíveis por hash direto até o garbage collection do GitHub. Aceito porque o repo
   é privado; **se um dia for público, apagar e recriar o repo antes** (tudo existe
   local).

## Alternativa considerada — janela semanal por modelo (não exibida)

A resposta de `/api/oauth/usage` também traz limites semanais **por modelo** em
`limits[]` (`kind: "weekly_scoped"`, ex.: só Fable), além do `seven_day` geral.
Decisão: **não exibir** — a linha já é longa e o semanal geral é o que aciona o limite
na prática. Se um dia for adicionado, entra no mesmo merge como janela nova (mesmo
filtro), não como lógica paralela.
