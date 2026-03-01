#!/usr/bin/env bash
set -euo pipefail

SYSTEMS_FILE="${1:-systems.txt}"
CREDS_FILE="${2:-creds.txt}"
OUT_ALL="${3:-results_all.csv}"
OUT_SUCCESS="${4:-results_success.csv}"

SSH_PORT=22
CONNECT_TIMEOUT=6
ATTEMPT_DELAY_SEC=1
STOP_AFTER_FIRST_SUCCESS=1     # 1=yes, 0=no
MASK_PASSWORDS=0               # 1 to hide passwords in CSV

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }
need ssh
need sshpass
need sed
need awk
need sort
need timeout

ts() { date +"%Y-%m-%d %H:%M:%S"; }

mask_pw() {
  local p="$1"
  if [[ "$MASK_PASSWORDS" -eq 1 ]]; then
    echo "********"
  else
    echo "$p"
  fi
}

trim_line() {
  # trims leading/trailing whitespace
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Dedupe systems only (safe)
mapfile -t SYSTEMS < <(
  sed -e 's/#.*$//' "$SYSTEMS_FILE" | trim_line | awk 'NF' | sort -u
)

# DO NOT “process” creds with awk - keep as raw lines.
# Treat format as: username:password (password may include colons)
mapfile -t CREDS < <(
  sed -e 's/#.*$//' "$CREDS_FILE" | trim_line | awk 'NF'
)

# Port check (fast)
port_open() {
  local host="$1" port="$2"
  timeout "$CONNECT_TIMEOUT" bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1
}

classify_err() {
  local err="$1"
  err="$(echo "$err" | tr -d '\r')"

  if grep -qiE "could not resolve hostname|name or service not known" <<<"$err"; then
    echo "dns_failed"
  elif grep -qiE "no route to host|network is unreachable" <<<"$err"; then
    echo "network_unreachable"
  elif grep -qiE "connection timed out" <<<"$err"; then
    echo "connect_timeout"
  elif grep -qiE "connection refused" <<<"$err"; then
    echo "connection_refused"
  elif grep -qiE "host key verification failed" <<<"$err"; then
    echo "hostkey_verification_failed"
  elif grep -qiE "permission denied \(publickey" <<<"$err"; then
    echo "password_auth_disabled_or_pubkey_only"
  elif grep -qiE "permission denied" <<<"$err"; then
    echo "auth_failed_bad_password"
  elif grep -qiE "too many authentication failures" <<<"$err"; then
    echo "too_many_auth_failures"
  elif grep -qiE "keyboard-interactive" <<<"$err"; then
    echo "keyboard_interactive_required"
  elif grep -qiE "authentication failed" <<<"$err"; then
    echo "auth_failed"
  else
    # keep last meaningful line for debugging
    local last
    last="$(echo "$err" | awk 'NF{p=$0} END{print p}')"
    [[ -z "$last" ]] && last="(no_ssh_stderr_captured)"
    echo "unknown_error:${last:0:160}"
  fi
}

try_ssh() {
  local host="$1" user="$2" pass="$3"

  local errfile rc err result
  errfile="$(mktemp)"
  # Capture stderr to errfile, discard stdout
  sshpass -p "$pass" ssh \
    -p "$SSH_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o NumberOfPasswordPrompts=1 \
    -o ConnectTimeout="$CONNECT_TIMEOUT" \
    -o ConnectionAttempts=1 \
    "${user}@${host}" "true" \
    1>/dev/null 2>"$errfile"
  rc=$?
  err="$(cat "$errfile")"
  rm -f "$errfile"

  if [[ "$rc" -eq 0 ]]; then
    echo "SUCCESS"
    return 0
  fi

  result="$(classify_err "$err")"
  echo "$result"
  return 1
}

echo "time,host,username,password,result" > "$OUT_ALL"
echo "time,host,username,password,result" > "$OUT_SUCCESS"

for host in "${SYSTEMS[@]}"; do
  # quick reachability
  if ! port_open "$host" "$SSH_PORT"; then
    echo "$(ts),${host},,,port_22_closed_or_unreachable" >> "$OUT_ALL"
    continue
  fi

  found=0

  for line in "${CREDS[@]}"; do
    # Must contain at least one colon
    [[ "$line" == *:* ]] || continue

    user="${line%%:*}"
    pass="${line#*:}"   # everything after first colon (keeps amd:amd intact)

    [[ -n "$user" && -n "$pass" ]] || continue

    result="$(try_ssh "$host" "$user" "$pass" || true)"
    out_pass="$(mask_pw "$pass")"

    echo "$(ts),${host},${user},${out_pass},${result}" >> "$OUT_ALL"

    if [[ "$result" == "SUCCESS" ]]; then
      echo "$(ts),${host},${user},${out_pass},${result}" >> "$OUT_SUCCESS"
      found=1
      [[ "$STOP_AFTER_FIRST_SUCCESS" -eq 1 ]] && break
    fi

    sleep "$ATTEMPT_DELAY_SEC"
  done

  [[ "$found" -eq 0 ]] && echo "$(ts),${host},,,NO_VALID_CREDS_FOUND" >> "$OUT_ALL"
done

echo "Done."
echo "All attempts: $OUT_ALL"
echo "Success-only: $OUT_SUCCESS"
