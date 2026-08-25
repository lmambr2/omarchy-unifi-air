# shellcheck shell=bash
# Shared Protect access for the UniFi Air bar widget.
#
# The console URL and TLS choice live in a plain state file; the API key and
# password live in the keyring and never reach argv. curl reads its options
# from a config on stdin (`curl --config -`). Login JSON is written to a
# 0600 file under the state dir and posted with `data = "@file"`, so a
# password with quotes cannot break the config.
#
# Every fetch failure is reported as JSON on stdout and exits 0, so the
# widget can render the reason rather than guess why a process died. A
# failure the user can fix by signing in carries "needsLogin": true.

readonly UNIFI_AIR_PLUGIN_ID="lane.unifi-air"
readonly UNIFI_AIR_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/unifi-air"
readonly UNIFI_AIR_CONFIG_FILE="$UNIFI_AIR_STATE_DIR/config"
readonly UNIFI_AIR_COOKIE_FILE="$UNIFI_AIR_STATE_DIR/cookie"

# Bootstrap includes every Protect camera and sensor. 8 MiB is enough for a
# home console and still bounds what a lying controller can make the shell
# hold. Integration-API lists are far smaller.
readonly UNIFI_AIR_MAX_BODY_BYTES=$(( 8 * 1024 * 1024 ))

UNIFI_AIR_URL=""
UNIFI_AIR_INSECURE=1
UNIFI_AIR_AUTH="password"
UNIFI_AIR_USERNAME=""
UNIFI_AIR_HTTP_CODE=""
UNIFI_AIR_HTTP_BODY=""

die() {
  jq -cn --arg m "$1" '{error: $m}'
  exit 0
}

die_needs_login() {
  jq -cn --arg m "$1" '{error: $m, needsLogin: true}'
  exit 0
}

unifi_air_require_commands() {
  local cmd
  for cmd in curl jq secret-tool; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not installed"
  done
}

unifi_air_ensure_state() {
  umask 077
  mkdir -p "$UNIFI_AIR_STATE_DIR"
}

# The curl config is line-oriented and its url/header values are quoted
# strings, so a newline, quote or backslash in any spliced value could turn
# data into a directive (`output = ~/.bashrc`).
unifi_air_config_safe() {
  local v
  for v in "$@"; do
    [[ $v != *[$'\n\r"\\']* ]] || return 1
  done
}

