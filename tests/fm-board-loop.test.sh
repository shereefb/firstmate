#!/usr/bin/env bash
# tests/fm-board-loop.test.sh - behavior tests for the Operating Studio board
# loop's detect/investigate/recover/verify command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-board-loop.sh"
TMP_ROOT=$(fm_test_tmproot fm-board-loop)

# make_world <name>: one isolated home with a fakebin boundary for Herdr
# activity, endpoint liveness, the forge PR probe, and the durable send.
make_world() { # <name>
  local name=$1 world
  world="$TMP_ROOT/$name"
  rm -rf "$world"
  mkdir -p "$world/home/state" "$world/home/data" "$world/fakebin"
  cat > "$world/fakebin/agent" <<'SH'
#!/usr/bin/env bash
printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "${FM_TEST_AGENT_STATUS:-working}"
SH
  cat > "$world/fakebin/endpoint" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_ENDPOINT_STATUS:-alive}"
SH
  cat > "$world/fakebin/pr" <<'SH'
#!/usr/bin/env bash
case "$1" in
  *merged*) printf '{"state":"MERGED","isDraft":false,"headRefOid":"%s"}\n' "${FM_TEST_MERGED_HEAD:-deadbeef}" ;;
  *draft*) printf '{"state":"OPEN","isDraft":true,"headRefOid":"%s"}\n' "${FM_TEST_OPEN_HEAD:-head1}" ;;
  *drift*) printf '{"state":"OPEN","isDraft":false,"headRefOid":"%s"}\n' "${FM_TEST_DRIFT_HEAD:-newhead}" ;;
  *closed*) printf '{"state":"CLOSED","isDraft":false,"headRefOid":"%s"}\n' "${FM_TEST_OPEN_HEAD:-head1}" ;;
  *) printf '{"state":"OPEN","isDraft":false,"headRefOid":"%s"}\n' "${FM_TEST_OPEN_HEAD:-head1}" ;;
esac
SH
  cat > "$world/fakebin/crew" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: test\n' "${FM_TEST_CREW_STATE:-working}"
SH
  cat > "$world/fakebin/curl" <<'SH'
#!/usr/bin/env bash
payload=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --data ]; then shift; payload=$1; break; fi
  shift
done
if printf '%s' "$payload" | jq -e '.query | contains("workflowStates")' >/dev/null 2>&1; then
  printf '{"data":{"workflowStates":{"nodes":[{"id":"state-review","name":"In Review"},{"id":"state-deploy","name":"Ready to Deploy"}]}}}\n'
  exit 0
fi
issue=$(printf '%s' "$payload" | jq -r '.variables.issue')
if printf '%s' "$payload" | jq -e '.query | startswith("query Issue")' >/dev/null 2>&1; then
  state=$(cat "${FM_TEST_LINEAR_STATE_FILE:?}")
  printf '{"data":{"issue":{"id":"%s","state":{"name":"%s"}}}}\n' "$issue" "$state"
  exit 0
fi
state_id=$(printf '%s' "$payload" | jq -r '.variables.state')
case "$state_id" in state-review) state='In Review' ;; state-deploy) state='Ready to Deploy' ;; *) exit 1 ;; esac
printf '%s\n' "$state" > "${FM_TEST_LINEAR_STATE_FILE:?}"
printf '{"data":{"issueUpdate":{"success":true,"issue":{"id":"%s","state":{"name":"%s"}}}}}\n' "$issue" "$state"
SH
  cat > "$world/fakebin/send" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_TEST_SEND_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$world/fakebin/"*
  printf '%s\n' "$world"
}

run_scan() { # <world> <now> [args...]
  local world=$1 now=$2
  shift 2
  FM_HOME="$world/home" FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_BOARD_LOOP_NOW="$now" FM_BOARD_LOOP_CREW_STATE_CMD="${FM_TEST_CREW_STATE_CMD-}" \
    FM_BOARD_LOOP_HERDR_CLI="$world/fakebin/agent" \
    FM_BOARD_LOOP_ENDPOINT_STATUS_CMD="$world/fakebin/endpoint" \
    FM_BOARD_LOOP_PR_PROBE_CMD="${FM_TEST_PR_PROBE_CMD-$world/fakebin/pr}" \
    FM_BOARD_LOOP_SEND_CMD="$world/fakebin/send" \
    "$SCRIPT" "$@"
}

