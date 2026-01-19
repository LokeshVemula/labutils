#!/bin/bash
# check_recover_node_dns_safe.sh
# DNS-safe flow:
#   CONNECT_TARGET (IP recommended) is used for ping/ssh.
#   PDU_OUTLET_NAME (string label) is used to find the outlet on APC AP7911B.
#   If ssh ok => report success.
#   Else try IPMI power cycle.
#   If IPMI fails/unreachable => PDU OFF 60s ON, then recheck.

set -u
set -o pipefail

log(){ echo "[$(date '+%F %T')] $*"; }

check_command() {
  if ! command -v "$1" &>/dev/null; then
    echo "Error: '$1' not found. Install package: $2"
    exit 1
  fi
}

is_ping_ok() { ping -c 2 -W 2 "$1" >/dev/null 2>&1; }

ssh_prompt_ok() {
  local user="$1" host="$2"
  expect -c "
    set timeout 10
    log_user 0
    spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 ${user}@${host}
    expect {
      \"(yes/no)\" { send \"yes\r\"; exp_continue }
      \"password:\" { exit 0 }
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

# ---------- APC AP7911B via SNMP ----------
snmp_find_outlet_index_by_name_apc() {
  local pdu_ip="$1" community="$2" outlet_name="$3"
  local name_oid_base=".1.3.6.1.4.1.318.1.1.12.3.3.1.1.2" # rPDUOutletControlOutletName.<idx>

  snmpwalk -v2c -c "$community" "$pdu_ip" "$name_oid_base" 2>/dev/null \
    | while IFS= read -r line; do
        oid="${line%% = *}"
        val="${line#*STRING: }"
        val="${val%$'\r'}"
        val="${val%\"}"; val="${val#\"}"
        if [[ "${val,,}" == "${outlet_name,,}" ]]; then
          echo "${oid##*.}"
          exit 0
        fi
      done
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
apc_pdu_run_cli_cmd() {
  local pdu_ip="$1" pdu_user="$2" pdu_pass="$3" cmd="$4"
  expect -c "
    set timeout 15
    log_user 0
    spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 ${pdu_user}@${pdu_ip}
    expect {
      \"(yes/no)\" { send \"yes\r\"; exp_continue }
      \"password:\" { send \"${pdu_pass}\r\" }
      timeout { exit 2 }
      eof { exit 2 }
    }
    expect {
      \"apc>\" {}
      timeout { exit 2 }
      eof { exit 2 }
    }
    send \"${cmd}\r\"
    expect {
      -re \"E000: Success\" { }
      \"apc>\" { }
      timeout { exit 3 }
      eof { exit 3 }
    }
    send \"exit\r\"
    expect eof
  " >/dev/null 2>&1
}

apc_pdu_cycle_ssh() {
  local pdu_ip="$1" pdu_user="$2" pdu_pass="$3" outlet_name="$4" off_wait="$5"
  log "PDU(SSH): OFF outlet label='$outlet_name'"
  apc_pdu_run_cli_cmd "$pdu_ip" "$pdu_user" "$pdu_pass" "olOff \"$outlet_name\"" || return 1
  sleep "$off_wait"
  log "PDU(SSH): ON outlet label='$outlet_name'"
  apc_pdu_run_cli_cmd "$pdu_ip" "$pdu_user" "$pdu_pass" "olOn \"$outlet_name\"" || return 1
  return 0
}

# ========================= Main =========================
check_command ping iputils-ping
check_command expect expect
check_command ipmitool ipmitool

# Key change: separate "how to connect" from "outlet label"
read -p "Enter CONNECT TARGET for ping/ssh (IP recommended): " CONNECT_TARGET
read -p "Enter SSH username for the system: " SSH_USER
read -p "Enter PDU outlet label (hostname/asset tag). Leave blank to reuse CONNECT TARGET: " PDU_OUTLET_NAME
PDU_OUTLET_NAME="${PDU_OUTLET_NAME:-$CONNECT_TARGET}"

read -p "Enter IPMI/BMC IP: " IPMI_IP
read -p "Enter IPMI username: " IPMI_USER
read -s -p "Enter IPMI password: " IPMI_PASS; echo

read -p "Enter APC AP7911B PDU IP: " PDU_IP
read -p "Enter PDU username (SSH CLI): " PDU_USER
read -s -p "Enter PDU password (SSH CLI): " PDU_PASS; echo
read -s -p "Enter SNMP v2c write community (blank to skip SNMP and use SSH CLI): " PDU_SNMP_COMM; echo

OFF_WAIT=60
RECOVERY_WAIT_TOTAL=600
RECOVERY_INTERVAL=20

log "Target for network checks: CONNECT_TARGET='$CONNECT_TARGET'"
log "Target for PDU outlet matching: PDU_OUTLET_NAME='$PDU_OUTLET_NAME'"

log "Step 1: Ping $CONNECT_TARGET..."
if is_ping_ok "$CONNECT_TARGET"; then
  log "Ping OK."
else
  log "Ping FAILED."
fi

log "Step 2: SSH responsiveness check to $CONNECT_TARGET..."
if ssh_prompt_ok "$SSH_USER" "$CONNECT_TARGET"; then
  log "RESULT: System is UP and SSH is accessible via '$CONNECT_TARGET'."
  exit 0
fi

log "SSH check FAILED. Trying IPMI..."

log "Step 3: Ping IPMI $IPMI_IP..."
if is_ping_ok "$IPMI_IP"; then
  log "IPMI ping OK. Sending IPMI power cycle..."
  if ipmi_power_cycle "$IPMI_IP" "$IPMI_USER" "$IPMI_PASS"; then
    log "IPMI power cycle sent. Waiting for recovery..."
    if wait_for_recovery "$CONNECT_TARGET" "$SSH_USER" "$RECOVERY_WAIT_TOTAL" "$RECOVERY_INTERVAL"; then
      log "RESULT: Recovered after IPMI power cycle. SSH accessible via '$CONNECT_TARGET'."
      exit 0
    else
      log "WARN: IPMI succeeded but system not accessible in time window. Escalating to PDU."
    fi
  else
    log "WARN: ipmitool failed (RMCP+/creds). Escalating to PDU."
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
    log "ERROR: PDU(SSH) failed. Check outlet label, user permissions, or PDU reachability."
    exit 2
  fi
fi

log "PDU cycle done. Waiting for recovery..."
if wait_for_recovery "$CONNECT_TARGET" "$SSH_USER" "$RECOVERY_WAIT_TOTAL" "$RECOVERY_INTERVAL"; then
  log "RESULT: Recovered after PDU cycle. SSH accessible via '$CONNECT_TARGET'."
  exit 0
else
  log "RESULT: Still not accessible after PDU cycle + wait window."
  exit 3
fi
