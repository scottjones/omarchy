#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const network = requireFromRoot('shell/plugins/panels/network/Model.js')
const panelSource = fs.readFileSync(root + '/shell/plugins/panels/network/Panel.qml', 'utf8')

const portalStatus = 'state\tportal\ndevice\twlan0\nlabel\t@Hyatt_Wifi\n'

assertDeepEqual(
  network.parsePortalStatus(portalStatus),
  { detected: true, device: 'wlan0', label: '@Hyatt_Wifi' },
  'parsePortalStatus reads the device and label off a portal report'
)

assertEqual(
  network.parsePortalStatus('state\tnone\n').detected,
  false,
  'parsePortalStatus treats an explicit "none" as no portal'
)

// The command always prints a state, so an empty read is a poll that has not
// answered yet. Guessing "portal" there would flash the sign-in notice on every
// panel open.
assertEqual(
  network.parsePortalStatus('').detected,
  false,
  'parsePortalStatus does not claim a portal from an empty read'
)

assertEqual(
  network.connectionIcon('wifi', 100, true),
  '\u{f059f}',
  'connectionIcon shows the web glyph behind a portal'
)

// A portal leaves the radio at full strength, so the bars have to lose to it.
assertEqual(
  network.connectionIcon('wifi', 100, true) === network.connectionIcon('wifi', 100, false),
  false,
  'connectionIcon does not fall back to signal bars when a portal is detected'
)

assertEqual(
  network.connectionIcon('ethernet', -1, true),
  '\u{f059f}',
  'connectionIcon shows the portal glyph on ethernet too'
)

assertEqual(
  network.connectionIcon('wifi', 100),
  '\u{f0928}',
  'connectionIcon keeps its two-argument behaviour'
)

// The bar pill is the only portal signal a user gets without opening anything,
// so this poll deliberately does not stop with the panel.
const portalPoll = panelSource.match(/id: portalPoll[\s\S]*?onTriggered: root\.pollPortal\(\)/)
assert(portalPoll, 'network has a portal poll timer')
assert(/running: true/.test(portalPoll[0]), 'network keeps polling for a portal while its panel is closed')

assert(
  /Model\.connectionIcon\(kind, signalStrength, portalDetected\)/.test(panelSource),
  'network feeds portal state into the bar icon'
)

// The hero meta line carries "SIGN-IN REQUIRED", and the idle phrase cycler
// fades that same element, so leaving it running would blink the notice.
const phraseTimer = panelSource.match(/id: connectionPhraseTimer[\s\S]*?onTriggered: connectionPhraseSwap\.restart\(\)/)
assert(phraseTimer, 'network has the connection phrase timer')
assert(/!root\.portalDetected/.test(phraseTimer[0]), 'network stops cycling idle phrases while a portal notice is showing')
assert(
  /function onPortalDetectedChanged\(\)[\s\S]*?heroMeta\.opacity = 1\.0/.test(panelSource),
  'network restores the meta line opacity when a portal is spotted mid-fade'
)

assert(
  /if \(headerIndex === portalHeaderIndex\) signInToPortal\(\)/.test(panelSource),
  'network activates the portal sign-in from the keyboard'
)

// The hero names whichever interface owns the default route. With a tether up
// that is the working link, so an unqualified notice would accuse the connection
// that is carrying traffic of needing a sign-in.
const elsewhere = panelSource.match(/readonly property bool portalIsElsewhere:[\s\S]*?\n\n/)
assert(elsewhere, 'network tracks whether the portal is on another interface')
assert(
  /portalDevice !== \(info\.iface \|\| ""\)/.test(elsewhere[0]),
  'network compares the portal device against the interface the hero describes'
)
assert(
  /if \(root\.portalIsElsewhere\) return "SIGN-IN REQUIRED: " \+ root\.portalLabel\.toUpperCase\(\)/.test(panelSource),
  'network names the intercepted network when it is not the one the hero describes'
)
assert(
  /tooltipText: root\.portalLabel !== "" \? "Sign in to " \+ root\.portalLabel/.test(panelSource),
  'network names the intercepted network in the sign-in tooltip'
)

// updatePortal has to keep the device, or portalIsElsewhere can never be true.
const updatePortal = panelSource.match(/function updatePortal\(raw\) \{[\s\S]*?\n {2}\}/)
assert(updatePortal, 'network has an updatePortal function')
assert(/portalDevice = status\.device/.test(updatePortal[0]), 'network records which device is intercepted')

