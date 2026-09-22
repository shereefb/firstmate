#!/usr/bin/env bash
# tests/fm-herdr-linear-reconcile.test.sh - behavior tests for the read-only
# Operating Studio reconciliation command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-linear-reconcile)
SCRIPT="$ROOT/bin/fm-herdr-linear-reconcile.sh"

make_case() { # <name>
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/bin"
  cat > "$dir/bin/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'pane get')
    case "${3:-}" in
      p-missing) printf '%s\n' '{"error":{"code":"pane_not_found"}}' ;;
      *) printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
    esac
    ;;
  'agent get')
    case "${3:-}" in
      p-working|p-review|p-shared|p-stale) printf '%s\n' '{"result":{"agent":{"agent_status":"working"}}}' ;;
      p-idle) printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}' ;;
      *) printf '%s\n' '{"error":{"code":"agent_not_found"}}' ;;
    esac
    ;;
  'pane process-info')
    pane=${4:-}
    if [ "$pane" = p-stale ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[{"pid":4242,"name":"zsh","argv0":"zsh","argv":["zsh"],"cmdline":"zsh"}]}}}\n' "$pane"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[{"pid":4343,"name":"claude","argv0":"claude","argv":["claude"],"cmdline":"claude"}]}}}\n' "$pane"
    fi
    ;;
  *)
    printf '%s\n' '{"error":{"code":"socket_unavailable"}}'
    ;;
esac
SH
  cat > "$dir/bin/fake-ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '-axo pid=,ppid=,comm=') printf '%s\n' '4242 1 zsh' ;;
  *) exit 1 ;;
esac
SH
  cat > "$dir/bin/fake-ssh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_TEST_ZEUS_SSH_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$FM_TEST_ZEUS_SSH_COUNT"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
[ "${1:-}" = zeus-host ] || exit 91
cat "$FM_TEST_ZEUS_LIVE_INVENTORY"
SH
  chmod +x "$dir/bin/herdr" "$dir/bin/fake-ps" "$dir/bin/fake-ssh"
  printf '%s\n' \
    '- zeus - Operating Studio delivery (host: zeus-host; root: /remote/firstmate; home: /remote/zeus-home; scope: Operating Studio delivery; projects: operating-studio; added 2026-09-22)' \
    '- other - Other delivery (host: zeus-host; root: /remote/firstmate; home: /remote/other-home; scope: Other delivery; projects: other; added 2026-09-22)' \
    > "$dir/home/data/secondmates.md"
  printf '%s\n' '{"schema":"fm-herdr-linear-inventory.v1","home":"/remote/zeus-home","children":[]}' > "$dir/zeus-live.json"
  write_linear_curl "$dir"
  printf '%s\n' "$dir"
}

write_linear_curl() { # <case-dir>
  local dir=$1
  cat > "$dir/bin/curl" <<'SH'
#!/usr/bin/env bash
cards_file=${FM_TEST_LINEAR_CARDS_FILE:?}
payload=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --data ]; then
    shift
    payload=${1:-}
  fi
  shift
done
printf '%s' "$payload" | jq -e '
  .variables.team == "team-os"
  and .variables.project == "project-os"
  and (.query | contains("project: { id: { eq: $project } }"))
' >/dev/null || exit 22
after=$(printf '%s' "$payload" | jq -r '.variables.after // ""')
if [ "${FM_TEST_LINEAR_PAGINATED:-0}" = 1 ]; then
  case "$after" in
    '') jq -c '{data:{issues:{nodes:(.cards[0:1] | map(.state = {name:.state})),pageInfo:{hasNextPage:true,endCursor:"cursor-1"}}}}' "$cards_file" ;;
    cursor-1) jq -c '{data:{issues:{nodes:(.cards[1:] | map(.state = {name:.state})),pageInfo:{hasNextPage:false,endCursor:null}}}}' "$cards_file" ;;
    *) exit 22 ;;
  esac
else
  jq -c '{data:{issues:{nodes:(.cards | map(.state = {name:.state})),pageInfo:{hasNextPage:false,endCursor:null}}}}' "$cards_file"
fi
SH
  chmod +x "$dir/bin/curl"
}

