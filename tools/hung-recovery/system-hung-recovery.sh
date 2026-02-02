#!/bin/bash
# system_hung_recovery.sh (simple updated working version)
# Fixes:
#  - Expect argv bug (no use of $argv)
#  - SNMP outlet lookup subshell bug
#  - Better APC SSH CLI success validation (requires "E000: Success")
# Usage:
#  DEBUG=1 ./system_hung_recovery.sh   (prints PDU output on failure)

set -u
set -o pipefail

DEBUG="${DEBUG:-0}"

log(){ echo "[$(date '+%F %T')] $*"; }
dbg(){ [[ "$DEBUG" == "1" ]] && echo "[DEBUG] $*" >&2 || true; }

check_command() {
  if ! command -v "$1" &>/dev/null; then
    echo "Error: '$1' not found. Install package: $2" >&2
    exit 1
  fi
}

is_ping_ok() { ping -c 2 -W 2 "$1" >/dev/null 2>&1; }

resolve_ipv4_first() {
  local host="$1" ip=""
  if command -v getent >/dev/null 2>&1; then
    ip="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')"
  fi
  [[ -n "$ip" ]] && echo "$ip" || echo "$host"
}

ssh_prompt_ok() {
  local user="$1" host="$2"
  expect -c "
    set timeout 10
    log_user 0
    spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 ${user}@${host}
    expect {
      \"(yes/no)\" { send \"yes\r\"; exp_continue }
      -re \"(?i)password:\" { exit 0 }
      \"Permission denied\" { exit 0 }
      \"Connection refused\" { exit 1 }
      timeout { exit 1 }
      eof { exit 1 }
    }
  " >/dev/null 2>&1
}

wait_for_recovery() {
  local host="$1" ssh_user="$2" total="$3" interval="$4"
  local elapsed=0
  while (( elapsed < total )); do
    if is_ping_ok "$host" && ssh_prompt_ok "$ssh_user" "$host"; then
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  return 1
}

ipmi_power_cycle() {
  local ipmi_ip="$1" user="$2" pass="$3"
  ipmitool -I lanplus -H "$ipmi_ip" -U "$user" -P "$pass" chassis power cycle >/dev/null 2>&1
}

# -------- Tcl escaping for expect here-doc embedding --------
tcl_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/\\n}"
  echo "$s"
}

# ---------- APC AP7911B via SNMP ----------
snmp_find_outlet_index_by_name_apc() {
  local pdu_ip="$1" community="$2" outlet_name="$3"
  local name_oid_base=".1.3.6.1.4.1.318.1.1.12.3.3.1.1.2" # rPDUOutletControlOutletName.<idx>

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local oid="${line%% = *}"
    local val="${line#*STRING: }"
    val="${val%$'\r'}"
    val="${val%\"}"; val="${val#\"}"
    if [[ "${val,,}" == "${outlet_name,,}" ]]; then
      echo "${oid##*.}"
      return 0
    fi
  done < <(snmpwalk -v2c -c "$community" "$pdu_ip" "$name_oid_base" 2>/dev/null)

  return 1
}

apc_pdu_cycle_snmp() {
  local pdu_ip="$1" community="$2" outlet_name="$3" off_wait="$4"
  local cmd_oid_base=".1.3.6.1.4.1.318.1.1.12.3.3.1.1.4" # rPDUOutletControlOutletCommand.<idx>
  # values: immediateOn(1), immediateOff(2), immediateReboot(3)

  local idx
  idx="$(snmp_find_outlet_index_by_name_apc "$pdu_ip" "$community" "$outlet_name")" || return 1

  log "PDU(SNMP): matched outlet index=$idx for label='$outlet_name'"
  log "PDU(SNMP): OFF index=$idx (wait ${off_wait}s) then ON"
  snmpset -v2c -c "$community" "$pdu_ip" "${cmd_oid_base}.${idx}" i 2 >/dev/null 2>&1 || return 1
  sleep "$off_wait"
  snmpset -v2c -c "$community" "$pdu_ip" "${cmd_oid_base}.${idx}" i 1 >/dev/null 2>&1 || return 1
  return 0
}

