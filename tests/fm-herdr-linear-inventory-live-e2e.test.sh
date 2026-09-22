#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
herdr_forget_inherited_pane

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$LAB_HELPER" ] || { echo "skip: live: Herdr lab helper not executable at $LAB_HELPER"; exit 0; }

ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-herdr-linear-inventory-live)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HOME_DIR="$TMP_ROOT/buildboard"
PRIMARY_HOME="$TMP_ROOT/primary"
SESSION=$("$LAB_HELPER" name fm-herdr-linear-inventory)
export LAB_HELPER ORIGINAL_PATH SESSION

cleanup() {
  local status=$?
  env PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr inventory lab"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

mkdir -p "$HOME_DIR/state" "$PRIMARY_HOME/state" "$TMP_ROOT/another-project"
printf '%s\n' buildboard > "$HOME_DIR/.fm-secondmate-home"
cat > "$HOME_DIR/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$PRIMARY_HOME
EOF

OWNER_CREATE=$(lab workspace create --cwd "$HOME_DIR" --label buildboard --no-focus) \
  || fail "could not create the registered owner workspace"
REGISTERED_WORKSPACE=$(printf '%s' "$OWNER_CREATE" | jq -er '.result.workspace.workspace_id') \
  || fail "could not read the registered owner workspace"
OWNER_OLD_TAB=$(printf '%s' "$OWNER_CREATE" | jq -er '.result.tab.tab_id') \
  || fail "could not read the registered owner tab"
OWNER_OLD_PANE=$(printf '%s' "$OWNER_CREATE" | jq -er '.result.root_pane.pane_id') \
  || fail "could not read the registered owner pane"

OLD_CHILD_CREATE=$(lab tab create --workspace "$REGISTERED_WORKSPACE" --cwd "$HOME_DIR" \
  --label fm-old-child --no-focus) || fail "could not create the registered-workspace child"
OLD_CHILD_TAB=$(printf '%s' "$OLD_CHILD_CREATE" | jq -er '.result.tab.tab_id') \
  || fail "could not read the registered-workspace child tab"
OLD_CHILD_PANE=$(printf '%s' "$OLD_CHILD_CREATE" | jq -er '.result.root_pane.pane_id') \
  || fail "could not read the registered-workspace child pane"
lab tab rename "$OLD_CHILD_TAB" renamed-old-child >/dev/null \
  || fail "could not rename the registered-workspace child tab"

PATH="$FAKEBIN:$ORIGINAL_PATH" bash -c '
  . "$1/bin/backends/herdr.sh"
  token=$(fm_backend_herdr_projection_journal_create "$2/state" projected) || exit
  printf "%s" "$token"
' _ "$ROOT" "$HOME_DIR" > "$TMP_ROOT/projection-token" \
  || fail "could not create the projection journal"
PROJECTION_TOKEN=$(cat "$TMP_ROOT/projection-token")
PROJECTION_LABEL="└ projected · p:$PROJECTION_TOKEN"
PROJECTED_CREATE=$(lab workspace create --cwd "$HOME_DIR" --label "$PROJECTION_LABEL" --no-focus) \
  || fail "could not create the projected workspace"
PROJECTED_WORKSPACE=$(printf '%s' "$PROJECTED_CREATE" | jq -er '.result.workspace.workspace_id') \
  || fail "could not read the projected workspace"
PROJECTED_TAB=$(printf '%s' "$PROJECTED_CREATE" | jq -er '.result.tab.tab_id') \
  || fail "could not read the projected tab"
PROJECTED_PANE=$(printf '%s' "$PROJECTED_CREATE" | jq -er '.result.root_pane.pane_id') \
  || fail "could not read the projected pane"
lab tab rename "$PROJECTED_TAB" fm-projected >/dev/null \
  || fail "could not name the projected task tab"

INTERMEDIATE_CREATE=$(lab workspace create --cwd "$TMP_ROOT/another-project" --label owner-intermediate --no-focus) \
  || fail "could not create the intermediate owner workspace"
INTERMEDIATE_WORKSPACE=$(printf '%s' "$INTERMEDIATE_CREATE" | jq -er '.result.workspace.workspace_id') \
  || fail "could not read the intermediate owner workspace"

FIRST_MOVE=$(lab pane move "$OWNER_OLD_PANE" --workspace "$INTERMEDIATE_WORKSPACE" --new-tab \
  --label owner-intermediate --no-focus) || fail "could not move the owner to the intermediate workspace"
INTERMEDIATE_OWNER_PANE=$(printf '%s' "$FIRST_MOVE" | jq -er '.result.move_result.pane.pane_id') \
  || fail "could not read the intermediate owner pane"

INTERMEDIATE_CHILD_CREATE=$(lab tab create --workspace "$INTERMEDIATE_WORKSPACE" --cwd "$HOME_DIR" \
  --label intermediate-child --no-focus) || fail "could not create the intermediate-workspace child"
INTERMEDIATE_CHILD_TAB=$(printf '%s' "$INTERMEDIATE_CHILD_CREATE" | jq -er '.result.tab.tab_id') \
  || fail "could not read the intermediate-workspace child tab"
INTERMEDIATE_CHILD_PANE=$(printf '%s' "$INTERMEDIATE_CHILD_CREATE" | jq -er '.result.root_pane.pane_id') \
  || fail "could not read the intermediate-workspace child pane"
lab tab rename "$INTERMEDIATE_CHILD_TAB" renamed-intermediate-child >/dev/null \
  || fail "could not rename the intermediate-workspace child tab"

CURRENT_CREATE=$(lab workspace create --cwd "$HOME_DIR" --label owner-current --no-focus) \
  || fail "could not create the current owner workspace"
CURRENT_WORKSPACE=$(printf '%s' "$CURRENT_CREATE" | jq -er '.result.workspace.workspace_id') \
  || fail "could not read the current owner workspace"

for pane in "$INTERMEDIATE_OWNER_PANE" "$OLD_CHILD_PANE" "$INTERMEDIATE_CHILD_PANE" "$PROJECTED_PANE"; do
  lab pane run "$pane" 'sleep 300' >/dev/null || fail "could not start live process in $pane"
done
lab pane report-agent "$OLD_CHILD_PANE" --source fm-linear-inventory-live \
  --agent old-child --state idle >/dev/null || fail "could not register the flat child"
lab pane report-agent "$INTERMEDIATE_CHILD_PANE" --source fm-linear-inventory-live \
  --agent intermediate-child --state idle >/dev/null || fail "could not register the intermediate child"
lab pane report-agent "$PROJECTED_PANE" --source fm-linear-inventory-live \
  --agent projected --state idle >/dev/null || fail "could not register the projected child"

MOVE=$(lab pane move "$INTERMEDIATE_OWNER_PANE" --workspace "$CURRENT_WORKSPACE" --new-tab \
  --label renamed-owner --no-focus) || fail "could not move the owner across workspaces again"
OWNER_PANE=$(printf '%s' "$MOVE" | jq -er '.result.move_result.pane.pane_id') \
  || fail "could not read the moved owner pane"
lab pane report-agent "$OWNER_PANE" --source fm-linear-inventory-live \
  --agent buildboard --state idle >/dev/null || fail "could not register the moved owner"

CANONICAL_HOME=$(CDPATH='' cd -- "$HOME_DIR" && pwd -P)
PATH="$FAKEBIN:$ORIGINAL_PATH" bash -c '
  . "$1/bin/backends/herdr.sh"
  journal=$(fm_backend_herdr_projection_journal_path "$2/state" projected)
  fm_backend_herdr_projection_journal_bind "$journal" projected "$2" "$3" \
    "$4" "$5" "$6" "$7" buildboard "$8" fm-projected
' _ "$ROOT" "$CANONICAL_HOME" "$SESSION" "$PROJECTED_WORKSPACE" "$PROJECTED_TAB" \
  "$PROJECTED_PANE" "$REGISTERED_WORKSPACE" "$PROJECTION_LABEL" \
  || fail "could not bind the live projection journal"

cat > "$PRIMARY_HOME/state/buildboard.meta" <<EOF
window=$SESSION:$OWNER_PANE
endpoint_task_id=buildboard
worktree=$CANONICAL_HOME
project=$CANONICAL_HOME
harness=codex
kind=secondmate
home=$CANONICAL_HOME
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$REGISTERED_WORKSPACE
herdr_tab_id=$OWNER_OLD_TAB
herdr_pane_id=$OWNER_PANE
EOF

cat > "$HOME_DIR/state/old-child.meta" <<EOF
backend=herdr
window=$SESSION:$OLD_CHILD_PANE
herdr_session=$SESSION
herdr_workspace_id=$REGISTERED_WORKSPACE
herdr_tab_id=$OLD_CHILD_TAB
herdr_pane_id=$OLD_CHILD_PANE
EOF

OUT=$(PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  "$ROOT/bin/fm-herdr-linear-reconcile.sh" --inventory 2>&1) && RC=0 || RC=$?
[ "$RC" -ne 0 ] || fail "an unrecorded worker in the intermediate owner workspace produced a false clean"
case "$OUT" in
  *'owner workspace history is unproven; inspect Herdr manually'*) ;;
  *) fail "the unrecorded intermediate worker diagnostic drifted: $OUT" ;;