write_cards() { # <file> <json-array>
  printf '%s\n' "$2" > "$1"
}

# --- cases -------------------------------------------------------------------

test_stop_posture_refuses_recovery() {
  # An explicit durable stop posture must refuse ANY recovery steer, even with a
  # live endpoint, until an explicit resume.
  local world log out
  world=$(make_world stop-posture)
  fm_write_meta "$world/home/state/child.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:1" "linear_card_id=card-D"
  printf '%s\n' 'needs-decision [at=999] [key=gate-3]: choose a path' \
    > "$world/home/state/child.status"
  write_cards "$world/cards.json" \
    '[{"id":"card-D","identifier":"COD-D","state":"In Progress","title":"d","url":"u"}]'
  log="$world/send.log"
  : > "$log"
  run_scan "$world" 1000 pause --reason 'captain stop' >/dev/null
  assert_present "$world/home/state/.board-loop-pause" "pause marker exists"
  FM_TEST_SEND_LOG="$log" run_scan "$world" 1000 recover --cards "$world/cards.json" >/dev/null 2>&1
  assert_equals "0" "$(wc -l < "$log" | tr -d '[:space:]')" \
    "a paused fleet sends no recovery steer"
  out=$(run_scan "$world" 1000 --cards "$world/cards.json")
  assert_equals "true" "$(printf '%s' "$out" | jq -r '.paused')" \
    "scan still reports the paused posture read-only"
  run_scan "$world" 1000 resume >/dev/null
  assert_absent "$world/home/state/.board-loop-pause" "resume removes the marker"
  FM_TEST_SEND_LOG="$log" run_scan "$world" 1000 recover --cards "$world/cards.json" >/dev/null 2>&1
  assert_equals "1" "$(wc -l < "$log" | tr -d '[:space:]')" \
    "resume re-enables exactly one recovery steer"
  pass "stop-posture-refuses-recovery"
}

test_stop_status_signal_gates_recovery() {
  local world status log
  world=$(make_world stop-status)
  fm_write_meta "$world/home/state/child.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:1" "linear_card_id=card-D"
  printf '%s\n' 'needs-decision [at=999] [key=gate-4]: choose a path' \
    > "$world/home/state/child.status"
  write_cards "$world/cards.json" \
    '[{"id":"card-D","identifier":"COD-D","state":"In Progress","title":"d","url":"u"}]'
  status="$world/buildboard.status"
  log="$world/send.log"
  : > "$log"
  printf '%s\n' 'paused [key=operating-studio-stop] [at=1]: all workers stopped' > "$status"
  FM_BOARD_LOOP_STOP_STATUS="$status" FM_TEST_SEND_LOG="$log" \
    run_scan "$world" 1000 recover --cards "$world/cards.json" >/dev/null 2>&1
  assert_equals "0" "$(wc -l < "$log" | tr -d '[:space:]')" \
    "a stop-status signal refuses recovery"
  printf '%s\n%s\n' 'paused [key=operating-studio-stop] [at=1]: all workers stopped' \
    'resolved [key=operating-studio-stop] [at=2]: resumed' > "$status"
  FM_BOARD_LOOP_STOP_STATUS="$status" FM_TEST_SEND_LOG="$log" \
    run_scan "$world" 1000 recover --cards "$world/cards.json" >/dev/null 2>&1
  assert_equals "1" "$(wc -l < "$log" | tr -d '[:space:]')" \
    "a resolved stop signal re-enables recovery"
  pass "stop-status-signal-gates-recovery"
}

