#!/usr/bin/env bash
# Behavior tests for bin/fm-codex-account-quota.sh: the Codex store a worker
# from this home would launch on is measured under its own CODEX_HOME, and its
# quota facts and uncertainty are printed, never a choice.
#
# A fake quota-axi answers from $CODEX_HOME/quota.json, the way the real
# --profile-only read answers from that store's own credential file, and logs
# the store and arguments of every read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-account-quota)
TOOL="$ROOT/bin/fm-codex-account-quota.sh"

# new_case <name> -> sets CASE HOME_DIR FAKEBIN
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  FAKEBIN="$CASE/fakebin"
  mkdir -p "$HOME_DIR/config" "$FAKEBIN" "$CASE/user-home"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s %s %s\n' "\${CODEX_HOME-unset}" "\${QUOTA_AXI_SNAPSHOT-unset}" "\$*" >> '$CASE/reads'
[ -f "\${CODEX_HOME-}/quota.json" ] || exit 1
cat "\$CODEX_HOME/quota.json"
[ ! -f "\$CODEX_HOME/exit-1" ] || exit 1
SH
  chmod +x "$FAKEBIN/quota-axi"
}

# store <dir> <all_models-percent> <all_models-spendPriority> [runway] [model-scope-spendPriority]
# A Codex store whose profile-only read reports these numbers.
store() {
  local dir=$1 pct=$2 sp=$3 runway=${4:-through_reset} model_sp=${5:-}
  mkdir -p "$dir"
  jq -n --argjson pct "$pct" --argjson sp "$sp" --arg runway "$runway" --arg model_sp "$model_sp" '{
    schemaVersion: 5,
    providers: [{
      provider: "codex",
      state: {status: "fresh", stale: false},
      quotaSemantics: {
        status: "known",
        effectiveAvailability: ([
          {scope: "all_models", status: "known", effectivePercentRemaining: $pct,
           runway: {status: $runway, projectionConfidence: "established"},
           selection: {spendPriority: $sp}}
        ] + (if $model_sp == "" then [] else [
          {scope: "model:gpt-6-astra", status: "known", effectivePercentRemaining: 40,
           runway: {status: "through_reset"}, selection: {spendPriority: ($model_sp | tonumber)}}
        ] end))
      }
    }]
  }' > "$dir/quota.json"
}

# signed_out_store <dir>: a store with no login, which quota-axi reports with
# exit 1 and a snapshot naming that state.
signed_out_store() {
  mkdir -p "$1"
  jq -n '{
    schemaVersion: 5,
    providers: [{
      provider: "codex",
      windows: [],
      state: {status: "unavailable", stale: false, error: "Codex profile credentials missing"},
      accountKeys: ["codex-home"],
      quotaSemantics: {status: "unknown", effectiveAvailability: []},
      notSetUp: true
    }]
  }' > "$1/quota.json"
  : > "$1/exit-1"
}

# run_tool [--codex-home <dir>] [tool args...]
run_tool() {
  local -a ambient=()
  if [ "${1-}" = --codex-home ]; then
    ambient=("CODEX_HOME=$2")
    shift 2
  fi
  env -i HOME="$CASE/user-home" PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    QUOTA_AXI_SNAPSHOT="$CASE/shared-fixture.json" ${ambient[@]+"${ambient[@]}"} "$TOOL" "$@" 2>&1
}

assert_no_choice() {
  assert_not_contains "$1" "--account" "the tool must not print a chosen account"
  assert_not_contains "$1" "status: " "the tool must not print a verdict status"
  assert_not_contains "$1" "eligible" "the tool must not judge eligibility"
}

reads_once() {
  local count
  count=$(wc -l < "$CASE/reads" | tr -d ' ')
  expect_code 1 "$count" "exactly one store should be read: $(cat "$CASE/reads")"
}