// Every other hero action has to shift over once sign-in takes the lead, or two
// actions answer to the same cursor index.
const headerCount = panelSource.match(/readonly property int headerActionCount:.*/)
assert(headerCount, 'network declares a hero action count')
assert(
  /canSignInToPortal \? 1 : 0/.test(headerCount[0]),
  'network counts the portal action among the hero actions'
)
for (const name of ['qrHeaderIndex', 'speedHeaderIndex', 'toggleHeaderIndex']) {
  const declaration = panelSource.match(new RegExp('readonly property int ' + name + ':.*'))
  assert(declaration, `network declares ${name}`)
  assert(
    /canSignInToPortal \? 1 : 0/.test(declaration[0]),
    `network offsets ${name} for the portal action`
  )
}

// Sending the URL as argv keeps a portal query string away from a shell.
assert(
  /Quickshell\.execDetached\(\["omarchy-network-portal", "--open"\]\)/.test(panelSource),
  'network opens the portal through the command rather than building a URL itself'
)
JS

# The command talks to nmcli, busctl and curl, so the stubs below stand in for
# all three. That makes the interesting cases -- which the live network cannot be
# put into on demand -- reachable from the suite.
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

cat >"$stub_dir/busctl" <<'STUB'
#!/bin/bash
case "$*" in
  *ConnectivityCheckAvailable*) echo "b ${STUB_CHECK_AVAILABLE:-true}" ;;
  *ConnectivityCheckEnabled*) echo "b ${STUB_CHECK_ENABLED:-true}" ;;
  *ConnectivityCheckUri*) echo 's "http://check.invalid/nm-check.txt"' ;;
esac
STUB

# Answers the aggregate connectivity question with "full" on purpose: reading it
# is the mistake this whole command exists to avoid, so anything that consults it
# should come out of the suite looking online.
cat >"$stub_dir/nmcli" <<'STUB'
#!/bin/bash
case "$*" in
  *"DEVICE,TYPE,STATE,IP4-CONNECTIVITY device status"*) printf '%s\n' "$STUB_DEVICES" ;;
  *"GENERAL.CONNECTION device show"*) echo "${STUB_LABEL:-Some Network}" ;;
  *"IP4.GATEWAY device show"*) echo "${STUB_GATEWAY:-}" ;;
  *"networking connectivity"*) echo "full" ;;
esac
STUB

# Counts probes as well as answering them: a portal NetworkManager already
# identified must cost none at all.
cat >"$stub_dir/curl" <<'STUB'
#!/bin/bash
echo probe >>"$STUB_PROBE_LOG"
[[ -n ${STUB_RESPONSE:-} ]] || exit 7
printf '%s' "$STUB_RESPONSE"
STUB

cat >"$stub_dir/omarchy-launch-browser" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" >>"$STUB_BROWSER_LOG"
STUB

