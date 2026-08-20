#!/bin/bash

source "$(dirname "$0")/base-test.sh"

require_command jq
require_command python3

TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

GROK_HOME="$TEST_HOME/.grok"
mkdir -p "$GROK_HOME/sessions/%2Fhome%2Fdev%2Fone/session-a" \
  "$GROK_HOME/sessions/%2Fhome%2Fdev%2Ftwo/session-b" \
  "$TEST_HOME/bin" \
  "$TEST_HOME/empty-bin"

now=$(date +%s)
open_period_start=$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%S+00:00)
open_period_end=$(date -u -d '5 days' +%Y-%m-%dT%H:%M:%S+00:00)
expired_period_start=$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%S+00:00)
expired_period_end=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%S+00:00)

usage_line() {
  local prompt_id="$1" models="$2"
  jq -cn --argjson ts "$now" --arg id "$prompt_id" --argjson models "$models" \
    '{timestamp: $ts, method: "_x.ai/session/update", params: {update: {
      sessionUpdate: "turn_completed", prompt_id: $id, stop_reason: "end_turn",
      usage: {modelUsage: $models}}}}'
}

# Grok reports each completed turn on its own, with cache reads folded into
# inputTokens. Every record on disk also carries cacheCreationTokens, always
# zero so far, so the non-zero one below assumes it nests inside inputTokens
# the way cache reads do — symmetry, not an observed shape. The same
# prompt_id appears twice to stand in for a resumed or replayed transcript. A
# cancelled turn has no usage and is not a prompt.
{
  usage_line p1 '{"grok-4.5-build":{"inputTokens":100,"cachedReadTokens":60,"outputTokens":20,"reasoningTokens":5,"totalTokens":120}}'
  usage_line p1 '{"grok-4.5-build":{"inputTokens":100,"cachedReadTokens":60,"outputTokens":20,"reasoningTokens":5,"totalTokens":120}}'
  usage_line p2 '{"grok-4.5-build":{"inputTokens":80,"cachedReadTokens":50,"cacheCreationTokens":10,"outputTokens":10,"totalTokens":90}}'
  echo '{"timestamp":'"$now"',"method":"_x.ai/session/update","params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"cancelled","stop_reason":"cancelled"}}}'
} >"$GROK_HOME/sessions/%2Fhome%2Fdev%2Fone/session-a/updates.jsonl"

# One turn answered by two models, plus a line the prefilter must skip.
{
  echo '{"timestamp":0,"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":"noise"}}}'
  usage_line p3 '{"grok-4.5-build":{"inputTokens":200,"cachedReadTokens":150,"outputTokens":40,"totalTokens":240},"grok-4.5":{"inputTokens":100,"cachedReadTokens":0,"outputTokens":10,"totalTokens":110}}'
} >"$GROK_HOME/sessions/%2Fhome%2Fdev%2Ftwo/session-b/updates.jsonl"

write_fake_grok() {
  local mode="$1"
  cat >"$TEST_HOME/bin/grok" <<EOF
#!/bin/bash
while read -r request; do
  id=\$(jq -r '.id // empty' <<<"\$request")
  method=\$(jq -r '.method // empty' <<<"\$request")
  [[ -n \$id ]] || continue
  case "\$method" in
    initialize)
      if [[ $mode == noise ]]; then
        echo 'mise tools: grok@1.0.5'
        echo '{"jsonrpc":"2.0","method":"_x.ai/mcp/servers_updated","params":{"mcpServers":[]}}'
      fi
      if jq -e '.params | .protocolVersion == 1 and .clientCapabilities.terminal == false
          and ._meta.clientType == "omarchy-agent-usage"
          and (._meta.clientVersion | type) == "string" and ._meta.clientVersion == "1"
          and ._meta.startupHints.nonInteractive and ._meta.startupHints.skipGitStatus
          and ._meta.startupHints.skipProjectLayout' <<<"\$request" >/dev/null; then
        jq -cn --argjson id "\$id" '{jsonrpc:"2.0",id:\$id,result:{}}'
      else
        jq -cn --argjson id "\$id" '{jsonrpc:"2.0",id:\$id,error:{code:-32602,message:"bad initialize"}}'
      fi
      ;;
    _x.ai/billing)
      if [[ $mode == noise ]]; then
        echo 'not-json'
        echo '{"jsonrpc":"2.0","method":"_x.ai/mcp/servers_updated","params":{}}'
      fi
      if [[ $mode == error ]]; then
        jq -cn --argjson id "\$id" '{jsonrpc:"2.0",id:\$id,error:{code:-32000,message:"Authentication required"}}'
      elif [[ $mode == expired ]]; then
        jq -cn --argjson id "\$id" --arg start "$expired_period_start" --arg end "$expired_period_end" \
          '{jsonrpc:"2.0",id:\$id,result:{config:{creditUsagePercent:22.0,currentPeriod:{type:"USAGE_PERIOD_TYPE_WEEKLY",start:\$start,end:\$end}},subscription_tier:"SuperGrok"}}'
      elif [[ $mode == noise ]]; then
        jq -cn --argjson id "\$id" --arg start "$open_period_start" --arg end "$open_period_end" \
          '{jsonrpc:"2.0",id:\$id,result:{config:{creditUsagePercent:22.0,currentPeriod:{type:"USAGE_PERIOD_TYPE_WEEKLY",start:\$start,end:\$end}},subscriptionTier:"SuperGrok"}}'
      else
        jq -cn --argjson id "\$id" --arg start "$open_period_start" --arg end "$open_period_end" \
          '{jsonrpc:"2.0",id:\$id,result:{config:{creditUsagePercent:22.0,currentPeriod:{type:"USAGE_PERIOD_TYPE_WEEKLY",start:\$start,end:\$end}},subscription_tier:"SuperGrok"}}'
      fi
      ;;
  esac
