#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-linear-check)
HOME_DIR="$TMP_ROOT/buildboard"
PRIMARY_HOME="$TMP_ROOT/primary"
OTHER_STATE="$TMP_ROOT/other-state"
mkdir -p "$HOME_DIR/bin" "$HOME_DIR/state" "$PRIMARY_HOME/data" "$OTHER_STATE"
for file in fm-herdr-linear-check.sh fm-check-register.sh fm-check-unregister.sh \
  fm-pr-lib.sh fm-check-lib.sh fm-env-lib.sh fm-primary-scope-lib.sh \
  fm-secondmate-parent-lib.sh fm-secondmate-registry-lib.sh fm-timeout-lib.sh; do
  cp "$ROOT/bin/$file" "$HOME_DIR/bin/$file"
done
chmod +x "$HOME_DIR/bin"/*.sh
printf '%s\n' buildboard > "$HOME_DIR/.fm-secondmate-home"
cat > "$HOME_DIR/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$PRIMARY_HOME
EOF
printf '%s\n' '- zues - Operating Studio delivery (home: /zeus; scope: Operating Studio; projects: operating-studio; added 2026-09-22)' > "$PRIMARY_HOME/data/secondmates.md"
cat > "$HOME_DIR/.env" <<'EOF'
FM_LINEAR_READONLY_API_KEY=read-only-secret
FM_LINEAR_OPERATING_STUDIO_TEAM_ID=team-os
FM_LINEAR_OPERATING_STUDIO_PROJECT_ID=project-os
EOF
chmod 0600 "$HOME_DIR/.env"
cat > "$HOME_DIR/bin/fm-herdr-linear-reconcile.sh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_HOME/state/fake-count" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$FM_HOME/state/fake-count"
printf '%s|%s|%s|%s|%s\n' "$LINEAR_API_KEY" "$FM_LINEAR_OPERATING_STUDIO_TEAM_ID" "$FM_LINEAR_OPERATING_STUDIO_PROJECT_ID" "$FM_STATE_OVERRIDE" "$FM_DATA_OVERRIDE" > "$FM_HOME/state/fake-env"
case "$(cat "$FM_HOME/state/fake-mode")" in
  match) printf '%s\n' '{"schema":"fm-herdr-linear-reconcile.v1","summary":{"needs_deep_check":0}}' ;;
  mismatch) printf '%s\n' '{"schema":"fm-herdr-linear-reconcile.v1","summary":{"needs_deep_check":2}}' ;;
  fail) printf '%s\n' 'live Zeus inventory unavailable' >&2; printf '%s\n' 'extra detail' >&2; exit 1 ;;
  hang) sleep 10 ;;
  *) printf '%s\n' '{"unexpected":true}' ;;
esac
SH
chmod 0755 "$HOME_DIR/bin/fm-herdr-linear-reconcile.sh"

CHECK="$HOME_DIR/bin/fm-herdr-linear-check.sh"

out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$OTHER_STATE" "$CHECK" arm) || fail "buildboard check did not arm"
[ "$out" = 'armed: state/herdr-linear-reconcile.check.sh' ] || fail "arm output drifted: $out"
FM_HOME="$HOME_DIR" "$CHECK" arm >/dev/null || fail "second arm was not idempotent"
[ ! -e "$OTHER_STATE/herdr-linear-reconcile.check.sh" ] || fail "arm used an inherited state override"
(
  . "$HOME_DIR/bin/fm-pr-lib.sh"
  . "$HOME_DIR/bin/fm-check-lib.sh"
  fm_custom_check_registered "$HOME_DIR/state" herdr-linear-reconcile
) || fail "arm did not produce a trusted custom check"
pass "persistent buildboard arms one trusted check idempotently"

printf '%s\n' match > "$HOME_DIR/state/fake-mode"
out=$(FM_LINEAR_READONLY_API_KEY=stale-key \
  FM_LINEAR_OPERATING_STUDIO_TEAM_ID=stale-team \
  FM_LINEAR_OPERATING_STUDIO_PROJECT_ID=stale-project \
  FM_STATE_OVERRIDE="$OTHER_STATE" \
  FM_HERDR_LINEAR_CHECK_NOW=1000 "$HOME_DIR/state/herdr-linear-reconcile.check.sh") || fail "matching watcher shim failed"
[ -z "$out" ] || fail "matching reconciliation was not silent: $out"
[ "$(cat "$HOME_DIR/state/fake-env")" = "read-only-secret|team-os|project-os|$HOME_DIR/state|$PRIMARY_HOME/data" ] \
  || fail "check did not load fresh buildboard configuration and the primary Zeus registry route"

printf '%s\n' mismatch > "$HOME_DIR/state/fake-mode"
out=$(FM_HOME="$HOME_DIR" FM_HERDR_LINEAR_CHECK_NOW=1200 "$CHECK" check) || fail "cadence-gated check failed"
[ -z "$out" ] || fail "check ran before its 15-minute cadence: $out"
[ "$(cat "$HOME_DIR/state/fake-count")" = 1 ] || fail "cadence gate invoked reconciliation early"

out=$(FM_HOME="$HOME_DIR" FM_HERDR_LINEAR_CHECK_NOW=1900 "$CHECK" check) || fail "mismatch check failed"
[ "$out" = 'Operating Studio reconciliation needs deep inspection: 2 discrepancy(s); run bin/fm-herdr-linear-check.sh inspect from buildboard' ] \
  || fail "mismatch did not emit one actionable line: $out"
pass "check is silent on match and reports mismatch every due interval"

out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$OTHER_STATE" "$CHECK" inspect) \
  || fail "one-shot inspection failed"
[ "$out" = '{"schema":"fm-herdr-linear-reconcile.v1","summary":{"needs_deep_check":2}}' ] \
  || fail "one-shot inspection did not print the reconciliation result: $out"
[ "$(cat "$HOME_DIR/state/fake-env")" = "read-only-secret|team-os|project-os|$HOME_DIR/state|$PRIMARY_HOME/data" ] \
  || fail "one-shot inspection bypassed buildboard configuration or the primary route"
pass "one-shot inspection uses buildboard configuration and primary routing"

EXTERNAL_ENV="$TMP_ROOT/operating-studio-linear.env"
cat > "$EXTERNAL_ENV" <<'EOF'
LINEAR_API_KEY=external-read-only-secret
EOF
rm -f "$HOME_DIR/.env"
out=$(FM_HOME="$HOME_DIR" FM_LINEAR_CONFIG_FILE="$EXTERNAL_ENV" \
  FM_LINEAR_OPERATING_STUDIO_TEAM_ID=external-team \
  FM_LINEAR_OPERATING_STUDIO_PROJECT_ID=external-project \
  "$CHECK" inspect) || fail "one-shot inspection could not reference external Linear configuration"
[ "$out" = '{"schema":"fm-herdr-linear-reconcile.v1","summary":{"needs_deep_check":2}}' ] \
  || fail "external-config inspection did not print the reconciliation result: $out"
[ "$(cat "$HOME_DIR/state/fake-env")" = "external-read-only-secret|external-team|external-project|$HOME_DIR/state|$PRIMARY_HOME/data" ] \
  || fail "inspection did not consume the referenced Linear configuration"
pass "one-shot inspection can reference read-only Linear configuration"

cat > "$HOME_DIR/.env" <<'EOF'
FM_LINEAR_READONLY_API_KEY=read-only-secret
FM_LINEAR_OPERATING_STUDIO_TEAM_ID=team-os
FM_LINEAR_OPERATING_STUDIO_PROJECT_ID=project-os
EOF
chmod 0600 "$HOME_DIR/.env"

printf '%s\n' fail > "$HOME_DIR/state/fake-mode"
out=$(FM_HOME="$HOME_DIR" FM_HERDR_LINEAR_CHECK_NOW=2800 "$CHECK" check) || fail "failure check did not preserve watcher contract"
[ "$out" = 'Operating Studio reconciliation check failed: live Zeus inventory unavailable; run bin/fm-herdr-linear-check.sh inspect from buildboard' ] \
  || fail "failure did not emit one actionable line: $out"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "failure emitted more than one line"
pass "check converts reconciliation failure into one actionable line"

printf '%s\n' hang > "$HOME_DIR/state/fake-mode"
out=$(FM_HOME="$HOME_DIR" FM_CHECK_TIMEOUT=4 FM_HERDR_LINEAR_CHECK_NOW=3700 "$CHECK" check) || fail "bounded check did not preserve watcher contract"
[ "$out" = 'Operating Studio reconciliation check failed: reconciliation exceeded its 1-second internal budget; run bin/fm-herdr-linear-check.sh inspect from buildboard' ] \
  || fail "timeout did not emit one actionable line: $out"
for artifact in "$HOME_DIR/state"/.fm-herdr-linear-output.* "$HOME_DIR/state"/.fm-herdr-linear-error.*; do
  [ ! -e "$artifact" ] || fail "timeout left private temporary state: $artifact"
done
pass "internal timeout reports once and removes private temporary files"

rm -f "$HOME_DIR/state/.herdr-linear-reconcile-check"
ln -s "$TMP_ROOT/cadence-target" "$HOME_DIR/state/.herdr-linear-reconcile-check"
printf '%s\n' match > "$HOME_DIR/state/fake-mode"
out=$(FM_HOME="$HOME_DIR" FM_HERDR_LINEAR_CHECK_NOW=4600 "$CHECK" check) || fail "cadence persistence failure did not preserve watcher contract"
[ "$out" = 'Operating Studio reconciliation check failed: cadence state could not be saved; inspect buildboard state permissions and rerun the check' ] \
  || fail "cadence persistence failure was silent or unclear: $out"
rm -f "$HOME_DIR/state/.herdr-linear-reconcile-check"
pass "cadence persistence failure emits one actionable line"

printf '%s\n' another-mate > "$HOME_DIR/.fm-secondmate-home"
out=$(FM_HOME="$HOME_DIR" "$CHECK" arm 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "another secondmate armed the buildboard check"
case "$out" in *'only the persistent buildboard home may arm'*) ;; *) fail "wrong-owner refusal drifted: $out" ;; esac
pass "only persistent buildboard may own the reconciliation check"

printf '%s\n' 'all fm-herdr-linear-check tests passed'
