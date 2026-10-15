#!/usr/bin/env bash
# Run site.yml twice against inventories/lab (test mode OFF) and check that the
# second run changes nothing.
#
#   scripts/test-idempotency.sh [extra ansible-playbook args...]
#
# Writes tests/output/run1.log and tests/output/run2.log. Exit status is 0 only
# if run 1 succeeded and run 2's PLAY RECAP shows changed=0, failed=0 and
# unreachable=0 for every host.
#
# Environment:
#   RUN1_USER  ansible_user for run 1 (default: the inventory's ansible_user)
#   RUN2_USER  ansible_user for run 2. Set it to an admin user when the
#              first-connection account is not one: after run 1, sshd only
#              admits members of the admin group.
#   INVENTORY  inventory to use (default: inventories/lab/hosts.yml)
set -euo pipefail

cd "$(dirname "$0")/.."

inventory="${INVENTORY:-inventories/lab/hosts.yml}"
out_dir="tests/output"
mkdir -p "$out_dir"

export ANSIBLE_NOCOLOR=1
export ANSIBLE_FORCE_COLOR=0

run_playbook() {
    local number="$1" user="$2"
    shift 2
    local args=(-i "$inventory" site.yml -e kvm_host_test_mode=off)
    if [[ -n "$user" ]]; then
        args+=(-e "ansible_user=$user")
    fi
    echo "==> run $number: ansible-playbook ${args[*]} $*" | tee "$out_dir/run$number.log"
    set +e
    ansible-playbook "${args[@]}" "$@" 2>&1 | tee -a "$out_dir/run$number.log"
    local rc="${PIPESTATUS[0]}"
    set -e
    return "$rc"
}

# Print "host changed failed unreachable" for every PLAY RECAP line of a log.
recap() {
    sed -n '/^PLAY RECAP/,$p' "$1" |
        sed -nE 's/^([^ ]+)[[:space:]]*:.*changed=([0-9]+).*unreachable=([0-9]+).*failed=([0-9]+).*/\1 \2 \4 \3/p'
}

if ! run_playbook 1 "${RUN1_USER:-}" "$@"; then
    echo "FAIL: run 1 failed, see $out_dir/run1.log" >&2
    exit 1
fi

run2_rc=0
run_playbook 2 "${RUN2_USER:-}" "$@" || run2_rc=$?

summary="$(recap "$out_dir/run2.log")"
if [[ -z "$summary" ]]; then
    echo "FAIL: no PLAY RECAP in $out_dir/run2.log (ansible-playbook exit code $run2_rc)" >&2
    exit 1
fi

status=0
echo
echo "Second run (host changed failed unreachable):"
while read -r host changed failed unreachable; do
    echo "  $host $changed $failed $unreachable"
    if [[ "$changed" != 0 || "$failed" != 0 || "$unreachable" != 0 ]]; then
        status=1
    fi
done <<< "$summary"

if [[ "$status" -ne 0 || "$run2_rc" -ne 0 ]]; then
    echo
    echo "FAIL: the second run is not clean. Tasks that reported changed:" >&2
    awk '/^TASK \[/ {task=$0} /^changed:/ {print "  " task}' "$out_dir/run2.log" | sort -u >&2
    exit 1
fi

echo
echo "PASS: second run reported changed=0 failed=0 (logs in $out_dir/)"