test_a_pinned_store_is_measured_over_the_ambient_one() {
  local out rc
  new_case pin
  store "$CASE/pinned" 100 1.19
  store "$CASE/ambient" 7 0.2
  store "$CASE/user-home/.codex" 7 0.2
  printf '%s\n' "$CASE/pinned" > "$HOME_DIR/config/codex-account"
  out=$(run_tool --codex-home "$CASE/ambient"); rc=$?
  expect_code 0 "$rc" "measuring a pinned store should succeed: $out"
  assert_contains "$out" "codex-account-quota:" "the block should be named"
  assert_contains "$out" "row: $CASE/pinned  root=$CASE/pinned  scope=all_models  status=known  remaining=100%  spendPriority=1.19  runway=through_reset  confidence=established" \
    "the pinned store's own row should be shown"
  assert_not_contains "$out" "remaining=7%" "neither the ambient nor the default store answers for a pin"
  assert_grep "$CASE/pinned unset --provider codex --profile-only --json" "$CASE/reads" "the pinned store should be read in isolation, with no shared snapshot"
  reads_once
  assert_no_choice "$out"
  pass "config/codex-account selects the measured store over an ambient CODEX_HOME"
}

test_an_ordinary_pin_is_measured_from_the_default_store() {
  local out
  new_case ordinary
  store "$CASE/user-home/.codex" 55 0.6
  store "$CASE/ambient" 100 1.19
  printf 'ordinary\n' > "$HOME_DIR/config/codex-account"
  out=$(run_tool --codex-home "$CASE/ambient")
  assert_contains "$out" "row: ordinary  root=$CASE/user-home/.codex  scope=all_models  status=known  remaining=55%  spendPriority=0.6" \
    "an ordinary pin should be measured from ~/.codex"
  assert_not_contains "$out" "remaining=100%" "an ordinary pin launches with CODEX_HOME unset, so the ambient store does not answer"
  assert_grep "$CASE/user-home/.codex unset --provider codex --profile-only --json" "$CASE/reads" "ordinary should be read from ~/.codex"
  reads_once
  assert_no_choice "$out"
  pass "an ordinary pin is measured from the default ~/.codex store"
}

test_an_unpinned_home_measures_the_ambient_store() {
  local out
  new_case ambient
  store "$CASE/ambient" 100 1.19 through_reset 0.9
  store "$CASE/user-home/.codex" 7 0.2
  out=$(run_tool --codex-home "$CASE/ambient" --model gpt-6-astra)
  assert_contains "$out" "row: ambient  root=$CASE/ambient  scope=all_models  status=known  remaining=100%  spendPriority=1.19" \
    "an unpinned home should measure the ambient CODEX_HOME a worker inherits"
  assert_contains "$out" "row: ambient  root=$CASE/ambient  scope=model:gpt-6-astra  status=known  remaining=40%  spendPriority=0.9" \
    "the model's own scope should be printed"
  assert_not_contains "$out" "remaining=7%" "the default store does not answer for an ambient CODEX_HOME"
  assert_grep "$CASE/ambient unset --provider codex --profile-only --json" "$CASE/reads" "the ambient store should be read in isolation"
  out=$(run_tool --codex-home "$CASE/ambient")
  assert_not_contains "$out" "scope=model:gpt-6-astra" "a model scope does not apply without --model"
  assert_no_choice "$out"
  pass "an unpinned home measures the ambient CODEX_HOME store"
}

test_an_unpinned_home_without_codex_home_measures_the_default() {
  local out
  new_case default
  store "$CASE/user-home/.codex" 7 0.2
  out=$(run_tool)
  assert_contains "$out" "row: default  root=$CASE/user-home/.codex  scope=all_models  status=known  remaining=7%  spendPriority=0.2" \
    "with no pin and no CODEX_HOME the default ~/.codex store should be measured"
  assert_grep "$CASE/user-home/.codex unset --provider codex --profile-only --json" "$CASE/reads" "the default store should be read from ~/.codex"
  reads_once
  out=$(run_tool --codex-home "")
  assert_contains "$out" "row: default  root=$CASE/user-home/.codex" "an empty CODEX_HOME is the default store"
  assert_no_choice "$out"
  pass "an unpinned home with no CODEX_HOME measures the default ~/.codex store"
}

