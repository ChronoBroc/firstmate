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
# The summary is read clause by clause: a clause ends at sentence punctuation,
# a semicolon, a line break, or "but"/"while". A clause is a merge claim when
# it holds affirmative merge wording: "merged" in any hyphenated form
# ("squash-merged", "auto-merged"), or "is/now/landed/already on|in
# main|master". Such wording is not a claim when one of the three words before
# it in the clause negates or defers it ("not", "n't", "once", "to be",
# "awaiting", "ready", ..., or "un-merged"), when it describes merging main
# into a branch ("merged main into", "main merged into"), or when "merged" is
# directly followed by a file path and the clause names no PR ("auto-merged
# src/a.ts"). A bare "landed" is not a claim: "the worker landed main into the
# PR; it remains open" is the truthful report of that state. PR URLs and PR
# references are read as opaque tokens, so no word inside them exempts a claim.
# Every PR a claim clause names (a PR URL, or a bare "PR 123" / "#123") must be
# proven merged; a claim clause naming none stands for the task's recorded pr=.
# A bare number is the recorded pr= when that ends in it, else that number in
# the GitHub repository the task's project= clone has as origin. A claim whose
# PR cannot be resolved is refused as unconfirmed.
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

# _fm_merge_claim_urls: read a summary on stdin and print, once per PR a merge
# claim clause names, that PR's URL or "#<number>" ("" for a claim clause that
# names none).
_fm_merge_claim_urls() {
  perl -e '
    use strict; use warnings;
    local $/; my $s = <STDIN>; $s = "" unless defined $s;
    my $l = lc $s;
    my (@spans, @ids);
    while ($s =~ m{https://[^\s<>()\[\]"\x27`,;]+}g) {
      my ($u, $p) = ($&, $-[0]);
      $u =~ s/[.:!?]+$//;
      push @spans, [$p, $p + length $u];
      push @ids, [$p, $u] if $u =~ m{/(?:pull|pulls|merge_requests)/[0-9]+$|/\+/[0-9]+$};
    }
    while ($l =~ /\b(?:pr|pull request)\s*#?\s*([0-9]+)\b|(?<![\w\/])#([0-9]+)\b/g) {
      my ($p, $e, $n) = ($-[0], $+[0], defined $1 ? $1 : $2);
      next if grep { $p >= $_->[0] && $p < $_->[1] } @spans;
      push @ids, [$p, "#$n"];
      push @spans, [$p, $e];
    }
    @ids = sort { $a->[0] <=> $b->[0] } @ids;
    my $m = $l;
    substr($m, $_->[0], $_->[1] - $_->[0]) = "z" x ($_->[1] - $_->[0]) for @spans;
    my @cut = (0, length $m);
    while ($m =~ /[.!?]+(?=\s|$)|[;\n]|\b(?:but|while)\b/g) { push @cut, $+[0]; }
    my %seen; @cut = sort { $a <=> $b } grep { !$seen{$_}++ } @cut;
    my $defer = qr/^(?:not|never|no|yet|until|unless|before|once|when|whenever|after|if|whether|await|awaits|awaiting|wait|waits|waiting|ready|pending|can|cannot|will|would|should|could|may|might|must|need|needs|ask|asks|asking|asked|to|be|for|get|gets)$/;
    my $negated = sub {
      my ($cs, $p) = @_;
      my @w = (substr($m, $cs, $p - $cs) =~ /([a-z0-9\x27\/]+)/g);
      @w = @w[-3 .. -1] if @w > 3;
      return scalar grep { $_ =~ $defer || $_ =~ /n\x27t$/ } @w;
    };
    for my $i (0 .. $#cut - 1) {
      my ($cs, $ce) = ($cut[$i], $cut[$i + 1]);
      my $c = substr($m, $cs, $ce - $cs);
      my @in = map { $_->[1] } grep { $_->[0] >= $cs && $_->[0] < $ce } @ids;
      my $claim = 0;
      while ($c =~ /\b(?:([a-z]+)-)?merged\b/g) {
        my ($p, $prefix, $after) = ($cs + $-[0], defined $1 ? $1 : "", substr($c, $+[0]));
        next if $prefix eq "un";
        next if $negated->($cs, $p);
        next if $after =~ /^\s+(?:main|master|origin\/|upstream|the default branch|the latest main|the base)\b/;
        next if substr($m, $cs, $p - $cs) =~ /\b(?:main|master|origin\/\S+|the base)\s+(?:was\s+|is\s+)?$/ && $after =~ /^\s+into\b/;
        if (!@in && $after =~ /^\s+(\S+)/) {
          my $t = $1; $t =~ s/[.,:!?]+$//;
          next if $t =~ m{/} || $t =~ /\.[a-z0-9]{1,6}$/;
        }
        $claim = 1;
      }
      while ($c =~ /\b(?:is|are|now|landed|lands|went|already|sits)\s+(?:now\s+)?(?:on|in)\s+(?:main|master)\b/g) {
        $claim = 1 unless $negated->($cs, $cs + $-[0]);
      }
      next unless $claim;
      print "$_\n" for (@in ? @in : (""));
    }
  '
}

# _fm_merge_claim_number_url <state> <task-id> <number> <recorded-pr>: print
# the PR URL a bare PR number names for this task, or nothing.
_fm_merge_claim_number_url() {
  local state=$1 id=$2 n=$3 recorded=$4 project='' remote
  case "$recorded" in */"$n") printf '%s' "$recorded"; return 0 ;; esac
  if [ -f "$state/$id.meta" ] && [ ! -L "$state/$id.meta" ]; then
    project=$(sed -n 's/^project=//p' "$state/$id.meta" 2>/dev/null | tail -n 1)
  fi
  [ -n "$project" ] && [ -d "$project" ] || return 0
  remote=$(git -C "$project" remote get-url origin 2>/dev/null) || return 0
  case "$remote" in
    git@github.com:*) remote="https://github.com/${remote#git@github.com:}" ;;
    ssh://git@github.com/*) remote="https://github.com/${remote#ssh://git@github.com/}" ;;
  esac
  remote=${remote%/}
  # shellcheck disable=SC2016 # The inner script expands after bash -c receives positional args.
  bash -c '. "$1"; fm_pr_url_parse "$2" && [ "$FM_PR_PROVIDER" = github ] && printf "%s" "$FM_PR_URL"' \
    _ "$_FM_MERGE_CLAIM_LIB_DIR/fm-pr-lib.sh" "${remote%.git}/pull/$n" 2>/dev/null || true
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
  claims=${claims%$'\n'}
  if [ -f "$state/$id.meta" ] && [ ! -L "$state/$id.meta" ]; then
    recorded=$(sed -n 's/^pr=//p' "$state/$id.meta" 2>/dev/null | tail -n 1)
  fi
  while IFS= read -r url; do
    [ -n "$url" ] || url=$recorded
    case "$url" in '#'*) url=$(_fm_merge_claim_number_url "$state" "$id" "${url#\#}" "$recorded" </dev/null) ;; esac
    if [ -z "$url" ]; then
      FM_MERGE_CLAIM_REFUSAL="the summary calls a PR merged or on main, but names no PR this home can check (no PR URL, no recorded pr=, and no PR number its project's repository resolves); name the PR's URL, or report the merge as unconfirmed, and send the report again."
      return 1
    fi
    case "$checked" in *" $url "*) continue ;; esac
    checked="$checked$url "
    # shellcheck disable=SC2016 # The inner script expands after bash -c receives positional args.
    result=$(fm_run_timed "$timeout" bash -c '
      . "$1"
      rc=0
      fm_pr_merge_proof "$2" "$3" "$4" || rc=$?
      printf "%s\t%s\n" "$rc" "$FM_PR_RECORD_STATE"
    ' _ "$_FM_MERGE_CLAIM_LIB_DIR/fm-pr-lib.sh" "$state" "$id" "$url" </dev/null 2>/dev/null) || result="2	"
    rc=${result%%$'\t'*}
    forge_state=${result#*$'\t'}
    case "$rc" in
      0) continue ;;
      1)
        FM_MERGE_CLAIM_REFUSAL="the summary calls $url merged or on main, but the forge reports it ${forge_state:-not merged}; a worker's \"landed\" can mean it merged main into its branch and pushed, which leaves the PR open. Report it as open and waiting for its merge, and send the report again."
        ;;
      *)
        FM_MERGE_CLAIM_REFUSAL="the summary calls $url merged or on main, but no merge record proves it and the forge could not be read; report the merge as unconfirmed, and send the report again."
        ;;
    esac
    return 1
  done <<URLS
$claims
URLS
  return 0
}
