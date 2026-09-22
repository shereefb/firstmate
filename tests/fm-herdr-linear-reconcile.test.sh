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
if [ "${1:-}" = agent ] && [ "${2:-}" = get ]; then
  case "${3:-}" in
    p-working|p-review|p-shared) printf '%s\n' '{"result":{"agent":{"agent_status":"working"}}}' ;;
    p-idle) printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}' ;;
    p-missing) printf '%s\n' '{"error":{"code":"agent_not_found"}}' ;;
    *) printf '%s\n' '{"error":{"code":"socket_unavailable"}}' ;;
  esac
fi
SH
  chmod +x "$dir/bin/herdr"
  printf '%s\n' "$dir"
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
    PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$SCRIPT" --cards "$cards" --zeus-inventory "$zeus" --json
  else
    PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$SCRIPT" --cards "$cards" --json
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
{"schema":"fm-herdr-linear-inventory.v1","home":"zeus-home","children":[{"task_id":"zeus-worker","linear_card_id":"card-zeus","backend":"herdr","endpoint":"zeus:p9","herdr_session":"zeus","herdr_pane_id":"p9","pr":"","endpoint_status":"working"}]}
JSON
  out=$(run_reconcile "$dir" "$cards" "$zeus") || fail "remote inventory reconciliation failed"
  printf '%s' "$out" | jq -e '
    .summary.workers == 1 and .findings[0].kind == "matched-live-endpoint"
  ' >/dev/null || fail "returned Zeus inventory was not reconciled: $out"
  pass "parent consumes compact Zeus inventory without probing Zeus lanes"
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
test_unavailable_inputs_fail_clearly
printf 'all fm-herdr-linear-reconcile tests passed\n'