write_meta() { # <home> <task> <pane> <card-id> [<pr>]
  local home=$1 task=$2 pane=$3 card=$4 pr=${5:-}
  {
    printf 'backend=herdr\n'
    printf 'window=jarvis:%s\n' "$pane"
    printf 'herdr_session=jarvis\n'
    printf 'herdr_pane_id=%s\n' "$pane"
    [ -z "$card" ] || printf 'linear_card_id=%s\n' "$card"
    [ -z "$pr" ] || printf 'pr=%s\n' "$pr"
  } > "$home/state/$task.meta"
}

run_reconcile() { # <case-dir> <cards>
  local dir=$1 cards=$2
  PATH="$dir/bin:$PATH" FM_HERDR_PS_BIN="$dir/bin/fake-ps" FM_HOME="$dir/home" \
    FM_SSH_BIN="$dir/bin/fake-ssh" FM_TEST_ZEUS_LIVE_INVENTORY="$dir/zeus-live.json" \
    FM_TEST_ZEUS_SSH_COUNT="$dir/zeus-ssh.count" \
    FM_TEST_LINEAR_CARDS_FILE="$cards" LINEAR_API_KEY=secret \
    FM_LINEAR_OPERATING_STUDIO_TEAM_ID=team-os \
    FM_LINEAR_OPERATING_STUDIO_PROJECT_ID=project-os \
    "$SCRIPT" --linear-api --json
}

test_equal_count_wrong_identity() {
  local dir cards out
  dir=$(make_case equal-count)
  write_meta "$dir/home" worker-a p-working card-a
  cards="$dir/cards.json"
  printf '%s\n' '{"cards":[{"id":"card-b","identifier":"OS-2","state":"In Progress"}]}' > "$cards"
  out=$(run_reconcile "$dir" "$cards") || fail "equal-count reconciliation failed"
  printf '%s' "$out" | jq -e '
    [.findings[].kind] | sort == ["card-without-task-binding", "worker-without-applicable-card"]
  ' >/dev/null || fail "equal counts with wrong identities were treated as coverage: $out"
  pass "equal counts still report unmatched card and worker identities"
}

test_remote_inventory_is_fetched_live() {
  local dir cards zeus out refreshed
  dir=$(make_case remote-inventory)
  cards="$dir/cards.json"
  zeus="$dir/zeus-live.json"
  printf '%s\n' '{"cards":[{"id":"card-zeus","identifier":"OS-9","state":"In Progress"}]}' > "$cards"
  cat > "$zeus" <<'JSON'
{"schema":"fm-herdr-linear-inventory.v1","home":"/remote/zeus-home","children":[{"task_id":"zeus-worker","linear_card_id":"card-zeus","backend":"herdr","endpoint":"zeus:p9","herdr_session":"zeus","herdr_pane_id":"p9","pr":"","endpoint_status":"alive"}]}
JSON
  out=$(run_reconcile "$dir" "$cards") || fail "remote inventory reconciliation failed"
  printf '%s' "$out" | jq -e '
    .summary.workers == 1 and .findings[0].kind == "matched-live-endpoint"
  ' >/dev/null || fail "returned Zeus inventory was not reconciled: $out"
  printf '%s\n' '{"schema":"fm-herdr-linear-inventory.v1","home":"/remote/zeus-home","children":[]}' > "$zeus"
  refreshed=$(run_reconcile "$dir" "$cards") || fail "refreshed remote inventory reconciliation failed"
  printf '%s' "$refreshed" | jq -e '
    .summary.workers == 0 and .findings[0].kind == "card-without-task-binding"
  ' >/dev/null || fail "a retained Zeus snapshot was reused: $refreshed"
  [ "$(cat "$dir/zeus-ssh.count")" -eq 2 ] || fail "Zeus route was not read on every comparison"
  pass "comparison obtains fresh Zeus inventory through its registered route"
}