test_orphan_card() {
  local world
  world=$(make_world orphan-card)
  write_cards "$world/cards.json" \
    '[{"id":"card-X","identifier":"COD-X","state":"In Progress","title":"x","url":"u"}]'
  local out
  out=$(run_scan "$world" 1000 --cards "$world/cards.json")
  assert_equals "orphan-card" \
    "$(printf '%s' "$out" | jq -r '.causes[0].kind')" "unbound card is an orphan"
  pass "orphan-card"
}

test_canonical_pr_moved_not_in_review() {
  # COD-5030: a finished lane with a canonical recorded PR left In Progress.
  local world
  world=$(make_world cod-5030)
  fm_write_meta "$world/home/state/cod-5030.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:1" "linear_card_id=card-5030" \
    "pr=https://example.com/open/42" "pr_head=head1"
  printf '%s\n' 'done [at=999]: PR https://example.com/open/42 checks green' \
    > "$world/home/state/cod-5030.status"
  write_cards "$world/cards.json" \
    '[{"id":"card-5030","identifier":"COD-5030","state":"In Progress","title":"t","url":"u"}]'
  local out
  out=$(run_scan "$world" 1000 --cards "$world/cards.json")
  assert_equals "green-pr-not-in-review" \
    "$(printf '%s' "$out" | jq -r '.causes[0].kind')" "finished lane with an open PR is flagged"
  assert_equals "0" "$(printf '%s' "$out" | jq -r '.capacity.productive')" \
    "terminal lane is not productive capacity"
  pass "canonical-pr-moved-not-in-review"
}

test_canonical_identity_over_title() {
  # The binding is the immutable card id; a title that names another card never
  # overrides it.
  local world
  world=$(make_world canonical-identity)
  fm_write_meta "$world/home/state/lane-a.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:1" "linear_card_id=card-A"
  printf '%s\n' 'working [at=999]: building' > "$world/home/state/lane-a.status"
  write_cards "$world/cards.json" \
    '[{"id":"card-A","identifier":"COD-A","state":"In Progress","title":"COD-B renamed","url":"u"},
      {"id":"card-B","identifier":"COD-B","state":"In Progress","title":"COD-A renamed","url":"u"}]'
  local out
  out=$(run_scan "$world" 1000 --cards "$world/cards.json")
  assert_equals "1" "$(printf '%s' "$out" | jq -r '[.lanes[] | select(.task_id=="lane-a" and .card_identifier=="COD-A")] | length')" \
    "canonical id wins over a mismatched title"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '[.causes[] | select(.kind=="orphan-card" and .identifier=="COD-B")] | length')" \
    "the unbound sibling card is the only orphan"
  pass "canonical-identity-over-title"
}

test_head_drift_supersedes_stale_evidence() {
  local world
  world=$(make_world head-drift)
  fm_write_meta "$world/home/state/lane.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:1" "linear_card_id=card-X" \
    "pr=https://example.com/drift/1" "pr_head=oldhead"
  printf '%s\n' 'working [at=999]: building' > "$world/home/state/lane.status"
  write_cards "$world/cards.json" \
    '[{"id":"card-X","identifier":"COD-X","state":"In Review","title":"x","url":"u"}]'
  local out
  out=$(run_scan "$world" 1000 --cards "$world/cards.json")
  assert_equals "head-drift" "$(printf '%s' "$out" | jq -r '.causes[0].kind')" \
    "a moved open PR head is a real cause"
  pass "head-drift-supersedes-stale-evidence"
}

test_terminal_lane_left_in_progress() {
  local world
  world=$(make_world terminal-lane)
  fm_write_meta "$world/home/state/lane.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:1" "linear_card_id=card-X"
  printf '%s\n' 'done [at=999]: finished' > "$world/home/state/lane.status"
  write_cards "$world/cards.json" \
    '[{"id":"card-X","identifier":"COD-X","state":"In Progress","title":"x","url":"u"}]'
  local out
  out=$(run_scan "$world" 1000 --cards "$world/cards.json")
  assert_equals "terminal-lane-active-card" "$(printf '%s' "$out" | jq -r '.causes[0].kind')" \
    "a terminal lane on an active card is a cause"
  pass "terminal-lane-left-in-progress"
}

