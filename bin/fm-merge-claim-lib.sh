#!/usr/bin/env bash
# fm-merge-claim-lib.sh - an outcome may call a PR merged only on proof.
#
# ONE OWNER of the merge-claim check that bin/fm-branch-outcome.sh append runs
# for every supervision-branch outcome, from both report surfaces (the Pi
# branch extension's fm_branch_report tool and bin/fm-branch-report.sh). A
# worker's own wording is never proof: "landed" in a worker's status can mean
# it merged main into its branch and pushed it while its PR is still open, and
# an outcome that turns that into "is merged" or "is on main" tells the captain
# a merge happened that did not.
#
# A claim is affirmative merge wording in the summary: the word "merged" or
# "landed", or "is/now/landed/already on|in main|master". The word is not a
# claim when one of the three words before it in its own clause negates or
# defers it ("not", "n't", "once", "to be", "awaiting", "ready", ...), or when
# it describes merging main into a branch ("merged main into", "main <sha> merged",
# "auto-merged <file>"). An open PR is therefore never "landed" in an outcome
# either: that is the worker's word for what it did to its branch.
# A clause ends at sentence punctuation, a semicolon, or a line break. Each
# claim names the PR URL closest before it in its clause, else the first one
# after it in its clause, else the closest before it in the summary, else the
# first one after it, else the task's recorded pr=. A claim naming no PR at all
# is left alone, because there is nothing to verify it against.
# Proof is fm_pr_merge_proof (bin/fm-pr-lib.sh): this home's merge record or the
# forge's live state, read within FM_MERGE_CLAIM_TIMEOUT seconds (default 10).
#
# This is a confused-agent-grade wording check, not a parser of intent: it
# refuses the common false claim and tells the branch exactly what to write
# instead, and a refused report is reworded and sent again.

_FM_MERGE_CLAIM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_MERGE_CLAIM_LIB_DIR/fm-timeout-lib.sh"

# Read by callers after a refusal.
# shellcheck disable=SC2034
FM_MERGE_CLAIM_REFUSAL=