test_local_registered_inventory_route_is_accepted() {
  local dir cards zeus_home out
  dir=$(make_case local-inventory-route)
  cards="$dir/cards.json"
  zeus_home="$dir/zeus-home"
  mkdir -p "$zeus_home"
  printf '%s\n' "- zeus - Operating Studio delivery (home: $zeus_home; scope: Operating Studio delivery; projects: operating-studio; added 2026-09-22)" > "$dir/home/data/secondmates.md"
  printf '%s\n' '{"cards":[]}' > "$cards"
  out=$(run_reconcile "$dir" "$cards") || fail "local registered Zeus inventory failed"
  printf '%s' "$out" | jq -e --arg home "$zeus_home" '
    .summary.workers == 0 and .zeus_inventory.home == $home
  ' >/dev/null || fail "local Zeus route was not preserved: $out"
  pass "local registered Zeus inventory route is accepted"
}

test_process_liveness_outranks_recorded_agent_status() {
  local dir cards out
  dir=$(make_case process-liveness)
  write_meta "$dir/home" live-idle p-idle card-live
  write_meta "$dir/home" stale-working p-stale card-stale
  cards="$dir/cards.json"
  printf '%s\n' '{"cards":[{"id":"card-live","identifier":"OS-11","state":"In Progress"},{"id":"card-stale","identifier":"OS-12","state":"In Progress"}]}' > "$cards"
  out=$(run_reconcile "$dir" "$cards") || fail "process-backed reconciliation failed"
  printf '%s' "$out" | jq -e '
    ([.findings[] | select(.task_id == "live-idle")][0].kind == "matched-live-endpoint")
    and ([.findings[] | select(.task_id == "stale-working")][0].kind == "needs-deep-check")
    and ([.local_inventory.children[] | select(.task_id == "stale-working")][0].endpoint_status == "dead")
  ' >/dev/null || fail "raw Herdr status overrode process-backed liveness: $out"
  pass "process-backed liveness accepts live idle agents and rejects stale working registrations"
}

test_empty_card_identities_are_rejected() {
  local dir cards out rc
  dir=$(make_case empty-card-identity)
  cards="$dir/cards.json"
  for field in id identifier; do
    if [ "$field" = id ]; then
      printf '%s\n' '{"cards":[{"id":"","identifier":"OS-13","state":"In Progress"}]}' > "$cards"
    else
      printf '%s\n' '{"cards":[{"id":"card-13","identifier":"","state":"In Progress"}]}' > "$cards"
    fi
    out=$(run_reconcile "$dir" "$cards" 2>&1) && rc=0 || rc=$?
    [ "$rc" -ne 0 ] || fail "empty $field was accepted"
    case "$out" in *'Linear API returned invalid cards'*) ;; *) fail "empty $field diagnostic drifted: $out" ;; esac
  done
  pass "empty Linear card identities are rejected before reconciliation"
}

test_live_remote_inventory_requires_complete_schema() {
  local dir cards zeus out rc
  dir=$(make_case remote-schema)
  cards="$dir/cards.json"
  zeus="$dir/zeus-live.json"
  printf '%s\n' '{"cards":[]}' > "$cards"
  printf '%s\n' '{"schema":"fm-herdr-linear-inventory.v1","home":"/remote/zeus-home","children":[{"task_id":"worker","endpoint_status":"alive"}]}' > "$zeus"
  out=$(run_reconcile "$dir" "$cards" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "incomplete Zeus child was accepted"
  case "$out" in *'Zeus inventory is invalid'*) ;; *) fail "incomplete Zeus diagnostic drifted: $out" ;; esac
  printf '%s\n' '{"schema":"fm-herdr-linear-inventory.v1","home":"/remote/zeus-home","children":[{"task_id":"worker","linear_card_id":"","backend":"herdr","endpoint":"zeus:p1","herdr_session":"zeus","herdr_pane_id":"p1","pr":"","endpoint_status":"working"}]}' > "$zeus"
  out=$(run_reconcile "$dir" "$cards" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "unknown Zeus endpoint status was accepted"
  case "$out" in *'Zeus inventory is invalid'*) ;; *) fail "unknown Zeus status diagnostic drifted: $out" ;; esac
  printf '%s\n' '{"schema":"fm-herdr-linear-inventory.v1","home":"/remote/other-home","children":[]}' > "$zeus"
  out=$(run_reconcile "$dir" "$cards" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "another home was accepted as Zeus inventory"
  case "$out" in *'live Zeus inventory returned home'*) ;; *) fail "wrong Zeus owner diagnostic drifted: $out" ;; esac
  pass "live Zeus inventory requires its registered route and complete child schema"
}

