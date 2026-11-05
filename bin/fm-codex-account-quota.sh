#!/usr/bin/env bash
# fm-codex-account-quota.sh - measure the Codex store a native Codex worker
# from this home would launch on, in isolation, and print its quota facts.
#
# Usage:
#   fm-codex-account-quota.sh [--model <model>]
#
# The measured store is the one the launch selects:
#   config/codex-account present  its path, or ~/.codex for `ordinary`, after
#                                 bin/fm-worker-account-lib.sh's parsing and
#                                 refusals; the account column is the pin value
#   otherwise, CODEX_HOME set     that directory; the account column is `ambient`
#   otherwise                     ~/.codex; the account column is `default`
# and is read with
#   CODEX_HOME=<root> quota-axi --provider codex --profile-only --json
# --profile-only reads only that store's credential file, so the row is that
# store's own quota and never the default ~/.codex login's. QUOTA_AXI_SNAPSHOT
# is removed from the read so a shared fixture cannot answer for the store.
# quota-axi exits nonzero when it cannot measure a provider, for example a
# store with no login, yet still prints a valid snapshot naming that state;
# such a snapshot is kept, so the store is reported unmeasured with the
# vendor's own reason rather than as an unreadable store.
#
# The store binds to its snapshot's codex row and to the scopes that bound
# --model: all_models/all_products plus model:<id> and product:<id> for the
# bare id. This prints facts only; it never judges eligibility or picks a
# candidate. The quota-array-dispatch skill applies its gates and
# spendPriority ranking to these rows.
#
# Output (stdout, TOON-style block):
#   codex-account-quota:
#     row: <account>  root=<dir>  scope=<scope>  status=..  remaining=..%  spendPriority=..  runway=..  usableRunwaySeconds=..  confidence=..
#     row: <account>  root=<dir>  uncertainty: <why this store is not fully measured>
#   usableRunwaySeconds is that scope's own runway time from the same snapshot,
#   printed whenever quota-axi reports it and always for projected_exhaustion,
#   where `-` means the snapshot gave no finite time. confidence is the
#   runway's projectionConfidence, the default TOON's confidence column.
#   Uncertainty names a failed or invalid read, quota-axi's own unknown or
#   unavailable state and reason, a missing codex row, or no applicable scope.
#   A missing quota-axi prints `error: quota-axi not installed` in the block.
#   Readings exit 0. Exit 2 for a usage error or a config/codex-account that
#   bin/fm-worker-account-lib.sh refuses, which is actionable, never measured
#   around.
#
# Data only: this never launches Codex, checks a sign-in, writes a credential,
# or changes any home or account file. bin/fm-spawn.sh runs the sign-in check
# for the store a launch selects.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

FM_CODEX_ACCOUNT_QUOTA_SECONDS=${FM_CODEX_ACCOUNT_QUOTA_SECONDS:-60}

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

MODEL=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)
      [ -n "${2-}" ] || die "--model needs a value"
      MODEL=$2
      shift 2
      ;;
    --model=*)
      MODEL=${1#--model=}
      [ -n "$MODEL" ] || die "--model needs a value"
      shift
      ;;
    -h|--help|help) usage; exit 0 ;;
    *) die "unexpected argument: $1" ;;
  esac
done
[ "$MODEL" != default ] || MODEL=

command -v jq >/dev/null 2>&1 || die "jq is required"
SELECTION=$(fm_worker_account_resolve codex "$CONFIG" config/codex-account) || exit 2
if [ -n "$SELECTION" ]; then
  ACCOUNT=${SELECTION%%$'\t'*}
  STORE=${SELECTION#*$'\t'}
  STORE=${STORE%%$'\t'*}
elif [ -n "${CODEX_HOME:-}" ]; then
  ACCOUNT=ambient
  STORE=$CODEX_HOME
else
  ACCOUNT=default
  STORE=
fi
[ -n "$STORE" ] || STORE="${HOME:?HOME is required to measure the default Codex store}/.codex"

if ! command -v quota-axi >/dev/null 2>&1; then
  printf 'codex-account-quota:\n  error: quota-axi not installed\n'
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-account-quota.XXXXXX") || die "cannot create a scratch directory"
trap 'rm -rf "$WORK"' EXIT

ERROR=
if fm_run_timed "$FM_CODEX_ACCOUNT_QUOTA_SECONDS" env -u QUOTA_AXI_SNAPSHOT CODEX_HOME="$STORE" \
    quota-axi --provider codex --profile-only --json > "$WORK/snapshot.json" 2>/dev/null </dev/null; then
  fm_quota_json_valid < "$WORK/snapshot.json" || ERROR="quota-axi returned an invalid snapshot"
elif ! fm_quota_json_valid < "$WORK/snapshot.json"; then
  ERROR="quota-axi could not read this account"
fi
if [ -n "$ERROR" ]; then
  jq -cn --arg account "$ACCOUNT" --arg root "$STORE" --arg error "$ERROR" '{account: $account, root: $root, error: $error}'
else
  jq -c --arg account "$ACCOUNT" --arg root "$STORE" '{account: $account, root: $root, snapshot: .}' "$WORK/snapshot.json"
fi > "$WORK/store.json" || die "cannot record the quota reading for $STORE"

jq -r --arg model "$MODEL" '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($value): ($value // "-") | flat;
  def bare($m): ($m | split("/") | last);
  def applicable($row):
    bare($model) as $b |
    [$row.quotaSemantics.effectiveAvailability[]? | select(
      .scope == "all_models" or .scope == "all_products" or
      ($model != "" and (.scope == ("model:" + $b) or .scope == ("product:" + $b)))
    )];
  "codex-account-quota:",
  ("  row: \(.account | flat)  root=\(.root | flat)" as $head |
    if .error then "\($head)  uncertainty: \(.error | flat)"
    else
      ([.snapshot.providers[]? | select(.provider == "codex")] | first) as $row |
      if $row == null then "\($head)  uncertainty: no codex quota row"
      else
        applicable($row) as $rows |
        (if (["known", "partial"] | index($row.quotaSemantics.status)) == null then
          "\($head)  uncertainty: quota \(show($row.quotaSemantics.status))\(if $row.state.status then " (\($row.state.status | flat): \(show($row.state.error)))" else "" end)"
         else empty end),
        (if ($rows | length) == 0 then "\($head)  uncertainty: no applicable quota scope" else empty end),
        ($rows[] | "\($head)  scope=\(.scope | flat)  status=\(show(.status))  remaining=\(show(.effectivePercentRemaining))%  spendPriority=\(show(.selection.spendPriority))  runway=\(show(.runway.status))"
          + (if .runway.usableRunwaySeconds != null or .runway.status == "projected_exhaustion"
             then "  usableRunwaySeconds=\(show(.runway.usableRunwaySeconds))" else "" end)
          + ((.runway.projectionConfidence // .confidence) as $c | if $c then "  confidence=\($c | flat)" else "" end))
      end
    end)
' "$WORK/store.json" || die "cannot format the quota reading"
