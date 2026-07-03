#!/bin/bash
# Hermetic harness for ../command.sh (v4).
# Every scenario uses its own CLAUDE_CONFIG_DIR under $BASE — the real
# ~/.claude cache is never touched, and the background fetcher finds no
# credentials for the test dirs (per-dir Keychain hash) so it exits silently.
set -u
SL="$(cd "$(dirname "$0")/.." && pwd)/command.sh"
BASE="$(cd "$(dirname "$0")" && pwd)/work.$$"
mkdir -p "$BASE"
PASS=0; FAIL=0
now=$(date +%s)
R1=$(( now + 7110 ))    # ~1h58m left (30s slack against tick drift)
R2=$(( now + 13710 ))   # ~3h48m left

newcfg() { local d="$BASE/$1"; mkdir -p "$d"
  printf '{"oauthAccount":{"displayName":"%s"}}' "${2:-Test}" > "$d/.claude.json"
  printf '%s' "$d"; }

# stdin_json sid five_pct five_reset week_pct week_reset [ctx]
stdin_json() {
  local sid="$1" fp="$2" fr="$3" wp="$4" wr="$5" ctx="${6:-85.2}" rl=""
  [ -n "$fp$wp" ] && rl=',"rate_limits":{"five_hour":{"used_percentage":'"$fp"',"resets_at":'"$fr"'},"seven_day":{"used_percentage":'"$wp"',"resets_at":'"$wr"'}}'
  local sidf=""; [ -n "$sid" ] && sidf='"session_id":"'"$sid"'",'
  printf '{%s"model":{"display_name":"Fable 5"},"effort":{"level":"high"},"workspace":{"current_dir":"/tmp"},"context_window":{"remaining_percentage":%s}%s}' \
    "$sidf" "$ctx" "$rl"
}