test_linear_api_requires_project_and_reads_all_pages() {
  local dir cards out rc
  dir=$(make_case linear-api)
  cards="$dir/cards.json"
  printf '%s\n' '{"cards":[{"id":"card-api-1","identifier":"OS-101","state":"In Progress"},{"id":"card-api-2","identifier":"OS-102","state":"In Review"}]}' > "$cards"
  out=$(env -u FM_LINEAR_OPERATING_STUDIO_PROJECT_ID \
    PATH="$dir/bin:$PATH" FM_HERDR_PS_BIN="$dir/bin/fake-ps" FM_HOME="$dir/home" \
    FM_TEST_LINEAR_CARDS_FILE="$cards" LINEAR_API_KEY=secret \
    FM_LINEAR_OPERATING_STUDIO_TEAM_ID=team-os \
    FM_SSH_BIN="$dir/bin/fake-ssh" FM_TEST_ZEUS_LIVE_INVENTORY="$dir/zeus-live.json" \
    FM_TEST_ZEUS_SSH_COUNT="$dir/zeus-ssh.count" \
    "$SCRIPT" --linear-api --json 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "Linear API ran without an Operating Studio project id"
  case "$out" in *'FM_LINEAR_OPERATING_STUDIO_PROJECT_ID is required'*) ;; *) fail "missing project diagnostic drifted: $out" ;; esac

  out=$(PATH="$dir/bin:$PATH" FM_HERDR_PS_BIN="$dir/bin/fake-ps" FM_HOME="$dir/home" \
    FM_TEST_LINEAR_CARDS_FILE="$cards" FM_TEST_LINEAR_PAGINATED=1 \
    LINEAR_API_KEY=secret FM_LINEAR_OPERATING_STUDIO_TEAM_ID=team-os \
    FM_LINEAR_OPERATING_STUDIO_PROJECT_ID=project-os \
    FM_SSH_BIN="$dir/bin/fake-ssh" FM_TEST_ZEUS_LIVE_INVENTORY="$dir/zeus-live.json" \
    FM_TEST_ZEUS_SSH_COUNT="$dir/zeus-ssh.count" \
    "$SCRIPT" --linear-api --json) \
    || fail "paginated Linear API reconciliation failed"
  printf '%s' "$out" | jq -e '
    .summary.cards == 2
    and ([.cards[].id] | sort) == ["card-api-1", "card-api-2"]
    and ([.findings[].kind] | all(. == "card-without-task-binding"))
  ' >/dev/null || fail "Linear API project scope or pagination drifted: $out"
  pass "Linear API requires project identity and consumes every page"
}