test_capacity_excludes_nonproductive_dispositions() {
  local world i=0 d
  world=$(make_world capacity)
  for d in "done" failed; do
    i=$((i + 1))
    fm_write_meta "$world/home/state/lane$i.meta" \
      "kind=ship" "backend=tmux" "window=jarvis:$i" "linear_card_id=card-$i"
    printf '%s [at=999]: x\n' "$d" > "$world/home/state/lane$i.status"
  done
  fm_write_meta "$world/home/state/lane3.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:3" "linear_card_id=card-3"
  printf '%s\n' 'blocked [at=999]: stuck' > "$world/home/state/lane3.status"
  write_cards "$world/cards.json" \
    '[{"id":"card-1","identifier":"COD-1","state":"In Progress","title":"1","url":"u"},
      {"id":"card-2","identifier":"COD-2","state":"In Progress","title":"2","url":"u"},
      {"id":"card-3","identifier":"COD-3","state":"In Progress","title":"3","url":"u"}]'
  local out
  out=$(run_scan "$world" 1000 --cards "$world/cards.json")
  assert_equals "0" "$(printf '%s' "$out" | jq -r '.capacity.productive')" \
    "done/failed/blocked lanes are never productive capacity"
  pass "capacity-excludes-nonproductive-dispositions"
}

test_review_promotion_and_return() {
  local world
  world=$(make_world review)
  fm_write_meta "$world/home/state/inrev.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:1" "linear_card_id=card-R"
  printf '%s\n' 'working [at=999]: waiting on review' > "$world/home/state/inrev.status"
  fm_write_meta "$world/home/state/rtm.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:2" "linear_card_id=card-M" \
    "pr=https://example.com/open/9" "pr_head=head1"
  printf '%s\n' 'working [at=999]: reviewing' > "$world/home/state/rtm.status"
  write_cards "$world/cards.json" \
    '[{"id":"card-R","identifier":"COD-R","state":"In Review","title":"r","url":"u"},
      {"id":"card-M","identifier":"COD-M","state":"Ready to Merge","title":"m","url":"u"}]'
  local out
  out=$(run_scan "$world" 1000 --cards "$world/cards.json")
  assert_equals "1" \
    "$(printf '%s' "$out" | jq -r '[.causes[] | select(.kind=="in-review-without-pr")] | length')" \
    "In Review without a PR is returned"
  assert_equals "1" \
    "$(printf '%s' "$out" | jq -r '[.causes[] | select(.kind=="ready-to-merge-unlanded")] | length')" \
    "an unlanded Ready to Merge candidate is a cause"
  pass "review-promotion-and-return"
}

test_serial_merge_pickup_and_throughput() {
  local world
  world=$(make_world throughput)
  fm_write_meta "$world/home/state/ship.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:1" "linear_card_id=card-D" \
    "pr=https://example.com/merged/1" "pr_head=deadbeef"
  printf '%s\n' 'done [at=999]: PR https://example.com/merged/1 checks green' \
    > "$world/home/state/ship.status"
  write_cards "$world/cards.json" \
    '[{"id":"card-D","identifier":"COD-D","state":"Ready to Deploy","title":"d","url":"u"}]'
  local out
  out=$(run_scan "$world" 2000 --cards "$world/cards.json")
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.throughput.verified_ready_to_deploy')" \
    "a merged Ready to Deploy PR is freshly verified"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.throughput.fault')" \
    "a landing inside the hour is not a fault"
  assert_equals "0" "$(printf '%s' "$out" | jq -r '[.causes[] | select(.kind=="ready-to-deploy-unverified")] | length')" \
    "merged evidence clears the unverified cause"
  pass "serial-merge-pickup-and-throughput"
}