# ---------- APC AP7911B via SSH CLI ----------
apc_pdu_expect_cmd() {
  # returns 0 only if output contains "E000: Success"
  local pdu_ip="$1" pdu_user="$2" pdu_pass="$3" cmd="$4"

  local ip_e user_e pass_e cmd_e
  ip_e="$(tcl_escape "$pdu_ip")"
  user_e="$(tcl_escape "$pdu_user")"
  pass_e="$(tcl_escape "$pdu_pass")"
  cmd_e="$(tcl_escape "$cmd")"

  local out rc
  out="$(
    expect <<EOF
      set timeout 25
      log_user 0
      set ip   "$ip_e"
      set user "$user_e"
      set pass "$pass_e"
      set cmd  "$cmd_e"

      spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \$user@\$ip
      expect {
        "(yes/no)" { send "yes\r"; exp_continue }
        -re "(?i)password:" { send -- "\$pass\r" }
        timeout { exit 2 }
        eof { exit 2 }
      }

      expect {
        -re "(?i)apc>" {}
        timeout { exit 2 }
        eof { exit 2 }
      }

      send -- "\$cmd\r"
      expect {
        -re "(?i)enter.*yes.*:" { send -- "YES\r"; exp_continue }
        -re "(?i)are you sure.*\\(y/n\\)" { send -- "y\r"; exp_continue }
        -re "(?i)apc>" {}
        timeout { exit 3 }
        eof { exit 3 }
      }

      puts \$expect_out(buffer)

      send -- "exit\r"
      expect eof
EOF
  )"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    dbg "PDU expect transport rc=$rc for cmd: $cmd"
    [[ "$DEBUG" == "1" ]] && echo "$out" >&2 || true
    return 1
  fi

  if echo "$out" | grep -q "E000: Success"; then
    return 0
  fi

  dbg "PDU cmd did not return E000: Success. cmd: $cmd"
  [[ "$DEBUG" == "1" ]] && echo "$out" >&2 || true
  return 1
}

apc_pdu_get_outlet_number_by_label_ssh() {
  local pdu_ip="$1" pdu_user="$2" pdu_pass="$3" label="$4"

  local ip_e user_e pass_e
  ip_e="$(tcl_escape "$pdu_ip")"
  user_e="$(tcl_escape "$pdu_user")"
  pass_e="$(tcl_escape "$pdu_pass")"

  local out
  out="$(
    expect <<EOF
      set timeout 25
      log_user 0
      set ip   "$ip_e"
      set user "$user_e"
      set pass "$pass_e"

      spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \$user@\$ip
      expect {
        "(yes/no)" { send "yes\r"; exp_continue }
        -re "(?i)password:" { send -- "\$pass\r" }
        timeout { exit 2 }
        eof { exit 2 }
      }

      expect { -re "(?i)apc>" {} timeout { exit 2 } eof { exit 2 } }

      send -- "olStatus all\r"
      expect { -re "(?i)apc>" {} timeout { exit 3 } eof { exit 3 } }
      puts \$expect_out(buffer)

      send -- "exit\r"
      expect eof
EOF
  )" || return 1

  # common format: "<n>: ON : <name>" (varies by firmware)
  echo "$out" | awk -v needle="$label" '
    BEGIN { IGNORECASE=1 }
    match($0, /^[[:space:]]*([0-9]+)[[:space:]]*:[[:space:]]*[A-Z]+[[:space:]]*:[[:space:]]*(.*)$/, m) {
      num=m[1]; name=m[2];
      gsub(/[[:space:]]+$/, "", name);
      if (tolower(name) == tolower(needle)) { print num; exit 0; }
    }
  '
}

apc_pdu_set_state_ssh() {
  local pdu_ip="$1" pdu_user="$2" pdu_pass="$3" outlet="$4" state="$5"
  local cmds=()
  case "$state" in
    off) cmds=("olOff $outlet" "olDlyOff $outlet") ;;
    on)  cmds=("olOn $outlet"  "olDlyOn $outlet") ;;
    *)   return 1 ;;
  esac

  local c
  for c in "${cmds[@]}"; do
    if apc_pdu_expect_cmd "$pdu_ip" "$pdu_user" "$pdu_pass" "$c"; then
      return 0
    fi
  done
  return 1
}

apc_pdu_cycle_ssh() {
  local pdu_ip="$1" pdu_user="$2" pdu_pass="$3" outlet_label="$4" off_wait="$5"

  local outlet="$outlet_label"
  if ! [[ "$outlet_label" =~ ^[0-9]+$ ]]; then
    local mapped
    mapped="$(apc_pdu_get_outlet_number_by_label_ssh "$pdu_ip" "$pdu_user" "$pdu_pass" "$outlet_label" 2>/dev/null || true)"
    if [[ -n "$mapped" ]]; then
      log "PDU(SSH): mapped label '$outlet_label' -> outlet #$mapped"
      outlet="$mapped"
    else
      log "PDU(SSH): could not map label '$outlet_label' to an outlet number; will try label directly."
    fi
  fi

  log "PDU(SSH): OFF outlet='$outlet' (from label='$outlet_label')"
  apc_pdu_set_state_ssh "$pdu_ip" "$pdu_user" "$pdu_pass" "$outlet" "off" || return 1
  sleep "$off_wait"
  log "PDU(SSH): ON outlet='$outlet' (from label='$outlet_label')"
  apc_pdu_set_state_ssh "$pdu_ip" "$pdu_user" "$pdu_pass" "$outlet" "on" || return 1
  return 0
}

