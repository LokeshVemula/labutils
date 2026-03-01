#!/usr/bin/env python3
import argparse
import csv
import socket
from datetime import datetime
from getpass import getpass

import paramiko


REMOTE_COMMANDS = {
    "lspci_amd": r"lspci -nn | egrep -i 'vga|3d|display' | egrep -i 'amd|ati' || true",
    "rocm_smi":  r"(command -v rocm-smi >/dev/null 2>&1 && rocm-smi -i) || true",
    "amd_smi":   r"(command -v amd-smi  >/dev/null 2>&1 && amd-smi list) || true",
}


def read_hosts(path: str) -> list[str]:
    with open(path, "r", encoding="utf-8") as f:
        return [h.strip() for h in f if h.strip() and not h.strip().startswith("#")]


def ssh_exec(host: str, user: str, password: str, cmd: str, port: int, timeout: int) -> tuple[int, str, str]:
    """
    Returns (rc, stdout, stderr). rc is command exit status when available; -1 on connection errors.
    """
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    try:
        client.connect(
            hostname=host,
            port=port,
            username=user,
            password=password,
            timeout=timeout,
            auth_timeout=timeout,
            banner_timeout=timeout,
            look_for_keys=False,   # force password auth
            allow_agent=False,     # don't use ssh-agent
        )

        stdin, stdout, stderr = client.exec_command(cmd, timeout=timeout)
        out = stdout.read().decode(errors="replace").strip()
        err = stderr.read().decode(errors="replace").strip()
        rc = stdout.channel.recv_exit_status()
        return rc, out, err

    except paramiko.AuthenticationException as e:
        return -1, "", f"AUTH FAILED: {e}"
    except (paramiko.SSHException, socket.timeout, TimeoutError) as e:
        return -1, "", f"SSH ERROR: {e}"
    except Exception as e:
        return -1, "", f"ERROR: {e}"
    finally:
        try:
            client.close()
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser(description="Collect AMD GPU inventory from remote Linux hosts via password SSH.")
    ap.add_argument("-H", "--hosts", default="hosts.txt", help="Hosts file (one host per line)")
    ap.add_argument("-u", "--user", required=True, help="SSH username")
    ap.add_argument("-p", "--port", type=int, default=22, help="SSH port")
    ap.add_argument("-t", "--timeout", type=int, default=10, help="Timeout seconds")
    ap.add_argument("-o", "--output", default="amd_gpu_inventory.csv", help="Output CSV file")
    ap.add_argument("--no-prompt", action="store_true", help="Read password from env var SSH_PASSWORD instead of prompting")
    args = ap.parse_args()

    password = None
    if args.no_prompt:
        import os
        password = os.environ.get("SSH_PASSWORD")
        if not password:
            raise SystemExit("Missing SSH_PASSWORD environment variable (used because --no-prompt was set).")
    else:
        password = getpass(f"SSH password for {args.user}: ")

    hosts = read_hosts(args.hosts)
    ts = datetime.now().isoformat(timespec="seconds")

    rows = []
    for host in hosts:
        row = {
            "timestamp": ts,
            "host": host,
            "reachable": "no",
            "amd_gpu_count_pci": 0,
            "pci_amd_lines": "",
            "rocm_smi_present": "no",
            "amd_smi_present": "no",
            "rocm_smi_out": "",
            "amd_smi_out": "",
            "error": "",
        }

        # Connectivity test
        rc, out, err = ssh_exec(host, args.user, password, "echo OK", args.port, args.timeout)
        if rc != 0 or out.strip() != "OK":
            row["error"] = err or out or f"ssh failed rc={rc}"
            rows.append(row)
            print(f"{host}: FAIL - {row['error']}")
            continue

        row["reachable"] = "yes"

        # lspci inventory
        rc, lspci_out, lspci_err = ssh_exec(host, args.user, password, REMOTE_COMMANDS["lspci_amd"], args.port, args.timeout)
        if lspci_err and rc != 0:
            row["error"] = lspci_err

        amd_lines = [ln.strip() for ln in lspci_out.splitlines() if ln.strip()]
        row["amd_gpu_count_pci"] = len(amd_lines)
        row["pci_amd_lines"] = " | ".join(amd_lines)

        # rocm-smi
        rc, rocm_out, _ = ssh_exec(host, args.user, password, REMOTE_COMMANDS["rocm_smi"], args.port, args.timeout)
        if rocm_out.strip():
            row["rocm_smi_present"] = "yes"
            row["rocm_smi_out"] = rocm_out.replace("\n", " | ")

        # amd-smi
        rc, amdsmi_out, _ = ssh_exec(host, args.user, password, REMOTE_COMMANDS["amd_smi"], args.port, args.timeout)
        if amdsmi_out.strip():
            row["amd_smi_present"] = "yes"
            row["amd_smi_out"] = amdsmi_out.replace("\n", " | ")

        rows.append(row)
        print(f"{host}: OK - AMD GPUs (PCI)={row['amd_gpu_count_pci']}")

    # Write CSV
    if rows:
        with open(args.output, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)

    print(f"\nWrote: {args.output}")


if __name__ == "__main__":
    main()