esac
pass "real Herdr inventory requests inspection for unproven owner workspace history"

cat > "$HOME_DIR/state/intermediate-child.meta" <<EOF
backend=herdr
window=$SESSION:$INTERMEDIATE_CHILD_PANE
herdr_session=$SESSION
herdr_workspace_id=$INTERMEDIATE_WORKSPACE
herdr_tab_id=$INTERMEDIATE_CHILD_TAB
herdr_pane_id=$INTERMEDIATE_CHILD_PANE
EOF

OUT=$(PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  "$ROOT/bin/fm-herdr-linear-reconcile.sh" --inventory) \
  || fail "real Herdr inventory could not reconcile the twice-moved owner"
printf '%s' "$OUT" | jq -e \
  --arg session "$SESSION" \
  --arg owner "$OWNER_PANE" \
  --arg old_child "$OLD_CHILD_PANE" \
  --arg intermediate_child "$INTERMEDIATE_CHILD_PANE" \
  --arg projected "$PROJECTED_PANE" '
    .schema == "fm-herdr-linear-inventory.v1"
    and .ownership_status == "verified"
    and (.children | length) == 3
    and any(.children[];
      .task_id == "old-child" and .herdr_session == $session
      and .herdr_pane_id == $old_child and .endpoint_status == "alive")
    and any(.children[];
      .task_id == "intermediate-child" and .herdr_session == $session
      and .herdr_pane_id == $intermediate_child and .endpoint_status == "alive")
    and any(.children[];
      .task_id == "projected" and .herdr_session == $session
      and .herdr_pane_id == $projected and .endpoint_status == "alive")
    and ([.children[] | select(.herdr_pane_id == $owner)] | length) == 0
    and ([.children[] | select(.task_id == "renamed-owner")] | length) == 0
  ' >/dev/null || fail "real Herdr inventory lost owned workers or counted the moved owner: $OUT"

STATUS=$(lab status --json) || fail "could not read the tested Herdr version"
VERSION=$(printf '%s' "$STATUS" | jq -er '.client.version') \
  || fail "could not read the tested Herdr client version"
PROTOCOL=$(printf '%s' "$STATUS" | jq -er '.client.protocol') \
  || fail "could not read the tested Herdr protocol"
pass "real Herdr inventory keeps workers after repeated owner moves and tab renames"
pass "real Herdr inventory excludes the exact moved owner pane"
printf 'evidence: herdr %s protocol=%s\n' "$VERSION" "$PROTOCOL"
