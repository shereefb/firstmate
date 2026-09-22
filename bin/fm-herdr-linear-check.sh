#!/usr/bin/env bash
# fm-herdr-linear-check.sh - recurring Operating Studio reconciliation check.
#
# Usage:
#   fm-herdr-linear-check.sh [check]
#   fm-herdr-linear-check.sh arm
#   fm-herdr-linear-check.sh retire
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="$FM_HOME/state"
CHECK_ID=herdr-linear-reconcile
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
RECORD="$STATE/.herdr-linear-reconcile-check"
ENV_FILE="$FM_HOME/.env"
INTERVAL=900

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-herdr-linear-check.sh [check]   reconcile when the 15-minute interval is due
  fm-herdr-linear-check.sh arm       arm the trusted buildboard custom check
  fm-herdr-linear-check.sh retire    retire the custom check and cadence record
EOF
}

owner_valid() {
  local owner
  fm_root_is_secondmate_home "$FM_HOME" || return 1
  owner=$(cat "$FM_HOME/.fm-secondmate-home" 2>/dev/null) || return 1
  [ "$owner" = buildboard ]
}

now_epoch() {
  case "${FM_HERDR_LINEAR_CHECK_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_HERDR_LINEAR_CHECK_NOW" ;;
  esac
}

record_epoch() {
  local epoch
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || { printf '0\n'; return 0; }
  IFS= read -r epoch < "$RECORD" || epoch=0
  case "$epoch" in ''|*[!0-9]*) epoch=0 ;; esac
  printf '%s\n' "$epoch"
}

record_write() {
  local epoch=$1 device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$RECORD" "$device" || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-herdr-linear-check.XXXXXX") || return 1
  if ! printf '%s\n' "$epoch" > "$tmp" || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$RECORD" "$device" \
    || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

one_line() {
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-1000
}

credential_value() {
  local key=$1 current=$2
  if [ -n "$current" ]; then
    printf '%s' "$current"
  else
    fmx_env_get "$key" "$ENV_FILE"
  fi
}

action_check() {
  local now previous api_key team_id project_id output_file error_file detail count rc
  now=$(now_epoch)
  previous=$(record_epoch)
  if [ "$previous" -gt 0 ] && [ "$now" -ge "$previous" ] \
    && [ $((now - previous)) -lt "$INTERVAL" ]; then
    return 0
  fi

  if ! owner_valid; then
    printf '%s\n' 'Operating Studio reconciliation check failed: this trusted check must run from the persistent buildboard home; retire it here and arm it from buildboard'
    record_write "$now" 2>/dev/null || true
    return 0
  fi

  api_key=$(credential_value FM_LINEAR_READONLY_API_KEY "${FM_LINEAR_READONLY_API_KEY:-}")
  team_id=$(credential_value FM_LINEAR_OPERATING_STUDIO_TEAM_ID "${FM_LINEAR_OPERATING_STUDIO_TEAM_ID:-}")
  project_id=$(credential_value FM_LINEAR_OPERATING_STUDIO_PROJECT_ID "${FM_LINEAR_OPERATING_STUDIO_PROJECT_ID:-}")
  if [ -z "$api_key" ] || [ -z "$team_id" ] || [ -z "$project_id" ]; then
    printf '%s\n' 'Operating Studio reconciliation check failed: buildboard .env needs FM_LINEAR_READONLY_API_KEY, FM_LINEAR_OPERATING_STUDIO_TEAM_ID, and FM_LINEAR_OPERATING_STUDIO_PROJECT_ID; add them and rerun the check'
    record_write "$now" 2>/dev/null || true
    return 0
  fi

  output_file=$(mktemp "$STATE/.fm-herdr-linear-output.XXXXXX") || {
    printf '%s\n' 'Operating Studio reconciliation check failed: could not create private result storage; inspect buildboard state permissions and rerun the check'
    return 0
  }
  error_file=$(mktemp "$STATE/.fm-herdr-linear-error.XXXXXX") || {
    rm -f -- "$output_file"
    printf '%s\n' 'Operating Studio reconciliation check failed: could not create private error storage; inspect buildboard state permissions and rerun the check'
    return 0
  }
  LINEAR_API_KEY="$api_key" \
    FM_LINEAR_OPERATING_STUDIO_TEAM_ID="$team_id" \
    FM_LINEAR_OPERATING_STUDIO_PROJECT_ID="$project_id" \
    "$SCRIPT_DIR/fm-herdr-linear-reconcile.sh" --linear-api > "$output_file" 2> "$error_file"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    detail=$(sed -n '/./{p;q;}' "$error_file")
    [ -n "$detail" ] || detail="reconciliation exited $rc without a diagnostic"
    printf 'Operating Studio reconciliation check failed: %s; run bin/fm-herdr-linear-reconcile.sh --linear-api from buildboard\n' "$(one_line "$detail")"
  elif ! count=$(jq -er '
      select(.schema == "fm-herdr-linear-reconcile.v1")
      | .summary.needs_deep_check
      | select(type == "number" and . >= 0 and floor == .)
    ' "$output_file" 2>/dev/null); then
    printf '%s\n' 'Operating Studio reconciliation check failed: reconciliation returned an invalid result; run bin/fm-herdr-linear-reconcile.sh --linear-api from buildboard'
  elif [ "$count" -gt 0 ]; then
    printf 'Operating Studio reconciliation needs deep inspection: %s discrepancy(s); run bin/fm-herdr-linear-reconcile.sh --linear-api from buildboard\n' "$count"
  fi
  rm -f -- "$output_file" "$error_file"
  record_write "$now" 2>/dev/null || true
  return 0
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "export FM_STATE_OVERRIDE=$(printf '%q' "$home/state")" \
    "exec $(printf '%q' "$home/bin/fm-herdr-linear-check.sh") check"
}

action_arm() {
  local home want device tmp key
  owner_valid || {
    printf '%s\n' 'fm-herdr-linear-check: only the persistent buildboard home may arm this check' >&2
    return 1
  }
  for key in FM_LINEAR_READONLY_API_KEY FM_LINEAR_OPERATING_STUDIO_TEAM_ID FM_LINEAR_OPERATING_STUDIO_PROJECT_ID; do
    [ -n "$(fmx_env_get "$key" "$ENV_FILE")" ] || {
      printf 'fm-herdr-linear-check: %s is required in %s\n' "$key" "$ENV_FILE" >&2
      return 1
    }
  done
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  want=$(shim_content "$home")
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ] \
    && fm_custom_check_registered "$STATE" "$CHECK_ID"; then
    printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
    return 0
  fi
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-herdr-linear-check.XXXXXX") || return 1
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM" \
    || ! FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f -- "$tmp"
    FM_HOME="$home" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null 2>&1 || true
    printf 'fm-herdr-linear-check: could not arm state/%s.check.sh\n' "$CHECK_ID" >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_retire() {
  "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null || return 1
  rm -f -- "$RECORD"
  printf 'retired: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  retire) action_retire ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