done
EOF
  chmod +x "$TEST_HOME/bin/grok"
}

run_collector() {
  HOME="$TEST_HOME" GROK_HOME="$GROK_HOME" PATH="$TEST_HOME/bin:$PATH" \
    "$ROOT/bin/omarchy-agent-usage-grok" "$@"
}

write_fake_grok ok
result=$(run_collector)

# 120 + 90 from session-a, 350 from the two-model turn in session-b.
[[ $(jq -r '.todayTotalTokens' <<<"$result") == "560" ]] ||
  fail "Grok collector sums each turn once" "$result"
pass "Grok collector sums each turn once"

[[ $(jq -r '.totalPrompts' <<<"$result") == "3" ]] ||
  fail "Grok collector counts one prompt per turn and ignores repeated prompt ids" "$result"
pass "Grok collector counts one prompt per turn and ignores repeated prompt ids"

[[ $(jq -r '.totalSessions' <<<"$result") == "2" ]] ||
  fail "Grok collector counts sessions by transcript" "$result"
pass "Grok collector counts sessions by transcript"

[[ $(jq -c '.modelUsage["grok-4.5-build"]' <<<"$result") == '{"inputTokens":110,"outputTokens":70,"cacheReadInputTokens":260,"cacheCreationInputTokens":10}' ]] ||
  fail "Grok collector does not double-count cache or reasoning tokens" "$result"
pass "Grok collector does not double-count cache or reasoning tokens"

[[ $(jq -c '.modelUsage["grok-4.5"]' <<<"$result") == '{"inputTokens":100,"outputTokens":10,"cacheReadInputTokens":0,"cacheCreationInputTokens":0}' ]] ||
  fail "Grok collector splits a turn across the models that served it" "$result"
pass "Grok collector splits a turn across the models that served it"

contract='{"schemaVersion":1,"id":"grok","name":"Grok","ready":true,"hasLocalStats":true,"recentDays":7,"usageStatusText":""}'
[[ $(jq -c '{schemaVersion, id, name, ready, hasLocalStats, recentDays: (.recentDays | length), usageStatusText}' <<<"$result") == "$contract" ]] ||
  fail "Grok collector prints the display-ready record contract" "$result"
pass "Grok collector prints the display-ready record contract"

[[ $(jq -c '.limits' <<<"$result") == '[{"label":"Weekly (7-day)","percent":0.22,"resetsAt":"'"$open_period_end"'"}]' ]] &&
  [[ $(jq -r '.tierLabel' <<<"$result") == "SuperGrok" ]] ||
  fail "Grok collector reads the weekly credit allowance from ACP billing" "$result"
pass "Grok collector reads the weekly credit allowance from ACP billing"

write_fake_grok expired
expired=$(run_collector)

[[ $(jq -r '.limits | length' <<<"$expired") == "0" ]] ||
  fail "Grok collector drops a credit reading from a period that has ended" "$expired"
pass "Grok collector drops a credit reading from a period that has ended"

write_fake_grok noise
noisy=$(run_collector)

[[ $(jq -c '.limits' <<<"$noisy") == '[{"label":"Weekly (7-day)","percent":0.22,"resetsAt":"'"$open_period_end"'"}]' ]] &&
  [[ $(jq -r '.tierLabel' <<<"$noisy") == "SuperGrok" ]] ||
  fail "Grok collector ignores non-JSON stdout and unrelated ACP notifications" "$noisy"