test_rolling_hour_and_zero_landing_fault() {
  local world
  world=$(make_world rolling-hour)
  fm_write_meta "$world/home/state/a.meta" \
    "kind=ship" "backend=herdr" "herdr_session=jarvis" "herdr_pane_id=p1" \
    "window=jarvis:p1" "linear_card_id=card-A"
  printf '%s\n' 'working [at=999]: building' > "$world/home/state/a.status"
  write_cards "$world/cards.json" \
    '[{"id":"card-A","identifier":"COD-A","state":"In Progress","title":"a","url":"u"}]'
  local out
  out=$(FM_TEST_CREW_STATE_CMD="$world/fakebin/crew" run_scan "$world" 5000 --cards "$world/cards.json")
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.capacity.productive')" \
    "a live working lane is productive"
  assert_equals "true" "$(printf '%s' "$out" | jq -r '.throughput.fault')" \
    "zero landings with active eligible work is an end-to-end fault"
  # A landing older than the window does not count.
  printf '%s\n' "0	card-Z	https://example.com/merged/old	oldhead" \
    > "$world/home/state/.board-loop-deploy-history"
  out=$(FM_TEST_CREW_STATE_CMD="$world/fakebin/crew" run_scan "$world" 100000 --cards "$world/cards.json")
  assert_equals "0" "$(printf '%s' "$out" | jq -r '.throughput.verified_ready_to_deploy')" \
    "a landing outside the rolling hour does not count"
  assert_equals "true" "$(printf '%s' "$out" | jq -r '.throughput.fault')" \
    "stale landings do not clear the fault"
  pass "rolling-hour-and-zero-landing-fault"
}

test_idle_done_unconsumed_decision_replay() {
  # The measured replay uses the public answer path: the answer closes the open
  # key, the worker acknowledges its exact inbox record, then produces no output.
  local world
  world=$(make_world decision-replay)
  fm_write_meta "$world/home/state/child.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:1" "linear_card_id=card-D"
  printf '%s\n' 'needs-decision [at=999] [key=gate-1]: choose a path' \
    > "$world/home/state/child.status"
  FM_HOME="$world/home" FM_STATE_OVERRIDE="$world/home/state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" child --resolve-key gate-1 answer >/dev/null 2>&1 \
    || fail "public decision answer failed"
  mkdir -p "$world/home/state/child.inbox/handled"
  mv "$world/home/state/child.inbox/001.msg" "$world/home/state/child.inbox/handled/001.msg"
  write_cards "$world/cards.json" \
    '[{"id":"card-D","identifier":"COD-D","state":"In Progress","title":"d","url":"u"}]'
  local out
  out=$(run_scan "$world" 1000 --cards "$world/cards.json")
  assert_equals "1" \
    "$(printf '%s' "$out" | jq -r '[.causes[] | select(.kind=="decision-unconsumed")] | length')" \
    "an acknowledged but unconsumed decision is a concrete cause"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.decisions[0].acknowledged')" \
    "the ledger records the acknowledgement"
  # A recovery pass steers the owning worker, idempotently.
  local log="$world/send.log"
  : > "$log"
  FM_TEST_SEND_LOG="$log" run_scan "$world" 1000 recover --cards "$world/cards.json" >/dev/null
  FM_TEST_SEND_LOG="$log" run_scan "$world" 1001 recover --cards "$world/cards.json" >/dev/null
  assert_equals "1" "$(wc -l < "$log" | tr -d '[:space:]')" \
    "recovery steers once and never spams on replay"
  pass "idle-done-unconsumed-decision-replay"
}

test_decision_recorded_but_undelivered() {
  local world
  world=$(make_world decision-undelivered)
  fm_write_meta "$world/home/state/child.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:1" "linear_card_id=card-D"
  printf '%s\n' 'needs-decision [at=999] [key=gate-2]: choose a path' \
    > "$world/home/state/child.status"
  write_cards "$world/cards.json" \
    '[{"id":"card-D","identifier":"COD-D","state":"In Progress","title":"d","url":"u"}]'
  local out
  out=$(run_scan "$world" 1000 --cards "$world/cards.json")
  assert_equals "1" \
    "$(printf '%s' "$out" | jq -r '[.causes[] | select(.kind=="decision-recorded-undelivered")] | length')" \
    "an undelivered decision is a concrete cause"
  pass "decision-recorded-but-undelivered"
}