# _fm_merge_claim_urls: read a summary on stdin and print, once per merge
# claim, the PR URL that claim names ("" when the summary names none).
_fm_merge_claim_urls() {
  perl -e '
    use strict; use warnings;
    local $/; my $s = <STDIN>; $s = "" unless defined $s;
    my $l = lc $s;
    my @urls;
    while ($s =~ m{https://[^\s<>()\[\]"\x27`,;]+}g) {
      my ($u, $p) = ($&, $-[0]);
      $u =~ s/[.:!?]+$//;
      push @urls, [$p, $u] if $u =~ m{/(?:pull|pulls|merge_requests)/[0-9]+$|/\+/[0-9]+$};
    }
    my @cut = (0);
    while ($l =~ /[.!?]+(?=\s|$)|[;\n]/g) { push @cut, $+[0]; }
    my $clause = sub { my $p = shift; my ($cs, $ce) = (0, length $l); for my $c (@cut) { $cs = $c if $c <= $p; } for my $c (@cut) { if ($c > $p) { $ce = $c; last; } } return ($cs, $ce); };
    my $defer = qr/^(?:not|never|no|yet|until|unless|before|once|when|whenever|after|if|whether|await|awaits|awaiting|wait|waits|waiting|ready|pending|can|cannot|will|would|should|could|may|might|must|need|needs|ask|asks|asking|asked|to|be|for|get|gets)$/;
    my @claims;
    while ($l =~ /\b(?:merged|landed)\b/g) {
      my $p = $-[0];
      my $before = substr($l, 0, $p);
      my $after = substr($l, $+[0]);
      next if $before =~ /-$/;
      next if $after =~ /^\s+(?:main|master|origin\/|upstream|the default branch|the latest main|in main|in the latest)\b/;
      my ($cs) = $clause->($p);
      my @w = (substr($l, $cs, $p - $cs) =~ /([a-z0-9\x27\/]+)/g);
      @w = @w[-3 .. -1] if @w > 3;
      next if grep { $_ =~ $defer || $_ =~ /n\x27t$/ } @w;
      next if @w && ($w[-1] =~ /^[0-9a-f]{7,40}$/ || $w[-1] eq "main" || $w[-1] eq "master");
      push @claims, $p;
    }
    while ($l =~ /\b(?:is|are|now|landed|lands|went|already|sits)\s+(?:now\s+)?(?:on|in)\s+(?:main|master)\b/g) {
      my $p = $-[0];
      my ($cs) = $clause->($p);
      my @w = (substr($l, $cs, $p - $cs) =~ /([a-z0-9\x27\/]+)/g);
      @w = @w[-3 .. -1] if @w > 3;
      next if grep { $_ =~ $defer || $_ =~ /n\x27t$/ } @w;
      push @claims, $p;
    }
    for my $c (@claims) {
      my ($cs, $ce) = $clause->($c);
      my $u = "";
      for my $e (@urls) { $u = $e->[1] if $e->[0] >= $cs && $e->[0] < $c; }
      if ($u eq "") { for my $e (@urls) { if ($e->[0] > $c && $e->[0] < $ce) { $u = $e->[1]; last; } } }
      if ($u eq "") { for my $e (@urls) { $u = $e->[1] if $e->[0] < $c; } }
      if ($u eq "") { for my $e (@urls) { if ($e->[0] > $c) { $u = $e->[1]; last; } } }
      print "$u\n";
    }
  '
}

# fm_merge_claim_check <state> <task-id> <summary>: 0 when every merge claim
# in the summary is proven, 1 when one is not, with FM_MERGE_CLAIM_REFUSAL set
# to the sentence to show the reporter.
# shellcheck disable=SC2034 # FM_MERGE_CLAIM_REFUSAL is read by callers.
fm_merge_claim_check() {  # <state> <task-id> <summary>
  local state=$1 id=$2 summary=$3 recorded='' url checked=' ' result rc forge_state claims
  local timeout=${FM_MERGE_CLAIM_TIMEOUT:-10}
  FM_MERGE_CLAIM_REFUSAL=
  case "$timeout" in ''|*[!0-9]*) timeout=10 ;; esac
  # One line per claim, so an empty line is a claim naming no URL; no claims
  # at all must not read as one such line.
  claims=$(printf '%s' "$summary" | _fm_merge_claim_urls; printf x) || return 0
  claims=${claims%x}
  [ -n "$claims" ] || return 0
  if [ -f "$state/$id.meta" ] && [ ! -L "$state/$id.meta" ]; then
    recorded=$(sed -n 's/^pr=//p' "$state/$id.meta" 2>/dev/null | tail -n 1)
  fi
  while IFS= read -r url; do
    [ -n "$url" ] || url=$recorded
    [ -n "$url" ] || continue
    case "$checked" in *" $url "*) continue ;; esac
    checked="$checked$url "
    # shellcheck disable=SC2016 # The inner script expands after bash -c receives positional args.
    result=$(fm_run_timed "$timeout" bash -c '
      . "$1"
      rc=0
      fm_pr_merge_proof "$2" "$3" "$4" || rc=$?
      printf "%s\t%s\n" "$rc" "$FM_PR_RECORD_STATE"
    ' _ "$_FM_MERGE_CLAIM_LIB_DIR/fm-pr-lib.sh" "$state" "$id" "$url" 2>/dev/null) || result="2	"
    rc=${result%%$'\t'*}
    forge_state=${result#*$'\t'}
    case "$rc" in
      0) continue ;;
      1)
        FM_MERGE_CLAIM_REFUSAL="the summary calls $url merged or landed, but the forge reports it ${forge_state:-not merged}; a worker's \"landed\" can mean it merged main into its branch and pushed, which leaves the PR open. Report it as open and waiting for its merge, and send the report again."
        ;;
      *)
        FM_MERGE_CLAIM_REFUSAL="the summary calls $url merged or landed, but no merge record proves it and the forge could not be read; report the merge as unconfirmed, and send the report again."
        ;;
    esac
    return 1
  done <<URLS
${claims%$'\n'}
URLS
  return 0
}
