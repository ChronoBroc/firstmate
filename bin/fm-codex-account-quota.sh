#!/usr/bin/env bash
# fm-codex-account-quota.sh - measure the Codex store a native Codex worker
# from this home would launch on, in isolation, and print its quota facts.
#
# Usage:
#   fm-codex-account-quota.sh [--model <model>] [--quota-scope <scope>]
#
# The measured store is the one the launch selects:
#   config/codex-account present  its path, or ~/.codex for `ordinary`, after
#                                 bin/fm-worker-account-lib.sh's parsing and
#                                 refusals; the account column is the pin value
#   otherwise, an inherited       that directory; the account column is `ambient`
#   CODEX_HOME
#   otherwise                     ~/.codex; the account column is `default`
# An unpinned launch adds no CODEX_HOME, so the worker pane inherits it from
# the backend that creates the pane, which bin/fm-backend.sh resolves as a
# spawn does. On tmux that is the destination session's environment (the
# current session inside tmux, else `firstmate`), then tmux's global
# environment, since a pane does not inherit this process's own environment; a
# variable tmux marks removed is no CODEX_HOME. With no tmux server running, or
# on any other backend, the pane inherits this process's own CODEX_HOME, as a
# server fm-spawn starts would.
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
# bare id, plus --quota-scope, the profile's declared quota_scope, when given.
# This prints facts only; it never judges eligibility or picks a
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
# starts a tmux server or session, or changes any home or account file. bin/fm-spawn.sh runs the sign-in check
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
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

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
QUOTA_SCOPE=
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
    --quota-scope)
      [ -n "${2-}" ] || die "--quota-scope needs a value"
      QUOTA_SCOPE=$2
      shift 2
      ;;
    --quota-scope=*)
      QUOTA_SCOPE=${1#--quota-scope=}
      [ -n "$QUOTA_SCOPE" ] || die "--quota-scope needs a value"
      shift
      ;;
    -h|--help|help) usage; exit 0 ;;
    *) die "unexpected argument: $1" ;;
  esac
done
[ "$MODEL" != default ] || MODEL=

command -v jq >/dev/null 2>&1 || die "jq is required"

# tmux_codex_home_entry <show-environment target args>: the CODEX_HOME entry
# in that tmux environment (`CODEX_HOME=<dir>`, `-CODEX_HOME` when removed, or
# empty when absent); fails when tmux cannot answer for that target.
tmux_codex_home_entry() {
  local env
  env=$(tmux show-environment "$@" 2>/dev/null) || return 1
  printf '%s\n' "$env" | awk '/^CODEX_HOME=/ || /^-CODEX_HOME$/ { print; exit }'
}

# inherited_codex_home: the CODEX_HOME a new unpinned worker pane inherits,
# empty for none.
inherited_codex_home() {
  local global session entry
  fm_backend_resolve 2>/dev/null
  if [ "$FM_BACKEND_RESOLVED" = tmux ] && fm_backend_source tmux >/dev/null 2>&1 \
      && global=$(tmux_codex_home_entry -g); then
    if [ -n "${TMUX:-}" ]; then
      session=$(fm_backend_tmux_own_session 2>/dev/null)
    else
      session=firstmate
    fi
    entry=
    [ -z "$session" ] || entry=$(tmux_codex_home_entry -t "$session") || entry=
    [ -n "$entry" ] || entry=$global
    case "$entry" in
    CODEX_HOME=*) printf '%s' "${entry#CODEX_HOME=}" ;;
    esac
  else
    printf '%s' "${CODEX_HOME:-}"
  fi
}

SELECTION=$(fm_worker_account_resolve codex "$CONFIG" config/codex-account) || exit 2
if [ -n "$SELECTION" ]; then
  ACCOUNT=${SELECTION%%$'\t'*}
  STORE=${SELECTION#*$'\t'}
  STORE=${STORE%%$'\t'*}
else
  STORE=$(inherited_codex_home)
  if [ -n "$STORE" ]; then
    ACCOUNT=ambient
  else
    ACCOUNT=default
  fi
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

jq -r --arg model "$MODEL" --arg qs "$QUOTA_SCOPE" '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($value): ($value // "-") | flat;
  def bare($m): ($m | split("/") | last);
  def applicable($row):
    bare($model) as $b |
    [$row.quotaSemantics.effectiveAvailability[]? | select(
      .scope == "all_models" or .scope == "all_products" or
      ($model != "" and (.scope == ("model:" + $b) or .scope == ("product:" + $b))) or
      ($qs != "" and .scope == $qs)
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