test_failed_lane_branch_retry_stalls() {
  # COD-5191 shape: a lane blocked on repeated preview-branch provisioning with
  # no new evidence across passes must surface as stalled, not "active".
  local world
  world=$(make_world lane-branch-stall)
  fm_write_meta "$world/home/state/child.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:1" "linear_card_id=card-D"
  printf '%s\n' 'blocked [at=999]: lane:branch preview returned UNHEALTHY on retry' \
    > "$world/home/state/child.status"
  write_cards "$world/cards.json" \
    '[{"id":"card-D","identifier":"COD-D","state":"In Progress","title":"d","url":"u"}]'
  run_scan "$world" 1000 --cards "$world/cards.json" >/dev/null
  local out
  out=$(run_scan "$world" 5000 --cards "$world/cards.json")
  assert_equals "1" \
    "$(printf '%s' "$out" | jq -r '[.causes[] | select(.kind=="stalled-disposition")] | length')" \
    "a stalled lane is an escalation, not active work"
  assert_equals "0" "$(printf '%s' "$out" | jq -r '.capacity.productive')" \
    "a blocked stalled lane is not capacity"
  pass "failed-lane-branch-retry-stalls"
}

test_replay_idempotence() {
  local world
  world=$(make_world replay)
  fm_write_meta "$world/home/state/ship.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:1" "linear_card_id=card-D" \
    "pr=https://example.com/merged/1" "pr_head=deadbeef"
  printf '%s\n' 'done [at=999]: PR https://example.com/merged/1 checks green' \
    > "$world/home/state/ship.status"
  write_cards "$world/cards.json" \
    '[{"id":"card-D","identifier":"COD-D","state":"Ready to Deploy","title":"d","url":"u"}]'
  local first second
  first=$(run_scan "$world" 2000 --cards "$world/cards.json" | jq -S .)
  second=$(run_scan "$world" 2000 --cards "$world/cards.json" | jq -S .)
  assert_equals "$first" "$second" "a replayed scan is idempotent"
  assert_equals "1" "$(wc -l < "$world/home/state/.board-loop-deploy-history" | tr -d '[:space:]')" \
    "the deployment ledger records one verified landing, not a duplicate"
  assert_equals "1" "$(wc -l < "$world/home/state/.board-loop-stall.tsv" | tr -d '[:space:]')" \
    "the stall ledger holds one lane row across replays"
  pass "replay-idempotence"
}

test_inventory_mode() {
  local world
  world=$(make_world inventory)
  fm_write_meta "$world/home/state/ship.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:1" "linear_card_id=card-D"
  local out
  out=$(run_scan "$world" 1000 inventory)
  assert_equals "fm-board-inventory.v1" "$(printf '%s' "$out" | jq -r '.schema')" \
    "inventory emits a stable schema"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.lanes | length')" \
    "inventory includes the local lane"
  pass "inventory-mode"
}

test_remote_lane_owns_card() {
  local world out
  world=$(make_world remote-lane)
  write_cards "$world/cards.json" \
    '[{"id":"card-R","identifier":"COD-R","state":"In Progress","title":"r","url":"u"}]'
  jq -n '{schema:"fm-board-inventory.v1",home:"remote",lanes:[{
    task_id:"remote-worker",kind:"ship",backend:"tmux",endpoint:"remote:1",
    linear_card_id:"card-R",agent_status:"working",endpoint_status:"alive",
    disposition:"working",validation:"running",terminal:false,pr:"",pr_head:"",
    pr_state:"unknown",pr_draft:false,pr_head_live:"",status_verb:"working",
    status_size:10,agent_source:"available",validation_source:"available",
    forge_source:"not-required"}]}' > "$world/remote.json"
  out=$(run_scan "$world" 1000 --cards "$world/cards.json" --remote-inventory "$world/remote.json")
  assert_equals "0" "$(printf '%s' "$out" | jq -r '[.causes[] | select(.kind=="orphan-card")] | length')" \
    "a remote canonical lane owns its card"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.capacity.productive')" \
    "a healthy remote lane counts as productive capacity"
  pass "remote-lane-owns-card"
}