unifi_air_host_is_lan() { # host (no brackets required for IPv6)
  local h="${1#\[}"
  h="${h%\]}"
  h="${h,,}"
  case "$h" in
    localhost|localhost.localdomain|::1) return 0 ;;
    *.local) return 0 ;;
    fe80:*) return 0 ;;
  esac
  [[ $h =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  local a b c d
  IFS=. read -r a b c d <<<"$h" || return 1
  (( 10#$a == 10 )) && return 0
  (( 10#$a == 127 )) && return 0
  (( 10#$a == 192 && 10#$b == 168 )) && return 0
  (( 10#$a == 172 && 10#$b >= 16 && 10#$b <= 31 )) && return 0
  (( 10#$a == 169 && 10#$b == 254 )) && return 0
  return 1
}

# Canonical console origin: scheme://host[:port]. Paths, userinfo, query
# strings and fragments are refused or stripped so a typed URL cannot be
# concatenated into Origin/Referer/curl-config injection.
unifi_air_normalize_url() {
  local raw="$1"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  [[ -n $raw && ${#raw} -le 256 ]] || return 1
  unifi_air_config_safe "$raw" || return 1
  [[ $raw != *['@?#\\ ']* ]] || return 1

  local scheme hostport host port=""
  case "$raw" in
    http://*)  scheme=http;  hostport="${raw#http://}" ;;
    https://*) scheme=https; hostport="${raw#https://}" ;;
    *://*) return 1 ;;
    *) scheme=https; hostport="$raw" ;;
  esac
  hostport="${hostport%%/*}"
  [[ -n $hostport ]] || return 1

  if [[ $hostport == \[* ]]; then
    [[ $hostport =~ ^(\[[0-9A-Fa-f:.]+\])(:([0-9]{1,5}))?$ ]] || return 1
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[3]}"
  else
    host="${hostport%%:*}"
    if [[ $hostport == *:* ]]; then
      port="${hostport#*:}"
      [[ $port != *:* ]] || return 1
    fi
    [[ $host =~ ^([A-Za-z0-9]([A-Za-z0-9.-]{0,253}[A-Za-z0-9])?)$ ]] || return 1
    [[ $host != *..* ]] || return 1
  fi
  if [[ -n $port ]]; then
    [[ $port =~ ^[0-9]+$ ]] || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
    printf '%s://%s:%s' "$scheme" "$host" "$port"
  else
    printf '%s://%s' "$scheme" "$host"
  fi
}

unifi_air_host_from_url() {
  local origin="$1"
  origin="${origin#http://}"
  origin="${origin#https://}"
  printf '%s' "${origin%%:*}"
}

unifi_air_load_config() {
  [[ -r $UNIFI_AIR_CONFIG_FILE ]] || return 1
  local key value origin
  UNIFI_AIR_URL=""
  UNIFI_AIR_INSECURE=1
  UNIFI_AIR_AUTH="password"
  UNIFI_AIR_USERNAME=""
  while IFS='=' read -r key value; do
    case "$key" in
      url) UNIFI_AIR_URL="$value" ;;
      insecure) UNIFI_AIR_INSECURE="$value" ;;
      auth) UNIFI_AIR_AUTH="$value" ;;
      username) UNIFI_AIR_USERNAME="$value" ;;
    esac
  done <"$UNIFI_AIR_CONFIG_FILE"
  origin=$(unifi_air_normalize_url "$UNIFI_AIR_URL") || return 1
  UNIFI_AIR_URL="$origin"
  [[ $UNIFI_AIR_INSECURE == 0 || $UNIFI_AIR_INSECURE == 1 ]] || UNIFI_AIR_INSECURE=1
  [[ $UNIFI_AIR_AUTH == apikey || $UNIFI_AIR_AUTH == password ]] || UNIFI_AIR_AUTH="password"
  return 0
}

unifi_air_save_config() { # url insecure auth username
  local origin
  origin=$(unifi_air_normalize_url "$1") || return 1
  unifi_air_ensure_state
  printf 'url=%s\ninsecure=%s\nauth=%s\nusername=%s\n' "$origin" "$2" "$3" "$4" >"$UNIFI_AIR_CONFIG_FILE"
}

unifi_air_api_key() {
  secret-tool lookup application "$UNIFI_AIR_PLUGIN_ID" type api-key 2>/dev/null \
    || secret-tool lookup application hegjon.unifi type api-key 2>/dev/null
}

unifi_air_password() {
  secret-tool lookup application "$UNIFI_AIR_PLUGIN_ID" type password username "${UNIFI_AIR_USERNAME}" 2>/dev/null
}

unifi_air_have_api_key() {
  secret-tool lookup application "$UNIFI_AIR_PLUGIN_ID" type api-key >/dev/null 2>&1 \
    || secret-tool lookup application hegjon.unifi type api-key >/dev/null 2>&1
}

unifi_air_have_password() {
  [[ -n $UNIFI_AIR_USERNAME ]] || return 1
  secret-tool lookup application "$UNIFI_AIR_PLUGIN_ID" type password username "$UNIFI_AIR_USERNAME" >/dev/null 2>&1
}

unifi_air_store_api_key() {
  secret-tool store --label="UniFi Protect API key (Omarchy air)" \
    application "$UNIFI_AIR_PLUGIN_ID" type api-key
}

unifi_air_store_password() { # username
  secret-tool store --label="UniFi Protect login (Omarchy air)" \
    application "$UNIFI_AIR_PLUGIN_ID" type password username "$1"
}

unifi_air_clear() {
  secret-tool clear application "$UNIFI_AIR_PLUGIN_ID" type api-key 2>/dev/null || true
  if [[ -n $UNIFI_AIR_USERNAME ]]; then
    secret-tool clear application "$UNIFI_AIR_PLUGIN_ID" type password username "$UNIFI_AIR_USERNAME" 2>/dev/null || true
  fi
  rm -f "$UNIFI_AIR_CONFIG_FILE" "$UNIFI_AIR_COOKIE_FILE"
}

unifi_air_refuse_request() {
  UNIFI_AIR_HTTP_CODE=000
  UNIFI_AIR_HTTP_BODY='curl: (3) refused a request whose URL or key would break the curl config'
}

# Call directly, not inside $(...): sets UNIFI_AIR_HTTP_CODE / BODY.
# Body is written to a 0600 file then read only if it is under the cap, so a
# controller without Content-Length still cannot fill RAM.
unifi_air_run_curl() { # config
  local config="$1"
  unifi_air_ensure_state
  local out err code status size
  out=$(mktemp "$UNIFI_AIR_STATE_DIR/body.XXXXXX") || return 1
  err=$(mktemp "$UNIFI_AIR_STATE_DIR/err.XXXXXX") || { rm -f "$out"; return 1; }
  code=$(printf '%s\n' "$config" | curl --config - -m 20 \
    --max-filesize "$UNIFI_AIR_MAX_BODY_BYTES" \
    -o "$out" -w '%{http_code}' 2>"$err")
  status=$?
  if [[ $status == 63 ]]; then
    UNIFI_AIR_HTTP_CODE=000
    UNIFI_AIR_HTTP_BODY="curl: (63) response larger than $(( UNIFI_AIR_MAX_BODY_BYTES / 1024 / 1024 )) MB"
    rm -f "$out" "$err"
    return
  fi
  if [[ $status != 0 ]]; then
    UNIFI_AIR_HTTP_CODE="${code:-000}"
    UNIFI_AIR_HTTP_BODY=$(head -c 512 "$err" 2>/dev/null || true)
    [[ -n $UNIFI_AIR_HTTP_BODY ]] || UNIFI_AIR_HTTP_BODY="curl: ($status) request failed"
    rm -f "$out" "$err"
    return
  fi
  size=$(stat -c%s "$out" 2>/dev/null || echo 0)
  if (( size > UNIFI_AIR_MAX_BODY_BYTES )); then
    UNIFI_AIR_HTTP_CODE=000
    UNIFI_AIR_HTTP_BODY="curl: (63) response larger than $(( UNIFI_AIR_MAX_BODY_BYTES / 1024 / 1024 )) MB"
    rm -f "$out" "$err"
    return
  fi
  UNIFI_AIR_HTTP_CODE="${code:-000}"
  UNIFI_AIR_HTTP_BODY=$(<"$out")
  rm -f "$out" "$err"
}

unifi_air_http_get() { # absolute-url [api-key] [cookie-file]
  local url="$1" key="${2:-}" cookie="${3:-}"
  local config
  unifi_air_config_safe "$url" || { unifi_air_refuse_request; return; }
  [[ -z $key ]] || unifi_air_config_safe "$key" || { unifi_air_refuse_request; return; }
  [[ -z $cookie ]] || unifi_air_config_safe "$cookie" || { unifi_air_refuse_request; return; }
  config=$(printf '%s\n' \
    "url = \"$url\"" \
    'header = "Accept: application/json"' \
    "silent")
  if [[ -n $key ]]; then
    config+=$(printf '\nheader = "X-API-KEY: %s"' "$key")
  fi
  if [[ -n $cookie ]]; then
    config+=$(printf '\ncookie = "%s"\ncookie-jar = "%s"' "$cookie" "$cookie")
  fi
  [[ ${UNIFI_AIR_INSECURE:-0} == 1 ]] && config+=$'\ninsecure'
  unifi_air_run_curl "$config"
}

# POST /api/auth/login. Password never appears in the curl config or argv:
# jq writes the JSON to a state-dir file, curl reads it with data = "@file".
# No Cookie header is sent (a leftover TOKEN made Protect return 403).
unifi_air_http_login() { # username password
  local user="$1" pass="$2"
  local url="${UNIFI_AIR_URL}/api/auth/login"
  local body config
  unifi_air_config_safe "$url" "$UNIFI_AIR_URL" "$UNIFI_AIR_COOKIE_FILE" \
    || { unifi_air_refuse_request; return; }
  unifi_air_ensure_state
  body=$(mktemp "$UNIFI_AIR_STATE_DIR/auth.XXXXXX") || return 1
  unifi_air_config_safe "$body" || { rm -f "$body"; unifi_air_refuse_request; return; }
  jq -nc --arg u "$user" --arg p "$pass" \
    '{username:$u, password:$p, rememberMe:false}' >"$body" || { rm -f "$body"; return 1; }
  rm -f "$UNIFI_AIR_COOKIE_FILE"
  config=$(printf '%s\n' \
    "url = \"$url\"" \
    'header = "Accept: application/json"' \
    'header = "Content-Type: application/json"' \
    "header = \"Origin: $UNIFI_AIR_URL\"" \
    "header = \"Referer: $UNIFI_AIR_URL/\"" \
    "data = \"@$body\"" \
    "cookie-jar = \"$UNIFI_AIR_COOKIE_FILE\"" \
    "silent")
  [[ ${UNIFI_AIR_INSECURE:-0} == 1 ]] && config+=$'\ninsecure'
  unifi_air_run_curl "$config"
  rm -f "$body"
}

unifi_air_describe_http_failure() {
  case "$UNIFI_AIR_HTTP_CODE" in
    200) return 1 ;;
    401|403) printf 'The console rejected the Protect login' ;;
    404) printf 'No Protect API at %s' "$UNIFI_AIR_URL" ;;
    429) printf 'The console is rate limiting requests' ;;
    000)
      local reason
      reason=$(head -n1 <<<"$UNIFI_AIR_HTTP_BODY" | sed 's/^curl: ([0-9]*) //')
      case "$reason" in
        *"response larger"*) printf 'The console sent a %s' "$reason" ;;
        *"certificate"*|*"SSL"*)
          printf 'TLS verification failed — re-run setup and allow the self-signed certificate' ;;
        *"refused a request"*)
          printf 'The stored console URL is not usable — run setup again' ;;
        "") printf 'Could not reach %s' "$UNIFI_AIR_URL" ;;
        *) printf 'Could not reach %s: %s' "$UNIFI_AIR_URL" "$reason" ;;
      esac ;;
    *) printf 'The console returned HTTP %s' "$UNIFI_AIR_HTTP_CODE" ;;
  esac
}
