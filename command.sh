#!/bin/bash
# Claude Code status line - "Completo"
# Layout (keep this comment AND the README example in sync with any display change):
#   account | model - effort | dir | git-branch |
#   5h[bar]pct%(reset-countdown) - 7d[bar]pct%(reset-countdown) - ↻freshness | ctx:pct%
# Example:
#   USER_NAME | Fable 5 - high | my-project | main | 5h[ ######---- ]59% (4h12m) - 7d[ ##-------- ]21% (32m) - ↻4s | ctx:78%
# Optional segments (account, effort, branch, bars, ↻, ctx) are simply omitted
# when their data is missing; separators collapse accordingly.

input=$(cat)

# C locale so printf %.0f always accepts "33.0" (a pt_BR LC_NUMERIC would
# expect a comma and error out).
export LC_ALL=C
now_epoch=$(date +%s)

# Single-pass stdin parse (was 8 separate jq calls). One value per LINE —
# never @tsv + IFS=tab, empty fields would collapse and shift (see below).
{ read -r model; read -r dir; read -r effort; read -r remaining
  read -r five_pct; read -r five_reset; read -r week_pct; read -r week_reset
  read -r session_id; } < <(printf '%s' "$input" | jq -r '
    [ (.model.display_name // ""), (.workspace.current_dir // ""),
      (.effort.level // ""), (.context_window.remaining_percentage // ""),
      (.rate_limits.five_hour.used_percentage // ""),
      (.rate_limits.five_hour.resets_at // ""),
      (.rate_limits.seven_day.used_percentage // ""),
      (.rate_limits.seven_day.resets_at // ""),
      (.session_id // "") ][] | tostring')
dir_name=$(basename "$dir")

# Git branch (skip optional locks to avoid contention)
branch=""
if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$dir" --no-optional-locks branch --show-current 2>/dev/null)
fi

# Claude account display name (not exposed via stdin; read directly from
# the global config file)
account_name=$(jq -r '.oauthAccount.displayName // empty' "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" 2>/dev/null)

# Build a human-readable "XhYm" countdown to reset
fmt_remaining_time() {
  local reset_epoch="$1"
  [ -z "$reset_epoch" ] && return
  local int="${reset_epoch%.*}"
  # Non-numeric resets_at (e.g. ISO-8601): omit the countdown instead of
  # crashing on bash arithmetic.
  case "$int" in ''|*[!0-9]*) return ;; esac
  local secs_left d h m
  secs_left=$(( int - now_epoch ))
  [ "$secs_left" -lt 0 ] && secs_left=0
  d=$(( secs_left / 86400 ))
  h=$(( (secs_left % 86400) / 3600 ))
  m=$(( (secs_left % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then
    printf "%dd%dh" "$d" "$h"
  elif [ "$h" -gt 0 ]; then
    printf "%dh%dm" "$h" "$m"
  else
    printf "%dm" "$m"
  fi
}
# Countdowns are computed *after* the shared-cache merge below, so they reflect
# the converged window rather than this session's possibly-stale snapshot.

# --- Shared rate-limit cache --------------------------------------------------
# Each Claude Code session only knows the rate-limit snapshot it last received.
# Two failure modes share one root cause: an idle terminal holds a stale (lower)
# value, and a mid-window limit INCREASE by Anthropic makes used_percentage
# (= usage / limit) DROP within the same window. "Highest wins" fixes the first
# and breaks the second (the baseline never descends). So we track, per session,
# the pct and when it last CHANGED, and display the window value from the
# session whose report changed most recently — the one that most recently heard
# from the server. Idle sessions age out naturally; a limit increase is a
# change, so it wins and the baseline descends.
#
# Schema (per-account file, anchored on CLAUDE_CONFIG_DIR — never hardcode):
#  {"five":{"resets_at":"<epoch>","sessions":{"<sid>":{"pct":N,"at":E,"seen":E}}},
#   "week":{...}}
# at = epoch of the last pct CHANGE (decides the display winner); seen = last
# report (TTL pruning only, so an active session with an unchanged pct is never
# pruned while a closed terminal eventually is).
CACHE_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/rate-limit-cache.json"
[ -z "$session_id" ] && session_id="_"
TTL_SECS=21600  # prune sessions not seen for 6h (closed terminals)

# --- Fresh usage straight from the OAuth API (same source as /usage) -----------
# stdin rate_limits only refresh when THIS session talks to the model, so an
# idle terminal goes stale — and usage from other devices (claude.ai, desktop)
# never reaches stdin at all. Fetch the account's real usage in the BACKGROUND
# (the render below is never blocked) and let it compete in the recency merge
# as pseudo-session "__api__".
API_CACHE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/usage-api-cache.json"
# Single knob for API call frequency (seconds). The fetch only fires when
# NOBODY confirmed fresh data for this long — neither an active session via
# stdin (a pct change counts as server contact) nor a previous fetch. So
# active use costs ZERO API calls; the API only covers idleness and usage
# made on other devices. The decision itself happens AFTER the merge below.
API_TTL=600

spawn_usage_fetch() {
  (
    exec </dev/null >/dev/null 2>&1
    lock="$API_CACHE.lock"
    # Reclaim a stale lock (crashed fetcher) after 120s.
    lock_m=$(stat -f %m "$lock" 2>/dev/null || echo 0)
    [ "$lock_m" -gt 0 ] && [ $(( now_epoch - lock_m )) -gt 120 ] && rmdir "$lock" 2>/dev/null
    mkdir "$lock" 2>/dev/null || exit 0  # another session is already fetching
    trap 'rmdir "$lock" 2>/dev/null' EXIT
    # On any failure, bump the cache mtime so the next ticks respect the TTL
    # instead of retrying every 3s; old content is kept (stale beats nothing).
    fail() { touch "$API_CACHE" 2>/dev/null; exit 0; }
    # Credentials for THIS account only. With CLAUDE_CONFIG_DIR set, Claude
    # Code stores them under a per-profile Keychain item suffixed with
    # sha256(config dir)[0:8]. NEVER fall back to the main account's item —
    # that would render another account's usage in this profile's bar.
    creds=""
    if [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ]; then
      creds=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" 2>/dev/null)
    else
      svc="Claude Code-credentials"
      [ -n "${CLAUDE_CONFIG_DIR:-}" ] && svc="$svc-$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)"
      creds=$(security find-generic-password -s "$svc" -w 2>/dev/null)
    fi
    [ -z "$creds" ] && fail
    tok=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    exp=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.expiresAt // empty' 2>/dev/null)
    [ -z "$tok" ] && fail
    # Expired token: skip quietly and NEVER refresh it here — rotating the
    # token under Claude Code's feet could invalidate the CLI's own session.
    case "$exp" in ''|*[!0-9]*) ;; *) [ "$exp" -le $(( now_epoch * 1000 )) ] && fail ;; esac
    # Token travels via curl's stdin config (-K -), never argv (visible in ps).
    resp=$(printf 'header = "Authorization: Bearer %s"\nheader = "anthropic-beta: oauth-2025-04-20"\n' "$tok" \
      | curl -sS -m 3 -K - "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
    out=$(printf '%s' "$resp" | jq -c --argjson now "$now_epoch" '
      # utilization is 0-100; resets_at is ISO-8601 UTC -> normalize to epoch
      # here so the merge (which only understands epochs) stays untouched.
      def iso2ep($s): try (($s|tostring) | sub("\\.[0-9]+";"") | sub("\\+00:00$";"Z") | fromdateiso8601) catch null;
      {five: {pct: (.five_hour.utilization // null), resets_at: iso2ep(.five_hour.resets_at)},
       week: {pct: (.seven_day.utilization // null), resets_at: iso2ep(.seven_day.resets_at)},
       fetched_at: $now}
      | if (.five.pct != null) or (.week.pct != null) then . else empty end' 2>/dev/null)
    [ -z "$out" ] && fail
    tmp="$API_CACHE.tmp.$$"
    { printf '%s' "$out" >"$tmp" 2>/dev/null && mv -f "$tmp" "$API_CACHE" 2>/dev/null; } || rm -f "$tmp"
  ) &
}

# Last successful fetch (possibly just renewed by another session's tick).
{ read -r api_fp; read -r api_fr; read -r api_wp; read -r api_wr; read -r api_at; } < <(
  jq -r '[ (.five.pct // ""), (.five.resets_at // ""),
           (.week.pct // ""), (.week.resets_at // ""),
           (.fetched_at // "") ][] | tostring' "$API_CACHE" 2>/dev/null)
case "$api_at" in ''|*[!0-9]*) api_fp=""; api_wp="" ;; esac
# -------------------------------------------------------------------------------

# Corrupt/unreadable/legacy cache degrades to {} and is rebuilt from stdin on
# the next ticks (self-heals) instead of silently disabling the cache forever.
cache_raw=$(cat "$CACHE_FILE" 2>/dev/null)
if ! printf '%s' "$cache_raw" | jq -e 'type=="object"' >/dev/null 2>&1; then
  cache_raw='{}'
fi

# Two sources report resets_at for the SAME window but round the instant
# differently (stdin rounds; the API's iso2ep truncates the fraction), so they
# can disagree by ~1s. With strict >/>= a -1s API reading looked like an OLD
# window and was dropped (freshness froze, ↻ grew unbounded when idle); a +1s
# reading looked like a NEW window and triggered a false rollover that wiped
# live sessions. A tolerance band, far below the smallest real window
# (5h = 18000s), absorbs the rounding without ever masking a genuine rollover.
RESETS_SLACK=120

# One filter, applied twice: once for this session's stdin snapshot, once for
# the API fetch as pseudo-session "__api__" (timestamped by WHEN IT WAS FETCHED,
# not now, so a stale API cache never outranks a live session). Same filter =
# rollover and TTL rules stay identical for both.
merge_filter='
  # "" / missing / non-numeric (e.g. ISO-8601) -> null, never a jq error.
  def tonum($x): (try (($x|tostring)|tonumber) catch null);
  def merge($w; $pct; $reset):
      ($w // {}) as $w
    | tonum($reset) as $sr | tonum($w.resets_at) as $cr
    # Rollover: a MEANINGFULLY newer window (beyond the cross-source rounding
    # slack) clears the per-session map so old sessions cannot leak their pct
    # across the reset boundary. The +$slack guard stops a +1s API reading from
    # faking a rollover and wiping live stdin sessions.
    | (if ($sr != null) and (($cr == null) or ($sr > ($cr + $slack)))
         then {resets_at: $reset, sessions: {}}
         else {resets_at: $w.resets_at, sessions: ($w.sessions // {})}
       end) as $base
    | tonum($pct) as $p | tonum($base.resets_at) as $br
    # Record this session only when it reports the current window. The -$slack
    # tolerance keeps a -1s API reading from being mistaken for an old window.
    # A null resets_at with a real pct (the API sends resets_at=null for a
    # 0-usage window) is treated as the CURRENT window so that fresh reading can
    # still display and refresh ↻. Stamp "at" only when the pct actually changed:
    # an unchanged pct keeps its old stamp, which lets idle terminals age out.
    | (if ($p != null) and ($br != null) and (($sr == null) or ($sr >= ($br - $slack)))
         then ($base.sessions[$sid] // null) as $prev
           | $base.sessions + {($sid): {
               pct: $p,
               at: (if ($prev == null) or ($prev.pct != $p) then $now else $prev.at end),
               seen: $now}}
         else $base.sessions
       end) as $ns
    | {resets_at: $base.resets_at,
       sessions: ($ns | with_entries(select(((.value.seen // .value.at) // 0) > ($now - $ttl))))};
  {five: merge(.five; $fp; $fr), week: merge(.week; $wp; $wr)}'

merged=$(printf '%s' "$cache_raw" | jq \
  --arg sid "$session_id" \
  --argjson now "$now_epoch" \
  --argjson ttl "$TTL_SECS" \
  --argjson slack "$RESETS_SLACK" \
  --arg fp "$five_pct" --arg fr "$five_reset" \
  --arg wp "$week_pct" --arg wr "$week_reset" "$merge_filter" 2>/dev/null)

if [ -n "$merged" ] && { [ -n "$api_fp" ] || [ -n "$api_wp" ]; }; then
  api_merged=$(printf '%s' "$merged" | jq \
    --arg sid "__api__" \
    --argjson now "$api_at" \
    --argjson ttl "$TTL_SECS" \
    --argjson slack "$RESETS_SLACK" \
    --arg fp "$api_fp" --arg fr "$api_fr" \
    --arg wp "$api_wp" --arg wr "$api_wr" "$merge_filter" 2>/dev/null)
  [ -n "$api_merged" ] && merged="$api_merged"
fi

fresh_txt=""
if [ -n "$merged" ]; then
  # Displayed value = pct of the session whose report changed most recently.
  # One value per LINE — never tab-joined: with IFS=$'\t' bash treats tab as
  # IFS *whitespace*, so leading empty fields collapse and every value shifts
  # left (this once put the weekly pct/reset inside the 5h segment).
  # Expired windows are NOT omitted on purpose: the countdown must reach
  # "0m" and sit there, so the user can SEE the limit just reset.
  # Freshness = last CONFIRMED server contact: a pct CHANGE from any session
  # ("at") or an API fetch ("__api__".seen). Plain "seen" of other sessions is
  # excluded — an idle terminal re-reports its stale snapshot on every tick.
  { read -r m_fp; read -r m_fr; read -r m_wp; read -r m_wr; read -r m_ls; } < <(
    printf '%s' "$merged" | jq -r '
      def best($w): (($w.sessions // {}) | to_entries | max_by(.value.at)) as $b
        | if $b == null then ["", ""]
          else [($b.value.pct | tostring), (($w.resets_at // "") | tostring)] end;
      def fresh: ([ (.five, .week) | (.sessions // {})
                    | (([.[].at] | max) // 0), ((.["__api__"] // {}).seen // 0) ] | max);
      (best(.five) + best(.week)
       + [ fresh as $f | if $f > 0 then ($f|tostring) else "" end ])[]')
  case "$m_ls" in
    ''|*[!0-9]*) ;;
    *) fresh_age=$(( now_epoch - m_ls ))
       [ "$fresh_age" -lt 0 ] && fresh_age=0
       if [ "$fresh_age" -lt 60 ]; then fresh_txt="${fresh_age}s"
       elif [ "$fresh_age" -lt 3600 ]; then fresh_txt="$(( fresh_age / 60 ))m"
       else fresh_txt="$(( fresh_age / 3600 ))h"
       fi ;;
  esac
  # No winner yet (fresh or legacy cache) -> keep this session's stdin values.
  if [ -n "$m_fp" ]; then five_pct="$m_fp"; five_reset="$m_fr"; fi
  if [ -n "$m_wp" ]; then week_pct="$m_wp"; week_reset="$m_wr"; fi
  # Persist atomically (mv is atomic on the same filesystem); skip the write
  # when nothing changed. Benign races self-heal on the next tick.
  if [ "$merged" != "$cache_raw" ]; then
    tmp="$CACHE_FILE.tmp.$$"
    if printf '%s' "$merged" >"$tmp" 2>/dev/null; then
      mv -f "$tmp" "$CACHE_FILE" 2>/dev/null || rm -f "$tmp"
    fi
  fi
  # GC: tmp files orphaned by crashed writers (kill -9 between write and mv).
  find "${CACHE_FILE%/*}" -maxdepth 1 \
    \( -name 'rate-limit-cache.json.tmp.*' -o -name 'usage-api-cache.json.tmp.*' \) \
    -mmin +10 -delete 2>/dev/null
fi

# Refetch decision — after the merge on purpose, so it sees the freshest
# "last confirmed" timestamp (m_ls) including this very tick's stdin report.
# Both gates must be open: no recent fetch attempt (mtime also absorbs
# failures via touch) AND no recent confirmation from any source.
api_mtime=$(stat -f %m "$API_CACHE" 2>/dev/null || echo 0)
last_confirm="$m_ls"
case "$last_confirm" in ''|*[!0-9]*) last_confirm=0 ;; esac
if [ $(( now_epoch - api_mtime )) -ge "$API_TTL" ] \
   && [ $(( now_epoch - last_confirm )) -ge "$API_TTL" ]; then
  spawn_usage_fetch
fi

five_time_left=$(fmt_remaining_time "$five_reset")
week_time_left=$(fmt_remaining_time "$week_reset")
# -----------------------------------------------------------------------------

# Build a small 10-segment progress bar for the 5h usage percentage
fmt_bar() {
  local pct="$1"
  [ -z "$pct" ] && return
  awk -v p="$pct" 'BEGIN {
    total = 10
    filled = int((p / 100) * total + 0.5)
    if (filled > total) filled = total
    if (filled < 0) filled = 0
    bar = ""
    for (i = 0; i < filled; i++) bar = bar "#"
    for (i = filled; i < total; i++) bar = bar "-"
    printf "%s", bar
  }'
}
five_bar=$(fmt_bar "$five_pct")
week_bar=$(fmt_bar "$week_pct")

# Colors (dim variants, suitable for terminal status lines)
DIM_CYAN='\033[2;36m'
DIM_GREEN='\033[2;32m'
DIM_YELLOW='\033[2;33m'
DIM_GRAY='\033[2;37m'
DIM_RED='\033[2;31m'
DIM_WHITE='\033[2;97m'
RESET='\033[0m'

sep() { printf "${DIM_GRAY}|${RESET}"; }
dsep() { printf "${DIM_GRAY}-${RESET}"; }  # lighter separator inside the rate-limit group

output=""

if [ -n "$account_name" ]; then
  output="$(printf "${DIM_WHITE}%s${RESET}" "$account_name")"
  output="$output $(sep)"
  output="$output $(printf "${DIM_CYAN}%s${RESET}" "$model")"
  if [ -n "$effort" ]; then
    output="$output $(printf "${DIM_GRAY}-${RESET}")"
    output="$output $(printf "${DIM_CYAN}%s${RESET}" "$effort")"
  fi
fi

if [ -n "$output" ]; then
  output="$output $(sep)"
  output="$output $(printf "${DIM_GREEN}%s${RESET}" "$dir_name")"
else
  output="$(printf "${DIM_GREEN}%s${RESET}" "$dir_name")"
fi

if [ -n "$branch" ]; then
  output="$output $(sep)"
  output="$output $(printf "${DIM_YELLOW}%s${RESET}" "$branch")"
fi

rl_open=""
if [ -n "$five_pct" ]; then
  output="$output $(sep)"
  output="$output $(printf "${DIM_GRAY}5h[${RESET}")"
  output="$output $(printf "${DIM_YELLOW}%s${RESET}" "$five_bar")"
  output="$output $(printf "${DIM_GRAY}]%s%%${RESET}" "$(printf '%.0f' "$five_pct")")"
  if [ -n "$five_time_left" ]; then
    output="$output $(printf "${DIM_GRAY}(%s)${RESET}" "$five_time_left")"
  fi
  rl_open=1
fi

if [ -n "$week_pct" ]; then
  if [ -n "$rl_open" ]; then output="$output $(dsep)"; else output="$output $(sep)"; fi
  output="$output $(printf "${DIM_GRAY}7d[${RESET}")"
  output="$output $(printf "${DIM_RED}%s${RESET}" "$week_bar")"
  output="$output $(printf "${DIM_GRAY}]%s%%${RESET}" "$(printf '%.0f' "$week_pct")")"
  if [ -n "$week_time_left" ]; then
    output="$output $(printf "${DIM_GRAY}(%s)${RESET}" "$week_time_left")"
  fi
  rl_open=1
fi

# How long since the shown numbers were last confirmed with the server.
if [ -n "$rl_open" ] && [ -n "$fresh_txt" ]; then
  output="$output $(dsep)"
  output="$output $(printf "${DIM_GRAY}↻%s${RESET}" "$fresh_txt")"
fi

if [ -n "$remaining" ]; then
  output="$output $(sep)"
  output="$output $(printf "${DIM_GRAY}ctx:%s%%${RESET}" "$(printf '%.0f' "$remaining")")"
fi

printf "%s" "$output"