test_non_herdr_lane_uses_crew_state() {
  local world out
  world=$(make_world non-herdr)
  fm_write_meta "$world/home/state/worker.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:1" "linear_card_id=card-T"
  printf '%s\n' 'working [at=999]: building' > "$world/home/state/worker.status"
  write_cards "$world/cards.json" \
    '[{"id":"card-T","identifier":"COD-T","state":"In Progress","title":"t","url":"u"}]'
  out=$(FM_TEST_CREW_STATE_CMD="$world/fakebin/crew" run_scan "$world" 1000 --cards "$world/cards.json")
  assert_equals "working" "$(printf '%s' "$out" | jq -r '.lanes[0].agent_status')" \
    "backend-neutral crew state supplies agent status"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '.capacity.productive')" \
    "a live tmux lane counts as productive"
  pass "non-herdr-lane-uses-crew-state"
}

test_dependency_outages_fail_closed() {
  local world out
  world=$(make_world source-outage)
  out=$(run_scan "$world" 1000)
  assert_equals "unavailable" "$(printf '%s' "$out" | jq -r '.sources.linear')" \
    "a Linear outage is explicit"
  assert_equals "1" "$(printf '%s' "$out" | jq -r '[.causes[] | select(.detail | contains("Linear board"))] | length')" \
    "a Linear outage is actionable"
  printf '{"schema":"bad","lanes":[]}\n' > "$world/remote.json"
  write_cards "$world/empty.json" '[]'
  out=$(run_scan "$world" 1000 --cards "$world/empty.json" --remote-inventory "$world/remote.json")
  assert_equals "unavailable" "$(printf '%s' "$out" | jq -r '.sources.remote')" \
    "an invalid remote inventory is explicit"
  pass "dependency-outages-fail-closed"
}

test_merged_head_drift_is_not_verified() {
  local world out
  world=$(make_world merged-drift)
  fm_write_meta "$world/home/state/ship.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:1" "linear_card_id=card-D" \
    "pr=https://example.com/merged/1" "pr_head=oldhead"
  printf '%s\n' 'done [at=999]: merged' > "$world/home/state/ship.status"
  write_cards "$world/cards.json" \
    '[{"id":"card-D","identifier":"COD-D","state":"Ready to Deploy","title":"d","url":"u"}]'
  out=$(FM_TEST_MERGED_HEAD=newhead run_scan "$world" 2000 --cards "$world/cards.json")
  assert_equals "head-drift" "$(printf '%s' "$out" | jq -r '.causes[0].kind')" \
    "merged head drift remains a cause"
  assert_equals "0" "$(printf '%s' "$out" | jq -r '.throughput.verified_ready_to_deploy')" \
    "a mismatched merged head is never recorded"
  pass "merged-head-drift-is-not-verified"
}

test_recovery_retry_resets_after_clear() {
  local world log
  world=$(make_world recovery-retry)
  fm_write_meta "$world/home/state/ship.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:1" "linear_card_id=card-D" \
    "pr=https://example.com/open/1" "pr_head=head1"
  printf '%s\n' 'done [at=999]: finished' > "$world/home/state/ship.status"
  write_cards "$world/cards.json" \
    '[{"id":"card-D","identifier":"COD-D","state":"In Progress","title":"d","url":"u"}]'
  log="$world/send.log"; : > "$log"
  FM_TEST_SEND_LOG="$log" run_scan "$world" 1000 recover --cards "$world/cards.json" >/dev/null
  FM_TEST_SEND_LOG="$log" run_scan "$world" 1900 recover --cards "$world/cards.json" >/dev/null
  FM_TEST_SEND_LOG="$log" run_scan "$world" 2800 recover --cards "$world/cards.json" >/dev/null
  FM_TEST_SEND_LOG="$log" run_scan "$world" 3700 recover --cards "$world/cards.json" >/dev/null
  assert_equals "3" "$(wc -l < "$log" | tr -d '[:space:]')" "one cause has a bounded retry ladder"
  write_cards "$world/empty.json" '[]'
  run_scan "$world" 4600 recover --cards "$world/empty.json" >/dev/null
  FM_TEST_SEND_LOG="$log" run_scan "$world" 5500 recover --cards "$world/cards.json" >/dev/null
  assert_equals "4" "$(wc -l < "$log" | tr -d '[:space:]')" \
    "a cleared cause gets a fresh retry when it recurs"
  pass "recovery-retry-resets-after-clear"
}