test_duplicate_ownership_and_endpoint_are_not_coverage() {
  local dir cards ownership endpoint
  dir=$(make_case duplicates)
  write_meta "$dir/home" worker-a p-working card-a
  write_meta "$dir/home" worker-b p-idle card-a
  cards="$dir/cards.json"
  printf '%s\n' '{"cards":[{"id":"card-a","identifier":"OS-1","state":"In Progress"}]}' > "$cards"
  ownership=$(run_reconcile "$dir" "$cards") || fail "duplicate ownership reconciliation failed"
  printf '%s' "$ownership" | jq -e '.findings[0].kind == "duplicate-ownership"' >/dev/null \
    || fail "duplicate card ownership was accepted: $ownership"

  rm -f "$dir/home/state"/*.meta
  write_meta "$dir/home" worker-a p-shared card-a
  write_meta "$dir/home" worker-b p-shared card-b
  printf '%s\n' '{"cards":[{"id":"card-a","identifier":"OS-1","state":"In Progress"},{"id":"card-b","identifier":"OS-2","state":"In Progress"}]}' > "$cards"
  endpoint=$(run_reconcile "$dir" "$cards") || fail "duplicate endpoint reconciliation failed"
  printf '%s' "$endpoint" | jq -e '[.findings[].kind] | all(. == "duplicate-endpoint")' >/dev/null \
    || fail "duplicate endpoints were accepted: $endpoint"
  pass "duplicate card ownership and endpoints do not count as coverage"
}

test_unrelated_worker_missing_endpoint_and_review_mismatch() {
  local dir cards out
  dir=$(make_case discrepancies)
  write_meta "$dir/home" working p-working card-working
  write_meta "$dir/home" orphan p-idle ''
  write_meta "$dir/home" missing p-missing card-missing
  write_meta "$dir/home" review p-review card-review
  cards="$dir/cards.json"
  printf '%s\n' '{"cards":[{"id":"card-working","identifier":"OS-1","state":"In Progress"},{"id":"card-missing","identifier":"OS-2","state":"In Progress"},{"id":"card-review","identifier":"OS-3","state":"In Review"}]}' > "$cards"
  out=$(run_reconcile "$dir" "$cards") || fail "discrepancy reconciliation failed"
  printf '%s' "$out" | jq -e '
    ([.findings[].kind] | sort) == ["board-column-mismatch-needs-pr-review", "matched-live-endpoint", "missing-endpoint", "worker-without-applicable-card"]
  ' >/dev/null || fail "unrelated, missing, or review mismatch classification drifted: $out"
  pass "unrelated workers, missing endpoints, and review mismatches remain visible"
}

test_non_applicable_columns_do_not_cover_workers() {
  local dir cards out
  dir=$(make_case non-applicable-column)
  write_meta "$dir/home" worker-a p-working card-done
  cards="$dir/cards.json"
  printf '%s\n' '{"cards":[{"id":"card-done","identifier":"OS-4","state":"Done"}]}' > "$cards"
  out=$(run_reconcile "$dir" "$cards") || fail "non-applicable column reconciliation failed"
  printf '%s' "$out" | jq -e '
    .summary.cards == 0 and .findings[0].kind == "worker-without-applicable-card"
  ' >/dev/null || fail "non-applicable card column counted as coverage: $out"
  pass "only In Progress and In Review cards provide coverage"
}

test_required_inputs_fail_clearly() {
  local dir cards out rc
  dir=$(make_case unavailable)
  cards="$dir/cards.json"
  printf '%s\n' '{"cards":[]}' > "$cards"
  out=$(PATH="/usr/bin:/bin" FM_HOME="$dir/home" "$SCRIPT" --linear-api --json 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "missing Herdr succeeded"
  case "$out" in *'Herdr is unavailable'*) ;; *) fail "missing Herdr diagnostic was unclear: $out" ;; esac

  printf '%s\n' '- other - Other delivery (host: zeus-host; root: /remote/firstmate; home: /remote/other-home; scope: Other delivery; projects: other; added 2026-09-22)' > "$dir/home/data/secondmates.md"
  out=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$SCRIPT" --linear-api --json 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "comparison without a registered Zeus route succeeded"
  case "$out" in *'Zeus route is unavailable'*) ;; *) fail "missing Zeus route diagnostic was unclear: $out" ;; esac

  out=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$SCRIPT" --zeus-inventory "$dir/zeus-live.json" --linear-api --json 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "caller-supplied Zeus inventory succeeded"
  case "$out" in *'usage: fm-herdr-linear-reconcile.sh'*) ;; *) fail "removed Zeus inventory input did not return usage: $out" ;; esac

  out=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$SCRIPT" --cards "$cards" --linear-api --json 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "unscoped --cards input succeeded"
  case "$out" in *'usage: fm-herdr-linear-reconcile.sh'*) ;; *) fail "removed --cards mode did not return usage: $out" ;; esac
  pass "comparison requires a registered Zeus route and rejects caller inputs"
}

test_equal_count_wrong_identity
test_remote_inventory_is_fetched_live
test_local_registered_inventory_route_is_accepted
test_duplicate_ownership_and_endpoint_are_not_coverage
test_unrelated_worker_missing_endpoint_and_review_mismatch
test_non_applicable_columns_do_not_cover_workers
test_process_liveness_outranks_recorded_agent_status
test_empty_card_identities_are_rejected
test_live_remote_inventory_requires_complete_schema
test_linear_api_requires_project_and_reads_all_pages
test_required_inputs_fail_clearly
printf 'all fm-herdr-linear-reconcile tests passed\n'
