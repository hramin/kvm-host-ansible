#!/usr/bin/env bash
# Apply site.yml to a clean host and prove that the last run changes nothing.
#
#   scripts/test-idempotency.sh [extra ansible-playbook args...]
#   BOOTSTRAP=1 scripts/test-idempotency.sh [extra args...]
#
# Default:      Run 1 = full play as the inventory's ansible_user (first contact),
#               Run 2 = full play as the admin user.
# BOOTSTRAP=1:  Run 0 = --tags bootstrap as the inventory's ansible_user,
#               Run 1 and Run 2 = full play as the admin user.
# Exit status 0 only if every run succeeded and Run 2's PLAY RECAP shows
# changed=0, failed=0 and unreachable=0 for every host.
# Logs: tests/output/run0.log (bootstrap only), run1.log, run2.log (git-ignored).
#
# Environment:
#   ADMIN_USER         user for the runs after first contact
#                      (default: the first entry of base_hardening_admin_users)
#   ASK_BECOME_PASS=1  ask for the sudo password on the first run only (an
#                      installer-created user's sudo usually wants one; the role
#                      gives the admin group passwordless sudo)
#   INVENTORY          default: inventories/lab/hosts.yml
set -euo pipefail

cd "$(dirname "$0")/.."

inventory="${INVENTORY:-inventories/lab/hosts.yml}"
out_dir="tests/output"
mkdir -p "$out_dir"
rm -f "$out_dir"/run0.log "$out_dir"/run1.log "$out_dir"/run2.log

export ANSIBLE_NOCOLOR=1 ANSIBLE_FORCE_COLOR=0

admin_user="${ADMIN_USER:-$(ansible-inventory -i "$inventory" --list | python3 -c '
import json, sys
data = json.load(sys.stdin)
hostvars = data["_meta"]["hostvars"]
names = [u["name"] for h in data.get("kvm_hosts", {}).get("hosts", [])
         for u in hostvars[h].get("base_hardening_admin_users", [])]
print(names[0] if names else "")')}"
if [[ -z "$admin_user" ]]; then
    echo "No admin user found; set ADMIN_USER." >&2
    exit 1
fi

first_run_args=()
if [[ "${ASK_BECOME_PASS:-0}" == 1 ]]; then
    first_run_args=(--ask-become-pass)
fi

# run_playbook <log name> <ansible_user or ""> [ansible-playbook args...]
run_playbook() {
    local name="$1" user="$2"
    shift 2
    local args=(-i "$inventory" site.yml)
    if [[ -n "$user" ]]; then
        args+=(-e "ansible_user=$user")
    fi
    echo "==> $name: ansible-playbook ${args[*]} $*" | tee "$out_dir/$name.log"
    set +e
    ansible-playbook "${args[@]}" "$@" 2>&1 | tee -a "$out_dir/$name.log"
    local rc="${PIPESTATUS[0]}"
    set -e
    if [[ "$rc" -ne 0 ]]; then
        echo "FAIL: $name exited with $rc, see $out_dir/$name.log" >&2
        exit 1
    fi
}

if [[ "${BOOTSTRAP:-0}" == 1 ]]; then
    run_playbook run0 "" --tags bootstrap ${first_run_args[@]+"${first_run_args[@]}"} "$@"
    run_playbook run1 "$admin_user" "$@"
else
    run_playbook run1 "" ${first_run_args[@]+"${first_run_args[@]}"} "$@"
fi
run_playbook run2 "$admin_user" "$@"

# "host changed failed unreachable" for every line of Run 2's PLAY RECAP
recap="$(sed -n '/^PLAY RECAP/,$p' "$out_dir/run2.log" |
    sed -nE 's/^([^ ]+)[[:space:]]*:.*changed=([0-9]+).*unreachable=([0-9]+).*failed=([0-9]+).*/\1 \2 \4 \3/p')"
if [[ -z "$recap" ]]; then
    echo "FAIL: no PLAY RECAP in $out_dir/run2.log" >&2
    exit 1
fi

status=0
echo
echo "Run 2 PLAY RECAP (host changed failed unreachable):"
while read -r host changed failed unreachable; do
    echo "  $host $changed $failed $unreachable"
    if [[ "$changed" != 0 || "$failed" != 0 || "$unreachable" != 0 ]]; then
        status=1
    fi
done <<< "$recap"

if [[ "$status" -ne 0 ]]; then
    echo "FAIL: Run 2 is not clean. Tasks that reported changed:" >&2
    awk '/^TASK \[|^RUNNING HANDLER \[/ {task=$0} /^changed:/ {print "  " task}' "$out_dir/run2.log" | sort -u >&2
    exit 1
fi
echo "PASS: Run 2 reported changed=0 failed=0 unreachable=0 (logs in $out_dir/)"