# ========================= Main =========================
check_command ping iputils-ping
check_command expect expect
check_command ipmitool ipmitool

read -p "Enter CONNECT TARGET for ping/ssh (IP recommended): " CONNECT_TARGET
read -p "Enter SSH username for the system: " SSH_USER
read -p "Enter PDU outlet label (hostname/asset tag) OR outlet number: " PDU_OUTLET_NAME

read -p "Enter IPMI/BMC IP or hostname: " IPMI_IP
read -p "Enter IPMI username: " IPMI_USER
read -s -p "Enter IPMI password: " IPMI_PASS; echo

read -p "Enter APC PDU IP: " PDU_IP
read -p "Enter PDU username (SSH CLI): " PDU_USER
read -s -p "Enter PDU password (SSH CLI): " PDU_PASS; echo
read -s -p "Enter SNMP v2c write community (blank to skip SNMP and use SSH CLI): " PDU_SNMP_COMM; echo

OFF_WAIT=60
RECOVERY_WAIT_TOTAL=600
RECOVERY_INTERVAL=20

CONNECT_TARGET_RESOLVED="$(resolve_ipv4_first "$CONNECT_TARGET")"
IPMI_IP_RESOLVED="$(resolve_ipv4_first "$IPMI_IP")"

log "Target for network checks: CONNECT_TARGET='$CONNECT_TARGET' (using '$CONNECT_TARGET_RESOLVED')"
log "Target for PDU outlet matching: PDU_OUTLET_NAME='$PDU_OUTLET_NAME'"
log "IPMI target: '$IPMI_IP' (using '$IPMI_IP_RESOLVED')"

log "Step 1: Ping $CONNECT_TARGET_RESOLVED..."
if is_ping_ok "$CONNECT_TARGET_RESOLVED"; then log "Ping OK."; else log "Ping FAILED."; fi

log "Step 2: SSH responsiveness check to $CONNECT_TARGET_RESOLVED..."
if ssh_prompt_ok "$SSH_USER" "$CONNECT_TARGET_RESOLVED"; then
  log "RESULT: System is UP and SSH is responsive via '$CONNECT_TARGET_RESOLVED'."
  exit 0
fi

log "SSH check FAILED. Trying IPMI..."

log "Step 3: Ping IPMI $IPMI_IP_RESOLVED..."
if is_ping_ok "$IPMI_IP_RESOLVED"; then
  log "IPMI ping OK. Sending IPMI power cycle..."
  if ipmi_power_cycle "$IPMI_IP_RESOLVED" "$IPMI_USER" "$IPMI_PASS"; then
    log "IPMI power cycle sent. Waiting for recovery..."
    if wait_for_recovery "$CONNECT_TARGET_RESOLVED" "$SSH_USER" "$RECOVERY_WAIT_TOTAL" "$RECOVERY_INTERVAL"; then
      log "RESULT: Recovered after IPMI power cycle. SSH responsive via '$CONNECT_TARGET_RESOLVED'."
      exit 0
    else
      log "WARN: IPMI succeeded but system not accessible in time window. Escalating to PDU."
    fi
  else
    log "WARN: ipmitool failed (network/creds). Escalating to PDU."
  fi
else
  log "IPMI ping FAILED. Escalating to PDU."
fi

log "Step 4: PDU fallback: OFF '$PDU_OUTLET_NAME' for ${OFF_WAIT}s then ON."

PDU_OK=false

if [[ -n "${PDU_SNMP_COMM}" ]]; then
  check_command snmpwalk snmp
  check_command snmpset snmp
  if apc_pdu_cycle_snmp "$PDU_IP" "$PDU_SNMP_COMM" "$PDU_OUTLET_NAME" "$OFF_WAIT"; then
    PDU_OK=true
  else
    log "WARN: PDU(SNMP) failed. Will try PDU(SSH) CLI."
  fi
fi

if [[ "$PDU_OK" != "true" ]]; then
  if apc_pdu_cycle_ssh "$PDU_IP" "$PDU_USER" "$PDU_PASS" "$PDU_OUTLET_NAME" "$OFF_WAIT"; then
    PDU_OK=true
  else
    log "ERROR: PDU(SSH) failed. Run with DEBUG=1 to see PDU output."
    exit 2
  fi
fi

log "PDU cycle done. Waiting for recovery..."
if wait_for_recovery "$CONNECT_TARGET_RESOLVED" "$SSH_USER" "$RECOVERY_WAIT_TOTAL" "$RECOVERY_INTERVAL"; then
  log "RESULT: Recovered after PDU cycle. SSH responsive via '$CONNECT_TARGET_RESOLVED'."
  exit 0
else
  log "RESULT: Still not accessible after PDU cycle + wait window."
  exit 3
fi
