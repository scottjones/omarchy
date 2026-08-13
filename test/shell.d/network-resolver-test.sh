#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Everything the command touches is stubbed: nmcli and ip for topology, curl for
# link reachability, and python3 because that is how the DNS probe sends its
# query -- the one thing a live network cannot be asked to fail on demand.
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

cat >"$stub_dir/ip" <<'STUB'
#!/bin/bash
[[ $* == *"route show default"* ]] && printf '%s\n' "${STUB_DEFAULT_ROUTE:-}"
STUB

cat >"$stub_dir/nmcli" <<'STUB'
#!/bin/bash
case "$*" in
  *"GENERAL.TYPE device show"*) echo "${STUB_DEV_TYPE:-wifi}" ;;
  *"IP4.DNS device show"*) printf '%s\n' "${STUB_DNS:-}" ;;
  *"GENERAL.CONNECTION device show"*) echo "${STUB_PROFILE:-@Hyatt_Wifi}" ;;
  *"connection modify"*) printf '%s\n' "$*" >>"$STUB_NMCLI_LOG" ;;
  *"device reapply"*) printf 'reapply\n' >>"$STUB_NMCLI_LOG"; exit "${STUB_REAPPLY_EXIT:-0}" ;;
  *"device disconnect"*) printf 'disconnect\n' >>"$STUB_NMCLI_LOG" ;;
  *"device connect"*) printf 'connect\n' >>"$STUB_NMCLI_LOG" ;;
  monitor) printf 'wlan0: update\nwlan0: update\n' ;;
esac
STUB

# STUB_RESOLVER_ANSWERS=no makes every resolver a black hole.
cat >"$stub_dir/python3" <<'STUB'
#!/bin/bash
cat >/dev/null
[[ ${STUB_RESOLVER_ANSWERS:-yes} == "yes" ]]
STUB

cat >"$stub_dir/curl" <<'STUB'
#!/bin/bash
[[ ${STUB_LINK_CARRIES:-yes} == "yes" ]]
STUB

cat >"$stub_dir/omarchy-network-portal" <<'STUB'
#!/bin/bash
[[ $1 == "--check" ]] && [[ ${STUB_PORTAL:-no} == "yes" ]]
STUB

cat >"$stub_dir/omarchy-notification-wait" <<'STUB'
#!/bin/bash
exit 0
STUB

cat >"$stub_dir/omarchy-notification-send" <<'STUB'
#!/bin/bash
printf '%s\n' "${*: -2:1}" >>"$STUB_NOTIFY_LOG"
STUB