chmod +x "$stub_dir"/*

export STUB_PROBE_LOG="$stub_dir/probes"
export STUB_BROWSER_LOG="$stub_dir/browser"
: >"$STUB_PROBE_LOG"
: >"$STUB_BROWSER_LOG"

portal="$ROOT/bin/omarchy-network-portal"

run_portal() {
  local mode=${1:-}
  : >"$STUB_PROBE_LOG"
  if [[ -n $mode ]]; then
    PATH="$stub_dir:$PATH" "$portal" "$mode"
  else
    PATH="$stub_dir:$PATH" "$portal"
  fi
}

probe_count() {
  wc -l <"$STUB_PROBE_LOG" | tr -d ' '
}

# The case that matters most: a phone tether at "full" makes NetworkManager's
# aggregate connectivity read "full" while the Wi-Fi behind it is intercepted.
# Reading the manager-level property instead of the per-device one reports this
# machine as online.
export STUB_DEVICES='enu1:ethernet:connected:full
wlan0:wifi:connected:portal
tailscale0:tun:connected (externally):limited
docker0:bridge:connected (externally):none'
export STUB_LABEL='@Hyatt_Wifi'
export STUB_GATEWAY='172.20.0.1'
unset STUB_RESPONSE

status=$(run_portal)
[[ $status == *"state	portal"* ]] || fail "reports a portal when a full-connectivity device masks it" "$status"
[[ $status == *"device	wlan0"* ]] || fail "names the intercepted device, not the one with a working route" "$status"
[[ $status == *"label	@Hyatt_Wifi"* ]] || fail "reports the intercepted connection's name" "$status"
pass "portal status survives a tether that reports full connectivity"

run_portal >/dev/null
[[ $(probe_count) == 0 ]] || fail "settles a known portal without probing" "probes: $(probe_count)"
pass "a device NetworkManager already calls portal costs no probe"

# Ordering, asserted by cost. The limited device is listed first and is a real
# ethernet link, so it survives the type filter -- only sorting the known portal
# ahead of it keeps its probe from being paid for on every poll.
export STUB_DEVICES='enu1:ethernet:connected:limited
wlan0:wifi:connected:portal'
status=$(run_portal)
[[ $status == *"device	wlan0"* ]] || fail "prefers the known portal over a merely limited device" "$status"
[[ $(probe_count) == 0 ]] || fail "does not probe a limited device when a known portal is available" "probes: $(probe_count)"
pass "a known portal is settled before a limited device costs a probe"

export STUB_DEVICES='enu1:ethernet:connected:full
wlan0:wifi:connected:portal
tailscale0:tun:connected (externally):limited
docker0:bridge:connected (externally):none'

if ! run_portal --check >/dev/null; then
  fail "--check exits 0 while a portal is present"
fi
pass "--check exits 0 while a portal is present"

# Tunnels and bridges sit at limited or none indefinitely, so they must never be
# probed or reported.
export STUB_DEVICES='tailscale0:tun:connected (externally):limited
docker0:bridge:connected (externally):none
lo:loopback:connected (externally):unknown'
status=$(run_portal)
[[ $status == *"state	none"* ]] || fail "ignores tunnels, bridges and loopback" "$status"
[[ $(probe_count) == 0 ]] || fail "never probes a tunnel or bridge" "probes: $(probe_count)"
pass "non-physical devices are neither probed nor reported"

if run_portal --check >/dev/null; then
  fail "--check exits non-zero with no portal"
fi
pass "--check exits non-zero with no portal"

# A "limited" device is only a portal once a probe sees an interception. A router
# serving its own page, or a plainly broken uplink, must not be called one.
export STUB_DEVICES='wlan0:wifi:connected:limited'
export STUB_RESPONSE='HTTP/1.1 200 OK
Content-Type: text/html

<html><body>Router admin</body></html>'
status=$(run_portal)
[[ $status == *"state	none"* ]] || fail "does not call a limited device a portal without an interception" "$status"
pass "a limited device serving an ordinary page is not a portal"

# Pinned DNS keeps NetworkManager's check from resolving, so an intercepted
# network lands at "limited" rather than "portal". The redirect is what proves it.
export STUB_RESPONSE='HTTP/1.0 302 RD
Location: https://splash.skyadmin.io?UI=0a95dc

'
status=$(run_portal)
[[ $status == *"state	portal"* ]] || fail "confirms a limited device that redirects" "$status"
pass "a limited device that redirects is reported as a portal"

url=$(run_portal --url)
[[ $url == "https://splash.skyadmin.io?UI=0a95dc" ]] || fail "--url returns the splash page from the redirect" "$url"
pass "--url returns the splash page a redirect points at"

# WISPr proves an interception, but its LoginURL is a form endpoint rather than a
# page worth opening, so the browser must not be sent there.
export STUB_RESPONSE='HTTP/1.1 200 OK

<WISPAccessGatewayParam><Redirect><LoginURL>https://ssl.certificate.com:1112/usg/process</LoginURL></Redirect></WISPAccessGatewayParam>'
status=$(run_portal)
[[ $status == *"state	portal"* ]] || fail "treats a WISPr payload as an interception" "$status"
url=$(run_portal --url)
[[ $url != *"ssl.certificate.com"* ]] || fail "--url must not hand the WISPr form endpoint to a browser" "$url"
[[ $url == "http://172.20.0.1" ]] || fail "--url falls back to the gateway when nothing redirects" "$url"
pass "a WISPr payload counts as a portal without becoming the browser target"

: >"$STUB_BROWSER_LOG"
run_portal --open >/dev/null
[[ $(cat "$STUB_BROWSER_LOG") == "http://172.20.0.1" ]] || fail "--open hands the resolved URL to the default browser" "$(cat "$STUB_BROWSER_LOG")"
pass "--open opens the resolved URL in the default browser"

# Without NetworkManager's connectivity check there is no portal signal to read,
# so the command has to stay quiet rather than probe every device itself.
export STUB_DEVICES='wlan0:wifi:connected:portal'
STUB_CHECK_ENABLED=false status=$(STUB_CHECK_ENABLED=false run_portal)
[[ $status == *"state	none"* ]] || fail "stays quiet when connectivity checking is disabled" "$status"
pass "a disabled connectivity check reports no portal"

STUB_CHECK_AVAILABLE=false status=$(STUB_CHECK_AVAILABLE=false run_portal)
[[ $status == *"state	none"* ]] || fail "stays quiet when connectivity checking is unavailable" "$status"
pass "an unavailable connectivity check reports no portal"

# --watch, driven by a finite stand-in for `nmcli monitor`. The toasts are
# critical, so they stay on screen until dealt with and every duplicate stacks
# visibly -- worth pinning without depending on a live desktop.
cat >"$stub_dir/omarchy-notification-wait" <<'STUB'
#!/bin/bash
exit 0
STUB

cat >"$stub_dir/omarchy-notification-send" <<'STUB'
#!/bin/bash
printf '%s\n' "${*: -2:1}" >>"$STUB_NOTIFY_LOG"
STUB

# The monitor stand-in emits several lines and exits, which ends the watch loop
# the same way a NetworkManager restart would.
cat >"$stub_dir/nmcli" <<'STUB'
#!/bin/bash
case "$*" in
  monitor) printf 'wlan0: connected\nwlan0: connectivity is now portal\nwlan0: update\n' ;;
  *"DEVICE,TYPE,STATE,IP4-CONNECTIVITY device status"*) printf '%s\n' "$STUB_DEVICES" ;;
  *"GENERAL.CONNECTION device show"*) echo "${STUB_LABEL:-Some Network}" ;;
  *"IP4.GATEWAY device show"*) echo "${STUB_GATEWAY:-}" ;;
  *"networking connectivity"*) echo "full" ;;
esac
STUB
chmod +x "$stub_dir"/omarchy-notification-wait "$stub_dir"/omarchy-notification-send "$stub_dir"/nmcli

export STUB_NOTIFY_LOG="$stub_dir/notifications"
announced_state="$stub_dir/announced"

run_watch() {
  : >"$STUB_NOTIFY_LOG"
  OMARCHY_PORTAL_DEBOUNCE_SECONDS=0 OMARCHY_PORTAL_TICK_SECONDS=1 \
    OMARCHY_PORTAL_STATE_FILE="$announced_state" \
    PATH="$stub_dir:$PATH" timeout 10 "$portal" --watch >/dev/null 2>&1 || true
}

notify_count() {
  wc -l <"$STUB_NOTIFY_LOG" | tr -d ' '
}

export STUB_DEVICES='enu1:ethernet:connected:full
wlan0:wifi:connected:portal'
rm -f "$announced_state"

run_watch
[[ $(notify_count) == 1 ]] || fail "announces a portal once across a burst of events" "notifications: $(notify_count)"
[[ $(cat "$STUB_NOTIFY_LOG") == "Sign in to @Hyatt_Wifi" ]] || fail "names the network in the toast" "$(cat "$STUB_NOTIFY_LOG")"
pass "a burst of connectivity events yields one toast"

# A restarted watcher -- systemd sets Restart=always, and the loop ends whenever
# NetworkManager goes away -- must not toast the same portal again.
run_watch
[[ $(notify_count) == 0 ]] || fail "does not re-announce the same portal after a restart" "notifications: $(notify_count)"
pass "a restarted watcher does not stack a duplicate toast"

# Signing in clears the state, so the next portal is announced again.
export STUB_DEVICES='enu1:ethernet:connected:full'
run_watch
[[ $(notify_count) == 0 ]] || fail "says nothing once the portal is gone" "notifications: $(notify_count)"
[[ -e $announced_state ]] && fail "clears the announced marker once the portal is gone"
pass "a cleared portal forgets what it announced"

export STUB_DEVICES='enu1:ethernet:connected:full
wlan0:wifi:connected:portal'
run_watch
[[ $(notify_count) == 1 ]] || fail "announces again after rejoining a portal network" "notifications: $(notify_count)"
pass "rejoining a portal network announces it again"