render() { printf '%s' "$2" | CLAUDE_CONFIG_DIR="$1" bash "$SL" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g'; }

check() { # name haystack ERE
  if printf '%s' "$2" | grep -qE "$3"; then PASS=$((PASS+1)); echo "PASS: $1"
  else FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "   out: $2"; echo "   exp: $3"; fi }

check_not() {
  if printf '%s' "$2" | grep -qE "$3"; then FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "   out: $2"; echo "   not: $3"
  else PASS=$((PASS+1)); echo "PASS: $1"; fi }

# --- A: growth — same session's pct rises, display follows -------------------
c=$(newcfg A)
render "$c" "$(stdin_json s1 33 "$R1" 10 "$R2")" >/dev/null
out=$(render "$c" "$(stdin_json s1 45 "$R1" 10 "$R2")")
check "A growth 33->45" "$out" '5h\[[^]]*\]45% \(1h5[78]m\)'

# --- B: active session beats idle one ----------------------------------------
c=$(newcfg B)
render "$c" "$(stdin_json idle 50 "$R1" 10 "$R2")" >/dev/null
jq --argjson old $(( now - 3600 )) '.five.sessions.idle.at = $old | .week.sessions.idle.at = $old' \
  "$c/rate-limit-cache.json" > "$c/t" && mv "$c/t" "$c/rate-limit-cache.json"
out=$(render "$c" "$(stdin_json live 40 "$R1" 12 "$R2")")
check "B live 40 beats idle 50" "$out" '5h\[[^]]*\]40%'

# --- C: baseline DESCENDS on limit increase (same window, pct drops) ---------
c=$(newcfg C)
render "$c" "$(stdin_json s1 5 "$R1" 10 "$R2")" >/dev/null
out=$(render "$c" "$(stdin_json s1 2 "$R1" 10 "$R2")")
check "C baseline 5->2" "$out" '5h\[[^]]*\]2%'

# --- D: rollover — newer window clears old sessions --------------------------
c=$(newcfg D)
render "$c" "$(stdin_json s1 90 "$R1" 50 "$R2")" >/dev/null
out=$(render "$c" "$(stdin_json s2 1 $(( R1 + 18000 )) 50 "$R2")")
check "D rollover shows 1%" "$out" '5h\[[^]]*\]1%'
check "D old session cleared" "$(jq -c '.five.sessions' "$c/rate-limit-cache.json")" '^\{"s2"'

# --- E: corrupt cache self-heals ----------------------------------------------
c=$(newcfg E)
printf 'garbage{{{' > "$c/rate-limit-cache.json"
out=$(render "$c" "$(stdin_json s1 33 "$R1" 10 "$R2")")
check "E corrupt cache still renders" "$out" '5h\[[^]]*\]33%'
check "E cache is valid json again" "$(jq -c '.five.sessions.s1.pct' "$c/rate-limit-cache.json" 2>&1)" '^33$'

# --- F: ISO-8601 resets_at degrades (bar yes, countdown no) -------------------
c=$(newcfg F)
out=$(render "$c" "$(stdin_json s1 33 '"2026-07-03T04:40:00Z"' 10 "$R2")")
check "F ISO shows bar without countdown" "$out" '5h\[[^]]*\]33% - 7d'

# --- G: per-account isolation (two CLAUDE_CONFIG_DIRs) ------------------------
c1=$(newcfg G1 Ana); c2=$(newcfg G2 Bia)
o1=$(render "$c1" "$(stdin_json sA 20 "$R1" 5 "$R2")")
o2=$(render "$c2" "$(stdin_json sB 70 "$R1" 60 "$R2")")
check "G1 Ana sees 20" "$o1" '^Ana \|.*\]20%'
check "G2 Bia sees 70" "$o2" '^Bia \|.*\]70%'
check "G1 cache untouched by G2" "$(jq -c '.five.sessions.sA.pct' "$c1/rate-limit-cache.json")" '^20$'

# --- H: expired 5h window shown as (0m), no field shift -----------------------
c=$(newcfg H)
out=$(render "$c" "$(stdin_json s1 33 $(( now - 100 )) 10 "$R2")")
check "H expired 5h shows (0m)" "$out" '5h\[[^]]*\]33% \(0m\) - 7d\[[^]]*\]10% \(3h4[78]m\)'

# --- I: TTL prunes dead session, keeps live one with stable pct ---------------
c=$(newcfg I)
mkdir -p "$c"
printf '%s' '{"five":{"resets_at":"'"$R1"'","sessions":{"dead":{"pct":60,"at":'$(( now - 30000 ))',"seen":'$(( now - 30000 ))'},"live":{"pct":8,"at":'$(( now - 7000 ))',"seen":'$(( now - 100 ))'}}},"week":{"resets_at":"'"$R2"'","sessions":{"live":{"pct":9,"at":'$(( now - 7000 ))',"seen":'$(( now - 100 ))'}}}}' > "$c/rate-limit-cache.json"
out=$(render "$c" "$(stdin_json live 8 "$R1" 9 "$R2")")
check "I live stable pct kept" "$out" '5h\[[^]]*\]8%'
check "I dead session pruned" "$(jq -c '.five.sessions | keys' "$c/rate-limit-cache.json")" '^\["live"\]$'

# --- J: legacy v1 schema self-heals -------------------------------------------
c=$(newcfg J)
printf '%s' '{"five":{"pct":5,"resets_at":"'"$R1"'"},"week":{"pct":9,"resets_at":"'"$R2"'"}}' > "$c/rate-limit-cache.json"
out=$(render "$c" "$(stdin_json s1 33 "$R1" 10 "$R2")")
check "J legacy cache upgraded" "$out" '5h\[[^]]*\]33%'

# --- K: missing session_id falls back to "_" ----------------------------------
c=$(newcfg K)
out=$(render "$c" "$(stdin_json "" 33 "$R1" 10 "$R2")")
check "K renders without session_id" "$out" '5h\[[^]]*\]33%'
check "K cache keyed by _" "$(jq -c '.five.sessions | keys' "$c/rate-limit-cache.json")" '^\["_"\]$'

# --- L: no rate_limits at all — graceful, ctx still shown ---------------------
c=$(newcfg L)
out=$(render "$c" "$(stdin_json s1 "" "" "" "")")
check_not "L no 5h segment" "$out" '5h\['
check "L ctx still shown" "$out" 'ctx:85%'

# --- M: fresh API beats idle session (the /usage-stale fix) -------------------
c=$(newcfg M)
printf '%s' '{"five":{"resets_at":"'"$R1"'","sessions":{"s1":{"pct":20,"at":'$(( now - 4000 ))',"seen":'$(( now - 10 ))'}}},"week":{"resets_at":"'"$R2"'","sessions":{"s1":{"pct":10,"at":'$(( now - 4000 ))',"seen":'$(( now - 10 ))'}}}}' > "$c/rate-limit-cache.json"
printf '%s' '{"five":{"pct":55,"resets_at":'"$R1"'},"week":{"pct":16,"resets_at":'"$R2"'},"fetched_at":'$(( now - 30 ))'}' > "$c/usage-api-cache.json"
out=$(render "$c" "$(stdin_json s1 20 "$R1" 10 "$R2")")
check "M api 55 beats idle 20" "$out" '5h\[[^]]*\]55%'
check "M api weekly 16" "$out" '7d\[[^]]*\]16%'

# --- N: live session change beats stale API -----------------------------------
c=$(newcfg N)
printf '%s' '{"five":{"pct":55,"resets_at":'"$R1"'},"week":{"pct":16,"resets_at":'"$R2"'},"fetched_at":'$(( now - 3000 ))'}' > "$c/usage-api-cache.json"
render "$c" "$(stdin_json s1 20 "$R1" 10 "$R2")" >/dev/null
out=$(render "$c" "$(stdin_json s1 22 "$R1" 10 "$R2")")
check "N fresh session 22 beats stale api 55" "$out" '5h\[[^]]*\]22%'

# --- O: API-side rollover clears old sessions ---------------------------------
c=$(newcfg O)
printf '%s' '{"five":{"resets_at":"'"$R1"'","sessions":{"s1":{"pct":90,"at":'$(( now - 50 ))',"seen":'$(( now - 50 ))'}}},"week":{"resets_at":"'"$R2"'","sessions":{"s1":{"pct":50,"at":'$(( now - 50 ))',"seen":'$(( now - 50 ))'}}}}' > "$c/rate-limit-cache.json"
printf '%s' '{"five":{"pct":3,"resets_at":'$(( R1 + 18000 ))'},"week":{"pct":50,"resets_at":'"$R2"'},"fetched_at":'"$now"'}' > "$c/usage-api-cache.json"
out=$(render "$c" "$(stdin_json s1 90 "$R1" 50 "$R2")")
check "O api rollover shows 3%" "$out" '5h\[[^]]*\]3%'
check "O only __api__ in new window" "$(jq -c '.five.sessions | keys' "$c/rate-limit-cache.json")" '^\["__api__"\]$'

# --- P: freshness indicator reflects last server confirmation -----------------
c=$(newcfg P)
printf '%s' '{"five":{"resets_at":"'"$R1"'","sessions":{"s1":{"pct":20,"at":'$(( now - 4000 ))',"seen":'$(( now - 10 ))'}}},"week":{"resets_at":"'"$R2"'","sessions":{"s1":{"pct":10,"at":'$(( now - 4000 ))',"seen":'$(( now - 10 ))'}}}}' > "$c/rate-limit-cache.json"
printf '%s' '{"five":{"pct":20,"resets_at":'"$R1"'},"week":{"pct":10,"resets_at":'"$R2"'},"fetched_at":'$(( now - 130 ))'}' > "$c/usage-api-cache.json"
out=$(render "$c" "$(stdin_json s1 20 "$R1" 10 "$R2")")
check "P freshness ~2m from api fetch" "$out" '↻2m \|'

# --- Q: corrupt API cache ignored gracefully ----------------------------------
c=$(newcfg Q)
printf 'not json' > "$c/usage-api-cache.json"
out=$(render "$c" "$(stdin_json s1 33 "$R1" 10 "$R2")")
check "Q corrupt api cache ignored" "$out" '5h\[[^]]*\]33%'
check "Q fresh from own change" "$out" '↻[0-9]s'

# --- R: ctx 0% is displayed (was hidden by // empty before) -------------------
c=$(newcfg R)
out=$(render "$c" "$(stdin_json s1 33 "$R1" 10 "$R2" 0)")
check "R ctx:0% shown" "$out" 'ctx:0%'

# --- T/U: fetch economy — API is only called on real inactivity ---------------
# Instrumented curl shim + fake creds file: counts actual calls, no network.
mkdir -p "$BASE/bin"
cat > "$BASE/bin/curl" <<'SHIM'
#!/bin/bash
echo "call" >> "$CURL_LOG"
cat >/dev/null
printf '{"five_hour":{"utilization":42.0,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":17.0,"resets_at":"2030-01-02T00:00:00+00:00"}}'
SHIM
chmod +x "$BASE/bin/curl"
render_counted() { # cfg json log
  printf '%s' "$2" | CLAUDE_CONFIG_DIR="$1" PATH="$BASE/bin:$PATH" CURL_LOG="$3" \
    bash "$SL" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g'; }

# T: ACTIVE session (this tick's pct change stamps at=now) -> zero API calls,
# even with no api cache at all.
c=$(newcfg T)
printf '%s' '{"claudeAiOauth":{"accessToken":"fake","expiresAt":9999999999999}}' > "$c/.credentials.json"
render_counted "$c" "$(stdin_json s1 33 "$R1" 10 "$R2")" "$BASE/T.log" >/dev/null
render_counted "$c" "$(stdin_json s1 34 "$R1" 10 "$R2")" "$BASE/T.log" >/dev/null
sleep 1
check "T active use makes 0 api calls" "calls=$( { wc -l < "$BASE/T.log" || echo 0; } 2>/dev/null | tr -d ' ')" '^calls=0$'

# U: IDLE (last pct change > API_TTL ago, no api cache) -> exactly 1 call;
# result is displayed on the next render; no re-call within the TTL.
c=$(newcfg U)
printf '%s' '{"claudeAiOauth":{"accessToken":"fake","expiresAt":9999999999999}}' > "$c/.credentials.json"
printf '%s' '{"five":{"resets_at":"'"$R1"'","sessions":{"s1":{"pct":33,"at":'$(( now - 400 ))',"seen":'$(( now - 5 ))'}}},"week":{"resets_at":"'"$R2"'","sessions":{"s1":{"pct":10,"at":'$(( now - 400 ))',"seen":'$(( now - 5 ))'}}}}' > "$c/rate-limit-cache.json"
render_counted "$c" "$(stdin_json s1 33 "$R1" 10 "$R2")" "$BASE/U.log" >/dev/null
sleep 1
check "U idle triggers exactly 1 api call" "calls=$(wc -l < "$BASE/U.log" | tr -d ' ')" '^calls=1$'
out=$(render_counted "$c" "$(stdin_json s1 33 "$R1" 10 "$R2")" "$BASE/U.log")
check "U next render shows fetched 42%" "$out" '5h\[[^]]*\]42%'
sleep 1
check "U no second call within TTL" "calls=$(wc -l < "$BASE/U.log" | tr -d ' ')" '^calls=1$'

# --- S: API-only — bars render even when stdin has no rate_limits -------------
c=$(newcfg S)
printf '%s' '{"five":{"pct":55,"resets_at":'"$R1"'},"week":{"pct":16,"resets_at":'"$R2"'},"fetched_at":'"$now"'}' > "$c/usage-api-cache.json"
out=$(render "$c" "$(stdin_json s1 "" "" "" "")")
check "S 5h bar from api" "$out" '5h\[[^]]*\]55% \(1h5[78]m\)'
check "S 7d bar from api" "$out" '7d\[[^]]*\]16%'
check "S freshness shown" "$out" '↻[0-9]+s'

echo
echo "== $PASS passed, $FAIL failed =="
# give stray background fetchers a moment, then clean up
sleep 1
rm -rf "$BASE"
exit $(( FAIL > 0 ))