chmod +x "$stub_dir"/*

export STUB_NMCLI_LOG="$stub_dir/nmcli.log"
export STUB_NOTIFY_LOG="$stub_dir/notify.log"
: >"$STUB_NMCLI_LOG"
: >"$STUB_NOTIFY_LOG"

resolver="$ROOT/bin/omarchy-network-resolver"

run_resolver() {
  PATH="$stub_dir:$PATH" OMARCHY_RESOLVER_STATE_FILE="$stub_dir/announced" \
    OMARCHY_RESOLVER_DEBOUNCE_SECONDS=0 OMARCHY_RESOLVER_TICK_SECONDS=1 \
    timeout 20 "$resolver" ${1:+"$1"}
}

# Every case starts from the failing topology and changes exactly one thing.
# Reset explicitly rather than with a command prefix: `VAR=x status=$(...)` is two
# assignments, not a prefixed command, so it leaks into every later case and can
# make an assertion pass for a reason it never tested.
reset_stubs() {
  export STUB_DEFAULT_ROUTE='default via 172.20.0.1 dev wlan0 proto dhcp src 172.20.3.184 metric 600'
  export STUB_DNS='172.20.0.1'
  export STUB_DEV_TYPE=wifi
  export STUB_RESOLVER_ANSWERS=no
  export STUB_LINK_CARRIES=yes
  export STUB_PORTAL=no
  export STUB_PROFILE='@Hyatt_Wifi'
  export STUB_REAPPLY_EXIT=0
}

# Tonight's failure, exactly: the hotel's DHCP hands out one resolver that
# silently drops queries, while the link itself carries traffic perfectly.
reset_stubs
status=$(run_resolver)
[[ $status == *"state	dead"* ]] || fail "reports a resolver that never answers" "$status"
[[ $status == *"device	wlan0"* ]] || fail "names the device with the dead resolver" "$status"
[[ $status == *"servers	172.20.0.1"* ]] || fail "reports which servers were tried" "$status"
pass "a DHCP resolver that drops queries is reported while the link still works"

if ! run_resolver --check >/dev/null; then
  fail "--check exits 0 when a resolver is dead"
fi
pass "--check exits 0 when a resolver is dead"

# An outage is not a resolver problem, and telling someone whose Wi-Fi dropped
# that DNS is broken sends them the wrong way.
reset_stubs; export STUB_LINK_CARRIES=no
status=$(run_resolver)
[[ $status == *"state	ok"* ]] || fail "does not blame DNS when the link carries nothing" "$status"
pass "a link carrying no traffic is an outage, not a dead resolver"

# Before sign-in a portal hijacks DNS on purpose, and the portal command is
# already prompting. Two toasts for one network is worse than one.
reset_stubs; export STUB_PORTAL=yes
status=$(run_resolver)
[[ $status == *"state	ok"* ]] || fail "stays quiet behind a captive portal" "$status"
pass "a captive portal suppresses the resolver warning"

reset_stubs; export STUB_RESOLVER_ANSWERS=yes
status=$(run_resolver)
[[ $status == *"state	ok"* ]] || fail "says nothing when the resolver answers" "$status"
pass "a working resolver reports ok"

# A tunnel's resolver is domain-scoped; treating one as the machine's resolver
# would fire on every Tailscale or VPN session.
reset_stubs; export STUB_DEV_TYPE=tun
status=$(run_resolver)
[[ $status == *"state	ok"* ]] || fail "ignores a tunnel owning the default route" "$status"
pass "a tunnel default route is not treated as a dead resolver"

# No resolver at all is systemd-resolved's fallback territory, not a fault.
reset_stubs; export STUB_DNS=''
status=$(run_resolver)
[[ $status == *"state	ok"* ]] || fail "ignores a link with no resolver configured" "$status"
pass "a link with no resolver is left to the fallback servers"

echo
reset_stubs
: >"$STUB_NMCLI_LOG"
run_resolver --fix >/dev/null
grep -q 'connection modify @Hyatt_Wifi' "$STUB_NMCLI_LOG" || fail "--fix pins the connection" "$(cat "$STUB_NMCLI_LOG")"
grep -q 'ignore-auto-dns yes' "$STUB_NMCLI_LOG" || fail "--fix stops trusting the DHCP resolver" "$(cat "$STUB_NMCLI_LOG")"
grep -q '1.1.1.1,9.9.9.9' "$STUB_NMCLI_LOG" || fail "--fix sets public resolvers" "$(cat "$STUB_NMCLI_LOG")"
pass "--fix pins the connection to public resolvers"

# `nmcli connection up` needs an interactive secret agent and fails without one,
# so a bounce through stored secrets is the fallback when reapply cannot run.
reset_stubs; export STUB_REAPPLY_EXIT=1
: >"$STUB_NMCLI_LOG"
run_resolver --fix >/dev/null
grep -q '^disconnect$' "$STUB_NMCLI_LOG" && grep -q '^connect$' "$STUB_NMCLI_LOG" ||
  fail "--fix bounces the device when reapply fails" "$(cat "$STUB_NMCLI_LOG")"
pass "--fix falls back to a device bounce when reapply is refused"

# resolvectl would be the obvious way to push DNS and is deliberately unused:
# runtime overrides outrank NetworkManager and cannot be reverted while resolved
# is timing out against the dead server. Comments are stripped first, since the
# file names resolvectl precisely to say it is not used.
if grep -vE '^[[:space:]]*#' "$ROOT/bin/omarchy-network-resolver" | grep -q 'resolvectl'; then
  fail "--fix must not push DNS through resolvectl runtime overrides"
fi
pass "the fix goes through NetworkManager, not resolvectl runtime overrides"

echo
reset_stubs
rm -f "$stub_dir/announced"
: >"$STUB_NOTIFY_LOG"
run_resolver --watch >/dev/null 2>&1 || true
[[ $(wc -l <"$STUB_NOTIFY_LOG" | tr -d ' ') == 1 ]] || fail "announces once across a burst" "$(cat "$STUB_NOTIFY_LOG")"
[[ $(cat "$STUB_NOTIFY_LOG") == "No DNS on @Hyatt_Wifi" ]] || fail "names the network in the toast" "$(cat "$STUB_NOTIFY_LOG")"
pass "a burst of events yields one toast naming the network"

: >"$STUB_NOTIFY_LOG"
run_resolver --watch >/dev/null 2>&1 || true
[[ $(wc -l <"$STUB_NOTIFY_LOG" | tr -d ' ') == 0 ]] || fail "does not re-announce after a restart" "$(cat "$STUB_NOTIFY_LOG")"
pass "a restarted watcher does not stack a duplicate toast"