test_enforce_writes_linear_and_reads_back() {
  local world state_file send_log
  world=$(make_world enforce-linear)
  state_file="$world/linear-state"
  fm_write_meta "$world/home/state/ship.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:1" "linear_card_id=card-D" \
    "pr=https://example.com/open/1" "pr_head=head1"
  printf '%s\n' 'done [at=999]: finished' > "$world/home/state/ship.status"
  write_cards "$world/cards.json" \
    '[{"id":"card-D","identifier":"COD-D","state":"In Progress","title":"d","url":"u"}]'
  printf 'FM_LINEAR_WRITE_API_KEY=test\nFM_LINEAR_OPERATING_STUDIO_TEAM_ID=team\n' \
    > "$world/home/.env.linear.local"
  send_log="$world/send.log"; : > "$send_log"
  PATH="$world/fakebin:$PATH" FM_TEST_LINEAR_STATE_FILE="$state_file" FM_TEST_SEND_LOG="$send_log" \
    run_scan "$world" 1000 enforce --cards "$world/cards.json" >/dev/null
  assert_equals "In Review" "$(cat "$state_file")" \
    "enforcement advances a verified green PR into independent review"
  assert_equals "0" "$(wc -l < "$send_log" | tr -d '[:space:]')" \
    "scheduled enforcement never wakes a stopped worker"
  run_scan "$world" 1001 pause --reason stop >/dev/null
  rm -f "$state_file"
  PATH="$world/fakebin:$PATH" FM_TEST_LINEAR_STATE_FILE="$state_file" \
    run_scan "$world" 1002 enforce --cards "$world/cards.json" >/dev/null 2>&1
  assert_absent "$state_file" "a durable stop blocks Linear writes as well as steers"
  run_scan "$world" 1003 resume >/dev/null
  fm_write_meta "$world/home/state/ship.meta" \
    "kind=ship" "backend=tmux" "window=jarvis:1" "linear_card_id=card-D" \
    "pr=https://example.com/merged/1" "pr_head=deadbeef"
  write_cards "$world/cards.json" \
    '[{"id":"card-D","identifier":"COD-D","state":"Ready to Merge","title":"d","url":"u"}]'
  PATH="$world/fakebin:$PATH" FM_TEST_LINEAR_STATE_FILE="$state_file" \
    run_scan "$world" 1004 enforce --cards "$world/cards.json" >/dev/null
  assert_equals "Ready to Deploy" "$(cat "$state_file")" \
    "enforcement advances only an already merged exact head to deployment"
  pass "enforce-writes-linear-and-reads-back"
}

test_orphan_card
test_stop_posture_refuses_recovery
test_stop_status_signal_gates_recovery
test_canonical_pr_moved_not_in_review
test_canonical_identity_over_title
test_head_drift_supersedes_stale_evidence
test_terminal_lane_left_in_progress
test_capacity_excludes_nonproductive_dispositions
test_review_promotion_and_return
test_serial_merge_pickup_and_throughput
test_rolling_hour_and_zero_landing_fault
test_idle_done_unconsumed_decision_replay
test_decision_recorded_but_undelivered
test_failed_lane_branch_retry_stalls
test_replay_idempotence
test_inventory_mode
test_remote_lane_owns_card
test_non_herdr_lane_uses_crew_state
test_dependency_outages_fail_closed
test_merged_head_drift_is_not_verified
test_recovery_retry_resets_after_clear
test_enforce_writes_linear_and_reads_back