pass "Grok collector ignores non-JSON stdout and unrelated ACP notifications"

write_fake_grok error
errored=$(run_collector)

[[ $(jq -r '.limits | length' <<<"$errored") == "0" ]] &&
  [[ $(jq -r '.totalPrompts' <<<"$errored") == "3" ]] &&
  [[ $(jq -r '.usageStatusText' <<<"$errored") == "Grok limits unavailable" ]] ||
  fail "Grok collector keeps local stats when ACP billing returns an error" "$errored"
pass "Grok collector keeps local stats when ACP billing returns an error"

missing=$(HOME="$TEST_HOME" GROK_HOME="$GROK_HOME" PATH="$TEST_HOME/empty-bin" \
  "$ROOT/bin/omarchy-agent-usage-grok")

[[ $(jq -r '.limits | length' <<<"$missing") == "0" ]] &&
  [[ $(jq -r '.totalPrompts' <<<"$missing") == "3" ]] &&
  [[ $(jq -r '.usageStatusText' <<<"$missing") == "Grok limits unavailable" ]] ||
  fail "Grok collector still reports tokens when grok is absent" "$missing"
pass "Grok collector still reports tokens when grok is absent"

# A turn from yesterday must not inflate today. local_day is easy to get
# wrong around UTC midnight — this machine's sessions stamp unix seconds.
mkdir -p "$GROK_HOME/sessions/%2Fhome%2Fdev%2Fthree/session-c"
yesterday=$(date -d 'yesterday 15:00:00' +%s)
yesterday_date=$(date -d 'yesterday 15:00:00' +%Y-%m-%d)
jq -cn --argjson ts "$yesterday" \
  '{timestamp: $ts, method: "_x.ai/session/update", params: {update: {
    sessionUpdate: "turn_completed", prompt_id: "old", stop_reason: "end_turn",
    usage: {modelUsage: {"grok-4.5-build":{"inputTokens":30,"outputTokens":10,"totalTokens":40}}}}}}' \
  >"$GROK_HOME/sessions/%2Fhome%2Fdev%2Fthree/session-c/updates.jsonl"
write_fake_grok ok
dated=$(run_collector)

[[ $(jq -r '.todayPrompts' <<<"$dated") == "3" ]] &&
  [[ $(jq -r '.todayTotalTokens' <<<"$dated") == "560" ]] &&
  [[ $(jq -r --arg day "$yesterday_date" '.recentDays[] | select(.date == $day) | .messageCount' <<<"$dated") == "40" ]] ||
  fail "Grok collector files a turn on the local day it happened" "$dated"
pass "Grok collector files a turn on the local day it happened"

# Interrupting a prompt and running it again reuses the prompt id, and the
# turn that spent the tokens is the second one. The cancelled record carries
# no usage key, so the prefilter is what drops it here.
mkdir -p "$GROK_HOME/sessions/%2Fhome%2Fdev%2Ffour/session-d"
{
  echo '{"timestamp":'"$now"',"method":"_x.ai/session/update","params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"p4","stop_reason":"cancelled"}}}'
  usage_line p4 '{"grok-4.5-build":{"inputTokens":30,"cachedReadTokens":0,"outputTokens":10,"totalTokens":40}}'
} >"$GROK_HOME/sessions/%2Fhome%2Fdev%2Ffour/session-d/updates.jsonl"
retried=$(run_collector)

[[ $(jq -r '.todayTotalTokens' <<<"$retried") == "600" ]] &&
  [[ $(jq -r '.todayPrompts' <<<"$retried") == "4" ]] ||
  fail "Grok collector counts a retried turn whose cancelled attempt shared its id" "$retried"
pass "Grok collector counts a retried turn whose cancelled attempt shared its id"

# No sessions and no grok is a machine that has never signed in: a full record
# the update runner can write, with nothing in it for the panel to show.
empty=$(GROK_HOME="$TEST_HOME/.grok-empty" HOME="$TEST_HOME" PATH="$TEST_HOME/empty-bin" \
  "$ROOT/bin/omarchy-agent-usage-grok")

[[ $(jq -r '.id + ":" + (.ready | tostring) + ":" + (.totalPrompts | tostring)' <<<"$empty") == "grok:false:0" ]] ||
  fail "Grok collector prints a valid record with nothing installed" "$empty"
pass "Grok collector prints a valid record with nothing installed"