test_an_unreadable_store_is_uncertainty() {
  local out rc
  new_case unreadable
  mkdir -p "$CASE/blank"
  printf '%s\n' "$CASE/blank" > "$HOME_DIR/config/codex-account"
  out=$(run_tool); rc=$?
  expect_code 0 "$rc" "an unreadable store is a reading, not a refusal: $out"
  assert_contains "$out" "row: $CASE/blank  root=$CASE/blank  uncertainty: quota-axi could not read this account" \
    "a store quota-axi cannot read should be disclosed uncertainty"
  assert_not_contains "$out" "scope=" "an unreadable store prints no scope"
  assert_no_choice "$out"
  pass "a store quota-axi cannot read is disclosed uncertainty"
}

test_a_nonzero_read_with_a_snapshot_keeps_its_reason() {
  local out rc
  new_case signed-out
  signed_out_store "$CASE/ambient"
  out=$(run_tool --codex-home "$CASE/ambient"); rc=$?
  expect_code 0 "$rc" "a failed measurement is a reading, not a refusal: $out"
  assert_contains "$out" "row: ambient  root=$CASE/ambient  uncertainty: quota unknown (unavailable: Codex profile credentials missing)" \
    "a nonzero read that still prints a snapshot should keep quota-axi's own reason"
  assert_contains "$out" "row: ambient  root=$CASE/ambient  uncertainty: no applicable quota scope" "no scope applies to an unknown read"
  assert_not_contains "$out" "could not read" "a snapshot naming its state is not an unreadable store"
  assert_no_choice "$out"
  pass "a nonzero quota-axi exit that prints a snapshot keeps the vendor's reason"
}

test_a_refused_pin_reads_nothing() {
  local out rc
  new_case refuse
  printf 'relative\n' > "$HOME_DIR/config/codex-account"
  out=$(run_tool); rc=$?
  expect_code 2 "$rc" "a malformed pin must refuse"
  assert_contains "$out" "config/codex-account must hold 'ordinary' or one absolute path" "the refusal should name the format"
  printf '%s\n' "$CASE/missing" > "$HOME_DIR/config/codex-account"
  out=$(run_tool); rc=$?
  expect_code 2 "$rc" "a pin naming a missing store must refuse"
  assert_contains "$out" "config/codex-account must name a readable, searchable existing directory" "the refusal should name the missing store"
  assert_absent "$CASE/reads" "a refused pin must not read any quota"
  pass "a malformed or missing pin refuses before any quota read"
}

test_missing_quota_axi_is_reported() {
  local out rc
  new_case missing-tool
  rm -f "$FAKEBIN/quota-axi"
  ln -s "$(command -v jq)" "$FAKEBIN/jq"
  ln -s "$BASH" "$FAKEBIN/bash"
  out=$(env -i HOME="$CASE/user-home" PATH="$FAKEBIN:/usr/bin:/bin" FM_HOME="$HOME_DIR" "$TOOL" 2>&1); rc=$?
  expect_code 0 "$rc" "a missing quota-axi is a reading: $out"
  assert_contains "$out" "error: quota-axi not installed" "a missing quota-axi should be named"
  pass "a missing quota-axi is reported in the block"
}

test_a_pinned_store_is_measured_over_the_ambient_one
test_an_ordinary_pin_is_measured_from_the_default_store
test_an_unpinned_home_measures_the_ambient_store
test_an_unpinned_home_without_codex_home_measures_the_default
test_an_unreadable_store_is_uncertainty
test_a_nonzero_read_with_a_snapshot_keeps_its_reason
test_a_refused_pin_reads_nothing
test_missing_quota_axi_is_reported

echo "# all fm-codex-account-quota tests passed"
