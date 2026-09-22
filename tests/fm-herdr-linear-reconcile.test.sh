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
  mkdir -p "$dir/home/state" "$dir/bin"
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
  chmod +x "$dir/bin/herdr" "$dir/bin/fake-ps"
  printf '%s\n' "$dir"
}

write_linear_curl() { # <case-dir>
  local dir=$1
  cat > "$dir/bin/curl" <<'SH'
#!/usr/bin/env bash
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
case "$after" in
  '') printf '%s\n' '{"data":{"issues":{"nodes":[{"id":"card-api-1","identifier":"OS-101","state":{"name":"In Progress"}}],"pageInfo":{"hasNextPage":true,"endCursor":"cursor-1"}}}}' ;;
  cursor-1) printf '%s\n' '{"data":{"issues":{"nodes":[{"id":"card-api-2","identifier":"OS-102","state":{"name":"In Review"}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}' ;;
  *) exit 22 ;;
esac
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

run_reconcile() { # <case-dir> <cards> [<zeus-inventory>]
  local dir=$1 cards=$2 zeus=${3:-}
  if [ -n "$zeus" ]; then
    PATH="$dir/bin:$PATH" FM_HERDR_PS_BIN="$dir/bin/fake-ps" FM_HOME="$dir/home" "$SCRIPT" --cards "$cards" --zeus-inventory "$zeus" --json
  else
    PATH="$dir/bin:$PATH" FM_HERDR_PS_BIN="$dir/bin/fake-ps" FM_HOME="$dir/home" "$SCRIPT" --cards "$cards" --json
  fi
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

test_remote_inventory_is_joined_without_remote_probe() {
  local dir cards zeus out
  dir=$(make_case remote-inventory)
  cards="$dir/cards.json"
  zeus="$dir/zeus.json"
  printf '%s\n' '{"cards":[{"id":"card-zeus","identifier":"OS-9","state":"In Progress"}]}' > "$cards"
  cat > "$zeus" <<'JSON'
{"schema":"fm-herdr-linear-inventory.v1","home":"zeus-home","children":[{"task_id":"zeus-worker","linear_card_id":"card-zeus","backend":"herdr","endpoint":"zeus:p9","herdr_session":"zeus","herdr_pane_id":"p9","pr":"","endpoint_status":"alive"}]}
JSON
  out=$(run_reconcile "$dir" "$cards" "$zeus") || fail "remote inventory reconciliation failed"
  printf '%s' "$out" | jq -e '
    .summary.workers == 1 and .findings[0].kind == "matched-live-endpoint"
  ' >/dev/null || fail "returned Zeus inventory was not reconciled: $out"
  pass "parent consumes compact Zeus inventory without probing Zeus lanes"
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
    case "$out" in *'Linear input is invalid'*) ;; *) fail "empty $field diagnostic drifted: $out" ;; esac
  done
  pass "empty Linear card identities are rejected before reconciliation"
}

test_remote_inventory_requires_complete_schema() {
  local dir cards zeus out rc
  dir=$(make_case remote-schema)
  cards="$dir/cards.json"
  zeus="$dir/zeus.json"
  printf '%s\n' '{"cards":[]}' > "$cards"
  printf '%s\n' '{"schema":"fm-herdr-linear-inventory.v1","home":"zeus-home","children":[{"task_id":"worker","endpoint_status":"alive"}]}' > "$zeus"
  out=$(run_reconcile "$dir" "$cards" "$zeus" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "incomplete Zeus child was accepted"
  case "$out" in *'Zeus inventory is invalid'*) ;; *) fail "incomplete Zeus diagnostic drifted: $out" ;; esac
  printf '%s\n' '{"schema":"fm-herdr-linear-inventory.v1","home":"zeus-home","children":[{"task_id":"worker","linear_card_id":"","backend":"herdr","endpoint":"zeus:p1","herdr_session":"zeus","herdr_pane_id":"p1","pr":"","endpoint_status":"working"}]}' > "$zeus"
  out=$(run_reconcile "$dir" "$cards" "$zeus" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "unknown Zeus endpoint status was accepted"
  case "$out" in *'Zeus inventory is invalid'*) ;; *) fail "unknown Zeus status diagnostic drifted: $out" ;; esac
  pass "Zeus inventory requires every field and a closed endpoint status"
}

test_linear_api_requires_project_and_reads_all_pages() {
  local dir out rc
  dir=$(make_case linear-api)
  write_linear_curl "$dir"
  out=$(env -u FM_LINEAR_OPERATING_STUDIO_PROJECT_ID \
    PATH="$dir/bin:$PATH" FM_HERDR_PS_BIN="$dir/bin/fake-ps" FM_HOME="$dir/home" \
    LINEAR_API_KEY=secret FM_LINEAR_OPERATING_STUDIO_TEAM_ID=team-os \
    "$SCRIPT" --linear-api --json 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "Linear API ran without an Operating Studio project id"
  case "$out" in *'FM_LINEAR_OPERATING_STUDIO_PROJECT_ID is required'*) ;; *) fail "missing project diagnostic drifted: $out" ;; esac

  out=$(PATH="$dir/bin:$PATH" FM_HERDR_PS_BIN="$dir/bin/fake-ps" FM_HOME="$dir/home" \
    LINEAR_API_KEY=secret FM_LINEAR_OPERATING_STUDIO_TEAM_ID=team-os \
    FM_LINEAR_OPERATING_STUDIO_PROJECT_ID=project-os \
    "$SCRIPT" --linear-api --json) || fail "paginated Linear API reconciliation failed"
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

test_unavailable_inputs_fail_clearly() {
  local dir cards out rc
  dir=$(make_case unavailable)
  cards="$dir/cards.json"
  printf '%s\n' '{"cards":[]}' > "$cards"
  out=$(PATH="/usr/bin:/bin" FM_HOME="$dir/home" "$SCRIPT" --cards "$cards" --json 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "missing Herdr succeeded"
  case "$out" in *'Herdr is unavailable'*) ;; *) fail "missing Herdr diagnostic was unclear: $out" ;; esac
  out=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$SCRIPT" --cards "$dir/no-such-cards.json" --json 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "missing Linear input succeeded"
  case "$out" in *'Linear input is unavailable'*) ;; *) fail "missing Linear diagnostic was unclear: $out" ;; esac
  pass "unavailable Herdr and Linear input fail clearly"
}

test_equal_count_wrong_identity
test_remote_inventory_is_joined_without_remote_probe
test_duplicate_ownership_and_endpoint_are_not_coverage
test_unrelated_worker_missing_endpoint_and_review_mismatch
test_non_applicable_columns_do_not_cover_workers
test_process_liveness_outranks_recorded_agent_status
test_empty_card_identities_are_rejected
test_remote_inventory_requires_complete_schema
test_linear_api_requires_project_and_reads_all_pages
test_unavailable_inputs_fail_clearly
printf 'all fm-herdr-linear-reconcile tests passed\n'
