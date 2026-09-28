#!/usr/bin/env bash
# _auto.sh — shared automation helpers for tools/auto.sh, tools/verify.sh and
# tools/handoff.sh. Sourced, never run directly. Requires gates/_common.sh.
#
# This file computes MACHINE STATE from the artifacts and approval records that
# already exist. It decides nothing on its own: every gate verdict comes from
# _common.sh (the same functions check-gate.sh, status.sh and close.sh use), so
# the JSON view and the prose view can never disagree about a binding.
#
# It runs no model and performs no reasoning. `ready` means "the next action is
# an action this project's lazymode lets an agent take", not "a script did it".
# Keep it dependency-free: POSIX tools plus git. Bash 3.2 compatible.

# --- small utilities ---------------------------------------------------------
sdlc_auto_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# JSON string escaping without jq. RFC 8259 requires every C0 control character
# to be escaped, not just the ones with a short form: a stray ESC or BEL in
# progress.md used to produce JSON that a driver could not parse (and an exit
# code of 0 while doing it). Newlines become \n; every other C0 byte becomes
# \u00XX. LC_ALL=C keeps awk byte-oriented so UTF-8 text passes through intact.
sdlc_json_str() { # <text> → "escaped"
  printf '%s' "${1-}" | LC_ALL=C awk '
    BEGIN { ORS = ""; printf "\"" }
    { line = $0
      gsub(/\\/, "\\\\", line); gsub(/"/, "\\\"", line)
      for (i = 1; i <= 31; i++) {
        c = sprintf("%c", i)
        if (index(line, c) > 0) gsub(c, sprintf("\\u%04x", i), line)
      }
      if (NR > 1) printf "\\n"
      printf "%s", line }
    END { printf "\"" }'
}

# A slug names a directory under .sdlc/work/ and is pasted into commands, log
# paths and JSON. Anything outside this set is refused by name rather than
# word-split into features that do not exist.
sdlc_auto_valid_slug() { # <slug> → 0 when usable
  case "${1-}" in
    ''|.|..) return 1;;
    *[!a-zA-Z0-9._-]*) return 1;;
    -*) return 1;;
  esac
  return 0
}

# --- project-level configuration ---------------------------------------------
# lazymode with the SAME fail-closed rule as approve.sh/status.sh: anything
# outside 0-4 (or absent) counts as 0.
sdlc_auto_lazymode() { # → 0..4
  local raw lm
  raw=$(awk '/^lazymode: /{gsub(/\r/,""); print $2; exit}' .sdlc/config.md 2>/dev/null || true)
  lm="$raw"
  case "$lm" in (''|*[!0-9]*) lm=0;; (*) [ "$lm" -le 4 ] || lm=0;; esac
  printf '%s\n' "$lm"
}
sdlc_auto_lazy_min() { # <stage> → the lazymode level that waives its human gate
  case "$1" in plan) echo 1;; spec) echo 2;; ship) echo 3;; intent) echo 4;; *) echo 99;; esac
}
sdlc_auto_kit_version() {
  local kitdir="$1" v=""
  if [ "$(git -C "$kitdir" rev-parse --show-toplevel 2>/dev/null)" = "$kitdir" ]; then
    v=$(git -C "$kitdir" describe --tags --always 2>/dev/null || true)
  fi
  [ -n "$v" ] || v=$(cat "$kitdir/VERSION" 2>/dev/null || echo unknown)
  printf '%s\n' "$v"
}

# --- track and per-stage gate state ------------------------------------------
sdlc_auto_track() { # <slug> → compact | full
  local dir=".sdlc/work/$1" rec=".sdlc/approvals/$1.intent.approval" t=full
  if [ -f "$dir/intent.md" ] && grep -qiE '^- *track: *(compact|micro)([^a-z]|$)' "$dir/intent.md"; then t=compact; fi
  [ -f "$dir/spec.md" ] && t=full
  # the intent approval FROZE the verdict (approve.sh): a post-approval rewrite
  # to compact does not skip spec/plan
  if [ "$t" = compact ] && [ -f "$rec" ] && [ "$(sdlc_field "$rec" track || true)" != "compact" ]; then t=full; fi
  printf '%s\n' "$t"
}
sdlc_auto_artifact_for() { sdlc_artifact_of "$1"; }   # one map, in _common.sh

# One stage's state: "<state>|<detail>"
#   absent    — no artifact yet
#   pending   — artifact exists, no approval record
#   approved  — record binds this artifact and its upstreams, all unchanged
#   stale     — a binding no longer holds (detail names the repair)
sdlc_auto_stage_state() { # <slug> <stage>
  local slug="$1" stage="$2" dir=".sdlc/work/$1" art rec want up upw upart
  art="$dir/$(sdlc_auto_artifact_for "$stage")"
  rec=".sdlc/approvals/${slug}.${stage}.approval"
  [ -f "$art" ] || { echo "absent|$(sdlc_auto_artifact_for "$stage") not written yet"; return 0; }
  [ -f "$rec" ] || { echo "pending|$art awaits the $stage gate"; return 0; }
  want=$(sdlc_field "$rec" artifact_sha256 || true)
  if [ -z "$want" ]; then
    echo "stale|the $stage record predates content binding — gates/approve.sh $stage $art"; return 0; fi
  if [ "$(sdlc_sha256_file "$art")" != "$want" ]; then
    echo "stale|$art changed after approval — gates/approve.sh $stage $art"; return 0; fi
  for up in $(sdlc_upstream_stages "$stage"); do
    upw=$(sdlc_field "$rec" "upstream_$up" || true)
    upart="$dir/$(sdlc_auto_artifact_for "$up")"
    [ -n "$upw" ] || continue
    if [ ! -f "$upart" ] || [ "$(sdlc_sha256_file "$upart" 2>/dev/null || true)" != "$upw" ]; then
      echo "stale|$(sdlc_auto_artifact_for "$up") changed since the $stage approval — $(sdlc_regate_hint "$up" "$stage")"; return 0; fi
  done
  for up in $(sdlc_upstream_unbound "$rec" "$slug"); do
    echo "stale|$(sdlc_auto_artifact_for "$up") is not part of the approved $stage basis — gates/approve.sh $stage $art"; return 0
  done
  echo "approved|approved at $(sdlc_field "$rec" approved_at || true)"
}

# --- the full-auto intent contract -------------------------------------------
# What an unattended run needs from intent.md before it may act on it
# (AGENTS.md rule 3a). Prints "<state>|<detail>":
#   ok        — actionable outcome, scope, non-goals, acceptance criteria,
#               evidence, scope authorization, and no unresolved MATERIAL question
#   material  — a MATERIAL question is open: a human decides, never a guess
#   incomplete— a required section is missing or still a template placeholder
#   absent    — no intent.md
# Optional (non-material) uncertainty never blocks: it is carried as a labelled
# assumption.
#
# Under "## Material questions", ANY content blocks unless it carries the exact
# resolution syntax. Markdown markers are irrelevant: a nested bullet, a `*`
# bullet, a numbered item and a bare prose line all count, because a question a
# human still owes an answer to does not become harmless by being typed without
# a dash. The only two ways a line stops blocking are
#   the CANONICAL resolution marker — `resolved:` (or the bracket form
#   `[resolved …]`) at the start of the line once Markdown markers are peeled,
#   or right after the ` — ` / ` - ` separator of the documented form
#   `- <question> — resolved: <answer and where it came from>` — and
#   a bare `none` / `n/a` line declaring the section empty.
# The marker is ANCHORED rather than searched for anywhere in the line, so prose
# that merely CONTAINS the word never clears a question: "unresolved:",
# "not resolved: pending", "non-resolved:" and "to be resolved with the PM" all
# still block, and no list of negation words has to be maintained to keep them
# blocking. HTML comments (including the template's multi-line one) are not content.
sdlc_auto_material_counts() { # <intent.md> → "<blocking> <placeholder>"
  awk '
    function trim(x) { sub(/^[ \t]+/, "", x); sub(/[ \t\r]+$/, "", x); return x }
    BEGIN { insec = 0; incomment = 0; mat = 0; ph = 0 }
    {
      line = $0; sub(/\r$/, "", line)
      if (line ~ /^##[ \t]*Material questions/) { insec = 1; next }
      else if (line ~ /^#+[ \t]/) { insec = 0 }
      if (!insec) next
      # strip HTML comments, which may span lines
      while (1) {
        if (incomment) {
          p = index(line, "-->")
          if (p == 0) { line = ""; break }
          line = substr(line, p + 3); incomment = 0
        } else {
          p = index(line, "<!--")
          if (p == 0) break
          rest = substr(line, p + 4); q = index(rest, "-->")
          if (q == 0) { line = substr(line, 1, p - 1); incomment = 1; break }
          line = substr(line, 1, p - 1) substr(rest, q + 3)
        }
      }
      c = trim(line)
      if (c == "") next
      # markers carry no meaning here: peel bullets, numbers and checkboxes off
      while (c ~ /^([-*+]|[0-9]+[.)])[ \t]+/) { sub(/^([-*+]|[0-9]+[.)])[ \t]+/, "", c); c = trim(c) }
      sub(/^\[[ xX]\][ \t]*/, "", c); c = trim(c)
      if (c == "") next
      # anchored: line start, or immediately after a dash separator that is
      # itself preceded by whitespace (the documented "— resolved:" form).
      anchor = "(^|(^|[ \t])(—|–|--|-)[ \t]+)"
      if (c ~ anchor "resolved:" || c ~ anchor "\\[resolved") next
      bare = tolower(c); gsub(/[*_.()\[\]~` \t-]/, "", bare)
      if (bare == "none" || bare == "na" || bare == "n/a" || bare == "nonopen" || bare == "nomaterialquestions") next
      if (substr(c, 1, 1) == "<" && index(c, ">") > 0) { ph++; next }
      mat++
    }
    END { printf "%d %d\n", mat, ph }
  ' "$1"
}

# The scope the human authorized, in their words (intent.md). It is AUTHORITY,
# not a gate approval, and it is the only recorded place a branch publication
# can be authorized from — a `--authorized` flag an agent types is not.
sdlc_auto_scope_authorization() { # <slug> → the recorded text (may be empty)
  local f=".sdlc/work/$1/intent.md"
  [ -f "$f" ] || return 0
  awk '/^[ \t]*- *Scope authorization:/{sub(/^[^:]*: */,""); sub(/[ \t\r]+$/,""); print; exit}' "$f"
}
# Does that recorded scope name publishing a branch (push / PR / MR / review
# branch)? Nothing else authorizes an external effect.
sdlc_auto_scope_allows_publish() { # <slug> → 0 when it does
  local t
  t=$(sdlc_auto_scope_authorization "$1" | tr 'A-Z' 'a-z')
  case "$t" in
    ''|'<'*) return 1;;
  esac
  case " $t " in
    *push*|*" pr "*|*"pull request"*|*"merge request"*|*" mr "*|*"review branch"*|*"feature branch"*|*"open a pr"*)
      return 0;;
  esac
  return 1
}

sdlc_auto_intent_contract() { # <slug>
  local f=".sdlc/work/$1/intent.md" missing="" v n
  [ -f "$f" ] || { echo "absent|no intent.md"; return 0; }
  # Goal: one actionable sentence, not the template placeholder
  v=$(awk '/^- *Goal:/{sub(/^- *Goal: */,""); print; exit}' "$f")
  case "$v" in (''|'<'*) missing="$missing Goal";; esac
  v=$(awk '/^- *Scope authorization:/{sub(/^[^:]*: */,""); print; exit}' "$f")
  case "$v" in (''|'<'*) missing="$missing Scope-authorization";; esac
  # acceptance criteria: at least one checklist line under Success criteria
  n=$(awk '/^## *Success criteria/{s=1;next} /^## /{s=0} s && /^- *\[/ && $0 !~ /<criterion>/ {c++} END{print c+0}' "$f")
  [ "$n" -ge 1 ] || missing="$missing Success-criteria"
  # non-goals: at least one real bullet under Out of scope
  n=$(awk '/^## *Out of scope/{s=1;next} /^## /{s=0} s && /^- / && $0 !~ /^- *</ {c++} END{print c+0}' "$f")
  [ "$n" -ge 1 ] || missing="$missing Non-goals"
  # evidence: at least one labelled claim
  n=$(awk '/^## *Evidence/{s=1;next} /^## /{s=0} s && /\[(verified|assumed)/ {c++} END{print c+0}' "$f")
  [ "$n" -ge 1 ] || missing="$missing Evidence"
  grep -qE '^## *Material questions' "$f" || missing="$missing Material-questions-section"
  if [ -n "$missing" ]; then
    echo "incomplete|intent.md is not full-auto ready — missing or placeholder:${missing}"; return 0; fi
  read -r n p <<EOF
$(sdlc_auto_material_counts "$f")
EOF
  if [ "${n:-0}" -gt 0 ]; then
    echo "material|$n unresolved MATERIAL question(s) in intent.md — a human decides; do not guess to make progress (resolve a line in place with 'resolved: <the answer and where it came from>')"; return 0; fi
  if [ "${p:-0}" -gt 0 ]; then
    echo "incomplete|## Material questions still holds $p template placeholder line(s) — write the real questions, or leave the section empty / 'none'"; return 0; fi
  echo "ok|intent contract satisfied"
}

# --- the build fix loop --------------------------------------------------------
# deviations.md's `- round n/3:` lines are the counter (AGENTS.md rule 5,
# skills/4-build); a line's `re-check:` field is updated in place. Prints
# "<state>|<detail>":
#   none      — no round recorded
#   open      — the latest round's re-check is pending or open, rounds remain
#   resolved  — the latest round's re-check is resolved
#   exhausted — round 3's re-check is still open, or a round past the cap
#               exists: a human decides, at every lazymode
sdlc_auto_fixloop_state() { # <slug>
  local f=".sdlc/work/$1/deviations.md" n line
  [ -f "$f" ] || { echo "none|no fix loop recorded"; return 0; }
  { read -r n; read -r line; } <<EOF
$(awk '/^- *round [0-9]+\/[0-9]+:/ && $0 !~ /<lens>/ { s=$0; sub(/^- *round /,"",s); sub(/\/.*/,"",s); if (s+0>=m) {m=s+0; l=$0} }
       END{print m+0; print l}' "$f")
EOF
  [ "${n:-0}" -ge 1 ] || { echo "none|no fix loop recorded"; return 0; }
  [ "$n" -le 3 ] || { echo "exhausted|fix loop round $n recorded in deviations.md; the cap is 3 (skills/4-build) — the human decides"; return 0; }
  case "$line" in
    *"re-check: resolved"*) echo "resolved|fix loop round $n/3 re-check resolved";;
    *"re-check: open"*)
      if [ "$n" -ge 3 ]; then echo "exhausted|fix loop round 3/3 re-check still open — show the human the evidence and deviations.md (skills/4-build)"
      else echo "open|fix loop round $n/3 re-check open — round $((n + 1)) next"; fi;;
    *) echo "open|fix loop round $n/3 in progress";;
  esac
}

# --- verification receipts ----------------------------------------------------
# The recipe is .sdlc/verify.md (templates/verify.md), plus an optional
# per-feature .sdlc/work/<slug>/verify.md (templates/verify-feature.md: check:
# and gap: lines only). Receipts are written by
# tools/verify.sh from commands it executed itself, and every field a reader
# depends on is re-checked here: the log files the receipt cites must exist and
# still hash to the digests it recorded, the command digests must match the
# recipe's commands, and the number of checks must account for every configured
# one. That is CHANGE DETECTION, not authentication — a receipt says "these
# commands produced these bytes over this source", never "a trustworthy party
# ran them". An independent reviewer (roles/verifier.md) is still required.
sdlc_verify_recipe() { echo ".sdlc/verify.md"; }
# per feature, so two open features' requirement checks never collide
sdlc_verify_feature_recipe() { echo ".sdlc/work/$1/verify.md"; }
sdlc_verify_receipt() { echo ".sdlc/work/$1/verify-receipt.md"; }
sdlc_verify_baseline() { echo ".sdlc/work/$1/verify-baseline.md"; }
# The prelude of every awk that reads the recipe, spec.md or intent.md (run it
# with -v bom="$SDLC_BOM"): it strips a UTF-8 BOM from line 1 — left in, it hid
# `profile: strict` and a strict project read as advisory. data(k, v) strips a
# trailing ` # comment` from the value keys only: commands go to `sh -c`
# verbatim, where stripping would cut a quoted `#`.
SDLC_BOM=$(printf '\357\273\277')
SDLC_VERIFY_AWK='
  function trim(x) { sub(/^[ \t]+/, "", x); sub(/[ \t\r]+$/, "", x); return x }
  function data(k, v) {
    if (index(" profile doctor_timeout doctor_attempt_timeout check_timeout cleanup_timeout test_paths forbidden_hosts environment ", " " k " ")) {
      if (v ~ /^#/) v = ""; sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v) }
    return v }
  FNR == 1 && index($0, bom) == 1 { $0 = substr($0, length(bom) + 1) }
'
# Comma-joined first fields of tab-separated rows, optionally only the rows whose
# second field matches <regex>.
sdlc_verify_join() { # [<regex>] < rows
  awk -F'\t' -v m="${1-}" 'NF && (m == "" || $2 ~ m) { printf "%s%s", s, $1; s = ", " }'
}
sdlc_verify_profile() { # → strict | advisory (default advisory; absent recipe = advisory)
  local p
  p=$(sdlc_verify_field "$(sdlc_verify_recipe)" profile)
  case "$p" in strict) echo strict;; *) echo advisory;; esac
}
sdlc_verify_recipe_digest() {
  local r; r=$(sdlc_verify_recipe)
  [ -f "$r" ] && sdlc_sha256_file "$r" || echo none
}
sdlc_verify_feature_recipe_digest() { # <slug> → sha256 of the feature recipe, or none
  local r; r=$(sdlc_verify_feature_recipe "$1")
  [ -f "$r" ] && sdlc_sha256_file "$r" || echo none
}
sdlc_verify_field() { # <recipe> <key> → value (\r, BOM and, on value keys, a trailing comment stripped)
  [ -f "$1" ] || return 0
  awk -v bom="$SDLC_BOM" -v key="$2" "$SDLC_VERIFY_AWK"'
    index($0, key ": ") == 1 { v = substr($0, length(key) + 3); gsub(/\r/, "", v); print data(key, v); exit }' "$1" 2>/dev/null
}
# The configured checks of ONE recipe file, one per line:
# "<id>\t<kind>\t<command>\t<flag>". The single parser both tools/verify.sh
# (which runs them) and the receipt validation below (which re-derives their
# digests) use, so the two cannot drift apart. The flag is only the exact word
# `must-fail-on-base` after the LAST `|`: a command keeps its own pipes.
sdlc_verify_recipe_checks() { # [recipe] → tab-separated lines
  local r="${1:-$(sdlc_verify_recipe)}"
  [ -f "$r" ] || return 0
  awk -v bom="$SDLC_BOM" "$SDLC_VERIFY_AWK"'
    index($0, "check:") == 1 {
      body = substr($0, 7); sub(/\r$/, "", body)
      p = index(body, "|"); if (p == 0) { print "\t\t" trim(body) "\t"; next }
      id = trim(substr(body, 1, p - 1)); rest = substr(body, p + 1)
      q = index(rest, "|"); if (q == 0) { print id "\t" trim(rest) "\t\t"; next }
      kind = trim(substr(rest, 1, q - 1)); cmd = trim(substr(rest, q + 1)); flag = ""
      if (match(cmd, /[|][ \t]*must-fail-on-base([ \t]+#.*)?$/)) { flag = "must-fail-on-base"; cmd = trim(substr(cmd, 1, RSTART - 1)) }
      print id "\t" tolower(kind) "\t" cmd "\t" flag
    }' "$r"
}
# The EFFECTIVE checks of a feature: the project recipe's, then its own.
sdlc_verify_checks() { # <slug> → tab-separated lines
  local f
  sdlc_verify_recipe_checks "$(sdlc_verify_recipe)"
  f=$(sdlc_verify_feature_recipe "${1-}")
  if [ -n "${1-}" ] && [ -f "$f" ]; then sdlc_verify_recipe_checks "$f"; fi
  return 0
}
# `gap: <id> | <reason>`: a requirement deliberately left unchecked, in words a
# reviewer can weigh. It satisfies coverage and is listed.
sdlc_verify_recipe_gaps() { # <recipe> → "<id>\t<reason>"
  [ -f "$1" ] || return 0
  awk -v bom="$SDLC_BOM" "$SDLC_VERIFY_AWK"'
    index($0, "gap:") == 1 {
      body = substr($0, 5); sub(/\r$/, "", body)
      p = index(body, "|"); if (p == 0) { print trim(body) "\t"; next }
      print trim(substr(body, 1, p - 1)) "\t" trim(substr(body, p + 1))
    }' "$1"
}
sdlc_verify_gaps() { # <slug> → the project's gap lines, then the feature's
  sdlc_verify_recipe_gaps "$(sdlc_verify_recipe)"
  if [ -n "${1-}" ]; then sdlc_verify_recipe_gaps "$(sdlc_verify_feature_recipe "$1")"; fi
  return 0
}
# forbidden_hosts: checked against the command TEXT before anything runs — a
# guard against a mistake, not a sandbox (a host behind a variable is not seen).
sdlc_verify_forbidden_hit() { # [slug] → "<what> names <host>" for the first hit, or nothing
  local r hosts k v
  r=$(sdlc_verify_recipe)
  hosts=$(sdlc_verify_field "$r" forbidden_hosts)
  [ -n "$hosts" ] || return 0
  {
    for k in launch doctor cleanup baseline_setup; do
      v=$(sdlc_verify_field "$r" "$k")
      [ -z "$v" ] || printf "'%s:'\t%s\n" "$k" "$v"
    done
    sdlc_verify_checks "${1-}" | awk -F'\t' '{ print "check '\''" $1 "'\''\t" $3 }'
  } | awk -F'\t' -v hosts="$hosts" '
    BEGIN { n = split(tolower(hosts), h, /[ \t,]+/) }
    { c = tolower($2); for (i = 1; i <= n; i++) if (h[i] != "" && index(c, h[i]) > 0) { print $1 " names the forbidden host " h[i]; exit } }'
}
# A recipe that is malformed or still half a template must be refused BEFORE
# anything is executed: `sh -c "<e.g. npm test>"` is not a verification, and the
# 60s doctor wait it burns looks like a real one in the log.
sdlc_verify_recipe_issue() { # [slug] → "" when usable, else "<code> <message>"
  local slug="${1-}" r fr v k launch tpaths
  r=$(sdlc_verify_recipe)
  [ -f "$r" ] || { echo "absent no $r"; return 0; }
  # the settings in one pass, read as sdlc_verify_field reads them (first line
  # of each key wins): what is validated is what is used
  v=$(awk -v bom="$SDLC_BOM" "$SDLC_VERIFY_AWK"'
    { sub(/\r$/, ""); p = index($0, ": "); if (p < 2) next
      k = substr($0, 1, p - 1); if (k in seen) next; seen[k] = 1; v = data(k, substr($0, p + 2))
      if (k == "profile" && v != "strict" && v != "advisory" && v != "") {
        print "profile profile must be '\''strict'\'' or '\''advisory'\'' (found '\''" v "'\'')"; exit }
      if ((k == "launch" || k == "doctor" || k == "cleanup" || k == "environment" || k == "baseline_setup" || k == "test_paths" || k == "forbidden_hosts") && substr(v, 1, 1) == "<") {
        print "placeholder the '\''" k ":'\'' line is still the template placeholder (" v ")"; exit }
      if ((k == "doctor_timeout" || k == "doctor_attempt_timeout" || k == "check_timeout" || k == "cleanup_timeout") && v ~ /[^0-9]/) {
        print "timeout '\''" k ": " v "'\'' must be a whole number of seconds"; exit }
    }' "$r")
  [ -z "$v" ] || { echo "$v"; return 0; }
  fr=""
  [ -z "$slug" ] || fr=$(sdlc_verify_feature_recipe "$slug")
  [ -n "$fr" ] && [ -f "$fr" ] || fr=""
  # a line that looks like a directive but would silently not be read as one
  v=$(awk -v bom="$SDLC_BOM" "$SDLC_VERIFY_AWK"'
    { sub(/\r$/, "") }
    /^[ \t]+(check|gap):/ { print "indent " FILENAME " line " FNR " is an indented directive — '\''check:'\'' and '\''gap:'\'' must start at column 1, or it is never read (found '\''" $0 "'\'')"; exit }
    (index($0, "check:") == 1 || index($0, "gap:") == 1) && index($0, "\t") > 0 {
      print "tab " FILENAME " line " FNR " holds a tab character — use spaces: the recipe parser separates fields with tabs"; exit }' "$r" ${fr:+"$fr"})
  [ -z "$v" ] || { echo "$v"; return 0; }
  if [ -n "$fr" ]; then
    # a `launch:` or `profile:` here would silently change the project recipe
    v=$(awk -v bom="$SDLC_BOM" "$SDLC_VERIFY_AWK"'
             { sub(/\r$/, "") } /^[ \t]*$/ || /^#/ || index($0, "check:") == 1 || index($0, "gap:") == 1 { next }
             { print "line " NR ": " $0; exit }' "$fr")
    [ -z "$v" ] || { echo "feature $fr may hold only check: and gap: lines (and # comments) — $v; project settings belong in $r"; return 0; }
  fi
  launch=$(sdlc_verify_field "$r" launch)
  tpaths=$(sdlc_verify_field "$r" test_paths)
  v=$(sdlc_verify_checks "$slug" | awk -F'\t' -v launch="$launch" -v tpaths="$tpaths" '
    BEGIN { n = 0; bad = "" }
    {
      n++
      id = $1; kind = $2; cmd = $3; flag = $4
      if (bad != "") next
      if (id == "" || cmd == "") { bad = "malformed check line " n " needs '\''check: <id> | <kind> | <command>'\''"; next }
      if (id ~ /[^a-zA-Z0-9._-]/) { bad = "id check id '\''" id "'\'' must be [a-zA-Z0-9._-]+ (it names a log file)"; next }
      if (kind != "build" && kind != "unit" && kind != "lint" && kind != "runtime" && kind != "e2e" && kind != "data")
        { bad = "kind check '\''" id "'\'' has kind '\''" kind "'\'' — use build|unit|lint|runtime|e2e|data"; next }
      if (substr(cmd, 1, 1) == "<") { bad = "placeholder check '\''" id "'\'' still holds the template placeholder (" cmd ")"; next }
      if (seen[id]++) { bad = "duplicate two checks share the id '\''" id "'\'' (project and feature recipes together)"; next }
      if (flag == "must-fail-on-base" && (kind == "runtime" || kind == "e2e") && launch != "")
        { bad = "mustfail check '\''" id "'\'' (" kind ") is marked must-fail-on-base, but this recipe launches a runtime and the baseline never launches one — drop the flag; the verifier compares against the base by hand (roles/verifier.md)"; next }
      if (flag == "must-fail-on-base" && tpaths == "")
        { bad = "mustfail check '\''" id "'\'' is marked must-fail-on-base, but the recipe has no '\''test_paths:'\'' line naming where tests live — the baseline could not copy the new test into the base"; next }
    }
    END {
      if (bad != "") { print bad; exit }
      if (n == 0) print "empty the recipe configures no check: line — nothing would be verified"
    }')
  [ -z "$v" ] || { echo "$v"; return 0; }
  v=$(sdlc_verify_gaps "$slug" | awk -F'\t' '
    $1 !~ /^[a-zA-Z0-9._-]+$/ { print "gap a gap: line needs '\''gap: <requirement id> | <reason>'\'' (found '\''" $1 "'\'')"; exit }
    $2 == "" || substr($2, 1, 1) == "<" { print "gap gap '\''" $1 "'\'' needs a real reason a reviewer can weigh"; exit }')
  [ -z "$v" ] || { echo "$v"; return 0; }
  v=$(sdlc_verify_forbidden_hit "$slug")
  [ -z "$v" ] || { echo "forbidden $v (forbidden_hosts: in $r) — nothing was run"; return 0; }
  return 0
}

# --- requirement coverage -----------------------------------------------------
# The ids come from the route's contract (sdlc_auto_track): spec.md `- R<n>:`
# (full), intent.md `- [ ] O<n>:` (compact). The reader is lenient, because a
# requirement it fails to see is one nobody has to cover; only the template's
# placeholder line is skipped. Syntax: docs/automation.md §4.
sdlc_verify_requirement_file() { # <slug> → the file the ids come from (it may not exist)
  if [ "$(sdlc_auto_track "$1")" = compact ]; then echo ".sdlc/work/$1/intent.md"
  else echo ".sdlc/work/$1/spec.md"; fi
}
sdlc_verify_requirement_ids() { # <slug> → ids in file order
  local f letter=R cb=0
  f=$(sdlc_verify_requirement_file "$1")
  [ -f "$f" ] || return 0
  case "$f" in */intent.md) letter=O; cb=1;; esac
  awk -v bom="$SDLC_BOM" -v L="$letter" -v cb="$cb" "$SDLC_VERIFY_AWK"'
    { s = $0; sub(/\r$/, "", s)
      if (!match(s, /^[ \t]*[-*+][ \t]+/)) next
      s = substr(s, RLENGTH + 1)
      if (cb) sub(/^\[[ xX]\][ \t]*/, "", s)
      sub(/^\*\*/, "", s)
      if (!match(s, "^" L "[0-9]+")) next
      id = substr(s, 1, RLENGTH); t = substr(s, RLENGTH + 1)
      sub(/^\*\*/, "", t); sub(/^[ \t]+/, "", t)
      if (substr(t, 1, 1) != ":") next
      t = substr(t, 2); sub(/^\*\*/, "", t); sub(/^[ \t]+/, "", t)
      if (t ~ /^<(requirement|criterion)>/) next
      if (!seen[id]++) print id }' "$f"
}
# One row per requirement: "<id>\t<status>\t<checks>\t<gap reason>".
#   covered    — a unit/runtime/e2e/data check named <id> or <id>.…
#                (strict: a runtime/e2e one)
#   gap        — no such check, but a `gap: <id> | <reason>` line
#   no-runtime — strict only: checks exist, none runtime/e2e, no gap
#   uncovered  — nothing
# Strict also emits "<id>.<variant>\tuncovered|gap" for each of happy/boundary/
# negative with no check and no gap line of its own (none for a gap'd id), and
# once any requirement is proved, "reach.<axis>\tuncovered|gap" for each of
# entry/state/context (roles/verifier.md) that no `<any id>.<axis>` check
# proves — a `gap: <any id>.<axis> | <reason>` line answers it.
sdlc_verify_coverage() { # <slug>
  local ids strict=0
  ids=$(sdlc_verify_requirement_ids "$1")
  [ -n "$ids" ] || return 0
  [ "$(sdlc_verify_profile)" = strict ] && strict=1
  {
    printf '%s\n' "$ids" | awk 'NF { print "I\t" $0 }'
    sdlc_verify_checks "$1" | awk -F'\t' '{ print "C\t" $1 "\t" $2 }'
    sdlc_verify_gaps "$1" | awk -F'\t' '{ print "G\t" $1 "\t" $2 }'
  } | awk -F'\t' -v strict="$strict" '
    # build and lint prove the code compiles and is tidy, never a requirement
    function proves(k) { return k == "unit" || k == "runtime" || k == "e2e" || k == "data" }
    $1 == "I" { ids[++n] = $2; next }
    $1 == "C" { cid[++m] = $2; ckind[m] = $3; next }
    $1 == "G" { if (!($2 in gap)) gap[$2] = $3; next }
    END {
      for (i = 1; i <= n; i++) {
        id = ids[i]; list = ""; any = 0; rt = 0
        for (j = 1; j <= m; j++) {
          c = cid[j]; k = ckind[j]
          if (c != id && index(c, id ".") != 1) continue
          if (!proves(k)) continue
          any = 1; if (k == "runtime" || k == "e2e") rt = 1
          list = list (list == "" ? "" : ", ") c "(" k ")"
        }
        if ((strict && rt) || (!strict && any)) st = "covered"
        else if (id in gap) st = "gap"
        else if (strict && any) st = "no-runtime"
        else st = "uncovered"
        print id "\t" st "\t" list "\t" (id in gap ? gap[id] : "")
        if (!strict || !any || st == "gap") continue
        proved = 1
        split("happy boundary negative", vs, " ")
        for (x = 1; x <= 3; x++) {
          v = id "." vs[x]; hit = 0
          for (j = 1; j <= m; j++) if ((cid[j] == v || index(cid[j], v ".") == 1) && proves(ckind[j])) hit = 1
          if (hit) continue
          print v "\t" (v in gap ? "gap" : "uncovered") "\t\t" (v in gap ? gap[v] : "")
        }
      }
      if (!proved) exit
      split("entry state context", ax, " ")
      for (x = 1; x <= 3; x++) {
        hit = 0; why = ""
        for (i = 1; i <= n; i++) {
          v = ids[i] "." ax[x]
          for (j = 1; j <= m; j++) if ((cid[j] == v || index(cid[j], v ".") == 1) && proves(ckind[j])) hit = 1
          if (why == "" && (v in gap)) why = gap[v]
        }
        if (hit) continue
        print "reach." ax[x] "\t" (why != "" ? "gap" : "uncovered") "\t\t" why
      }
    }'
}

# --- the base comparison (tools/verify.sh baseline) --------------------------
# verify-baseline.md records what the project recipe's build/unit/lint checks and
# the must-fail-on-base checks did at the BASE commit. It decides two things:
# `pre-existing` (sdlc_verify_preexisting_ok) and `vacuous`
# (sdlc_verify_baseline_issue). One for another recipe, or at a base no longer
# in HEAD's history, is ignored: it is not about this change.
sdlc_verify_baseline_usable() { # <slug> → 0 when a baseline exists for THIS recipe and base
  local b bsha; b=$(sdlc_verify_baseline "$1")
  [ -f "$b" ] || return 1
  [ "$(sdlc_field "$b" baseline_schema || true)" = "sdlc-kit/verify-baseline@1" ] || return 1
  [ "$(sdlc_field "$b" recipe_digest || true)" = "$(sdlc_verify_recipe_digest)" ] || return 1
  [ "$(sdlc_field "$b" feature_recipe_digest || true)" = "$(sdlc_verify_feature_recipe_digest "$1")" ] || return 1
  bsha=$(sdlc_field "$b" base_sha || true)
  [ -n "$bsha" ] && git merge-base --is-ancestor "$bsha" HEAD 2>/dev/null || return 1
  return 0
}
sdlc_verify_baseline_label() { # <slug> → "<base ref> @ <sha8>" of the recorded baseline
  local b r h; b=$(sdlc_verify_baseline "$1")
  r=$(sdlc_field "$b" base_ref || true); h=$(sdlc_field "$b" base_sha || true)
  printf '%s @ %s\n' "${r:-?}" "${h%"${h#????????}"}"
}
sdlc_verify_baseline_rc() { # <slug> <id> <command sha256> → that check's exit status at base, or nothing
  local b; b=$(sdlc_verify_baseline "$1")
  [ -f "$b" ] || return 0
  awk -F' *\\| *' -v i="$2" -v c="$3" 'index($0, "check: ") == 1 { sub(/^check: */, ""); if ($1 == i && $3 == c) { print $4; exit } }' "$b"
}
# A check named for a requirement (R1, R1.happy, O2) is that requirement's proof.
sdlc_verify_covers_requirement() { # <slug> <check id>
  local r
  for r in $(sdlc_verify_requirement_ids "$1"); do
    [ "$2" = "$r" ] && return 0
    case "$2" in "$r".*) return 0;; esac
  done
  return 1
}
# May this failing check be called pre-existing? Each condition closes a way a
# regression could pass as "it was already broken": a PROJECT-recipe
# build/unit/lint check, not must-fail-on-base, not named for a requirement; the
# usable baseline shows the same id and command failing with the SAME exit
# status, and one that ran (not 124/126/127); its command names no file new
# since the base.
sdlc_verify_preexisting_ok() { # <slug> <id> <kind> <command sha256> <flag> <current exit status>
  local brc pcmd bsha
  case "$3" in build|unit|lint) ;; *) return 1;; esac
  [ -z "${5-}" ] || return 1
  if sdlc_verify_covers_requirement "$1" "$2"; then return 1; fi
  pcmd=$(sdlc_verify_recipe_checks "$(sdlc_verify_recipe)" | awk -F'\t' -v i="$2" '$1 == i { print $3; exit }')
  [ -n "$pcmd" ] || return 1
  sdlc_verify_baseline_usable "$1" || return 1
  brc=$(sdlc_verify_baseline_rc "$1" "$2" "$4")
  case "$brc" in ''|0|124|126|127|*[!0-9]*) return 1;; esac
  [ "$brc" = "${6-}" ] || return 1
  bsha=$(sdlc_field "$(sdlc_verify_baseline "$1")" base_sha || true)
  [ -z "$(sdlc_verify_cmd_new_file "$bsha" "$pcmd")" ] || return 1
  return 0
}
sdlc_verify_paths_since() { # <base sha> [<git diff filter>] → paths changed since base, then untracked ones
  git -c core.quotepath=off diff --name-only --relative ${2:+"$2"} "$1" -- 2>/dev/null
  git -c core.quotepath=off ls-files -o --exclude-standard 2>/dev/null
}
# The files that did not exist at base. `.sdlc/` is records, never source.
sdlc_verify_new_files() { # <base sha> → project-relative paths, one per line
  sdlc_verify_paths_since "$1" --diff-filter=A | awk 'NF && $0 != ".sdlc" && $0 !~ /^\.sdlc\//' | LC_ALL=C sort -u
}
# The first of those files that a command names (as text), or nothing.
sdlc_verify_cmd_new_file() { # <base sha> <command>
  # ENVIRON, not -v: -v would rewrite a backslash in the command text
  sdlc_verify_new_files "$1" | SDLC_C="$2" awk 'index(ENVIRON["SDLC_C"], $0) > 0 { print; exit }'
}
sdlc_verify_changed_files() { # <base sha> → changed/added/untracked paths that exist now
  sdlc_verify_paths_since "$1" | LC_ALL=C sort -u | while IFS= read -r f; do
    case "$f" in ''|.sdlc|.sdlc/*|\"*) continue;; esac
    [ -f "./$f" ] || continue
    printf '%s\n' "$f"
  done
  return 0
}
# The changed files matching test_paths: (shell patterns, `*` also matches `/`):
# what a must-fail-on-base check runs with at base. A subshell, for `set -f`.
sdlc_verify_test_files() ( # <base sha> → project-relative paths, one per line
  set -f
  pats=$(sdlc_verify_field "$(sdlc_verify_recipe)" test_paths | tr ',' ' ')
  [ -n "$pats" ] || exit 0
  sdlc_verify_changed_files "$1" | while IFS= read -r f; do
    for p in $pats; do
      case "$f" in $p) printf '%s\n' "$f"; break;; esac
    done
  done
  exit 0
)
sdlc_verify_test_files_digest() { # <base sha> → digest of those files' paths and content
  local f
  sdlc_verify_test_files "$1" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s %s\n' "$(sdlc_sha256_file "./$f" 2>/dev/null || echo unreadable)" "$f"
  done | sdlc_sha256_stdin
}
# The must-fail-on-base contract, before any receipt is read. "" when it holds
# (or no check asks for it), else "<state>|<detail>".
sdlc_verify_baseline_issue() { # <slug>
  local slug="$1" mf b ids id cmd want brc old="" vac="" norun="" bsha
  mf=$(sdlc_verify_checks "$slug" | awk -F'\t' '$4 == "must-fail-on-base" { print $1 "\t" $3 }')
  [ -n "$mf" ] || return 0
  ids=$(printf '%s\n' "$mf" | sdlc_verify_join)
  b=$(sdlc_verify_baseline "$slug")
  if ! sdlc_verify_baseline_usable "$slug"; then
    echo "missing|$ids must fail without the change, but no baseline for this recipe and a base in HEAD's history is recorded — run tools/verify.sh baseline $slug (add --base <ref> when the change is already committed)"
    return 0
  fi
  # no new test copied in: the base ran the OLD test (or none)
  case "$(sdlc_field "$b" test_files || true)" in ''|0)
    echo "missing|the baseline copied no changed test file into the base, so $ids never ran with the new test — re-run tools/verify.sh baseline $slug"; return 0;;
  esac
  while IFS='	' read -r id cmd; do
    [ -n "$id" ] || continue
    want=$(printf '%s' "$cmd" | sdlc_sha256_stdin)
    brc=$(sdlc_verify_baseline_rc "$slug" "$id" "$want")
    case "$brc" in
      '') old="$old${old:+, }$id";;
      0)  vac="$vac${vac:+, }$id";;
      124|126|127) norun="$norun${norun:+, }$id (exit $brc)";;
    esac
  done <<EOF
$mf
EOF
  if [ -n "$old" ]; then
    echo "missing|the baseline predates the current command of $old — re-run tools/verify.sh baseline $slug"; return 0; fi
  bsha=$(sdlc_field "$b" base_sha || true)
  if [ -n "$vac" ]; then
    echo "vacuous|check $vac passes without the change (at base ${bsha%"${bsha#????????}"}), so it proves nothing — make the test exercise the change, then re-run tools/verify.sh baseline $slug"; return 0; fi
  if [ -n "$norun" ]; then
    echo "vacuous|check $norun could not run at base ${bsha%"${bsha#????????}"} (124 timed out, 126 not executable, 127 not found) — a command that never ran did not fail, so it proves nothing; make it runnable against the base (test_paths:, baseline_setup:), then re-run tools/verify.sh baseline $slug"; return 0; fi
  if [ "$(sdlc_verify_test_files_digest "$bsha")" != "$(sdlc_field "$b" test_files_digest || true)" ]; then
    echo "stale|the test files changed since the baseline ran them at base — re-run tools/verify.sh baseline $slug"; return 0; fi
  return 0
}
# "<state>|<detail>":
#   ok            — every configured check ran and passed over THIS source (a
#                   build/unit/lint failure the baseline shows at base too is
#                   pre-existing and listed, not counted)
#   fail          — a configured check failed
#   flaky         — a runtime/e2e check failed, then passed on its one re-run
#   inconclusive  — the source changed WHILE the checks ran: the result belongs
#                   to no single snapshot
#   stale         — the source, the recipe, or the baselined tests changed
#                   after the receipt / baseline
#   missing       — a recipe exists but no receipt does, or a must-fail-on-base
#                   check has no baseline
#   invalid       — the receipt does not hold together: a missing or rewritten
#                   log, a command that is not the recipe's, checks unaccounted
#   blocked       — strict profile without the runtime proof it demands, a
#                   failed doctor, a runtime nobody owned, a failed cleanup, or
#                   no git repository (the receipt binds no source)
#   uncovered     — a requirement id has no check and no gap line, or the
#                   requirement file holds no id at all
#   vacuous       — a must-fail-on-base check passed at base, or could not run
#                   there (exit 124/126/127): it proves nothing
#   recipe        — the recipe itself is malformed, unfilled, or names a
#                   forbidden host
#   unconfigured  — no .sdlc/verify.md in this project
sdlc_verify_state() { # <slug>
  local slug="$1" rec cur profile before after issue n conf run line id kind rc csha osha log label want flag
  local all cov unc weak gapl pre="" detail rf
  [ -f "$(sdlc_verify_recipe)" ] || { echo "unconfigured|no .sdlc/verify.md (templates/verify.md) — runtime proof is not machine-checked here"; return 0; }
  issue=$(sdlc_verify_recipe_issue "$slug")
  [ -z "$issue" ] || { echo "recipe|the verification recipe is not usable: ${issue#* } — fix it, then re-run tools/verify.sh run $slug"; return 0; }
  rec=$(sdlc_verify_receipt "$slug")
  profile=$(sdlc_verify_profile)
  all=$(sdlc_verify_checks "$slug")
  # a requirement file with no id the reader recognises covers nothing
  rf=$(sdlc_verify_requirement_file "$slug")
  if [ -f "$rf" ] && [ -z "$(sdlc_verify_requirement_ids "$slug")" ]; then
    echo "uncovered|no requirement ids found in $rf — write each as '- R<n>: <text>' (spec.md) or '- [ ] O<n>: <text>' (compact intent.md), then cover them (tools/verify.sh coverage $slug)"; return 0
  fi
  cov=$(sdlc_verify_coverage "$slug")
  unc=$(printf '%s\n' "$cov" | sdlc_verify_join '^uncovered$')
  weak=$(printf '%s\n' "$cov" | sdlc_verify_join '^no-runtime$')
  if [ -n "$unc$weak" ]; then
    detail=""
    [ -z "$unc" ] || detail="no check covers $unc"
    [ -z "$weak" ] || detail="${detail:+$detail; }strict profile: no runtime/e2e check covers $weak"
    echo "uncovered|$detail — add 'check: <id>[.<variant>] | <kind> | <command>' or 'gap: <id> | <reason>' (see tools/verify.sh coverage $slug)"; return 0
  fi
  gapl=$(printf '%s\n' "$cov" | sdlc_verify_join '^gap$')
  issue=$(sdlc_verify_baseline_issue "$slug")
  [ -z "$issue" ] || { echo "$issue"; return 0; }
  [ -f "$rec" ] || { echo "missing|no verification receipt — run tools/verify.sh run $slug"; return 0; }
  if [ "$(sdlc_field "$rec" receipt_schema || true)" != "sdlc-kit/verify-receipt@1" ]; then
    echo "invalid|$rec is not a sdlc-kit/verify-receipt@1 receipt — re-run tools/verify.sh run $slug"; return 0; fi
  cur=$(sdlc_source_digest 2>/dev/null || echo unbound)
  before=$(sdlc_field "$rec" source_digest_before || true)
  after=$(sdlc_field "$rec" source_digest_after || true)
  [ -n "$before" ] || before=$(sdlc_field "$rec" source_digest || true)
  [ -n "$after" ] || after="$before"
  if [ -z "$before" ] || [ -z "$after" ]; then
    echo "invalid|the receipt binds no source identity — re-run tools/verify.sh run $slug"; return 0; fi
  # the compatibility alias must agree with the field it aliases
  if [ -n "$(sdlc_field "$rec" source_digest || true)" ] && [ "$(sdlc_field "$rec" source_digest || true)" != "$after" ]; then
    echo "invalid|the receipt's source_digest and source_digest_after disagree — re-run tools/verify.sh run $slug"; return 0; fi
  if [ "$before" != "$after" ]; then
    echo "inconclusive|the source changed while the checks ran, so the result belongs to no single snapshot — re-run tools/verify.sh run $slug"; return 0; fi
  if [ "$after" != "$cur" ]; then
    echo "stale|the source changed after the receipt was recorded — re-run tools/verify.sh run $slug"; return 0; fi
  if [ "$(sdlc_field "$rec" recipe_digest || true)" != "$(sdlc_verify_recipe_digest)" ]; then
    echo "stale|.sdlc/verify.md changed after the receipt was recorded — re-run tools/verify.sh run $slug"; return 0; fi
  # this slug's own feature recipe only; an older receipt binds none (`none`)
  want=$(sdlc_field "$rec" feature_recipe_digest || true)
  if [ "${want:-none}" != "$(sdlc_verify_feature_recipe_digest "$slug")" ]; then
    echo "stale|$(sdlc_verify_feature_recipe "$slug") changed after the receipt was recorded — re-run tools/verify.sh run $slug"; return 0; fi
  case "$(sdlc_field "$rec" doctor || true)" in
    fail*) echo "blocked|the environment doctor command failed — no runnable environment, so nothing is verified"; return 0;;
    unowned-runtime*) echo "blocked|the doctor passed but the runtime this run launched was already dead: something else answered — re-run tools/verify.sh run $slug"; return 0;;
  esac
  case "$(sdlc_field "$rec" cleanup || true)" in
    failed*) echo "blocked|the run could not stop what it started (see $rec) — a leftover runtime makes the next result meaningless"; return 0;;
  esac
  case "$(sdlc_field "$rec" result || true)" in
    pass) ;;
    inconclusive) echo "inconclusive|the run did not reach a verdict — see $rec"; return 0;;
    flaky) echo "flaky|check $(grep '^check: ' "$rec" | awk -F' *\\| *' '$7 ~ /^flaky/ { sub(/^check: */, "", $1); printf "%s%s", s, $1; s = ", " }') failed, then passed on one re-run — a result that changes between runs proves nothing; make it deterministic, then re-run tools/verify.sh run $slug"; return 0;;
    *) echo "fail|a configured verification check failed — see $rec, fix it, then re-run tools/verify.sh run $slug"; return 0;;
  esac
  # every configured check must be accounted for, and its log must still be the
  # one that was hashed. A receipt that cites a log nobody wrote is not evidence.
  conf=$(printf '%s\n' "$all" | grep -c . || true)
  n=$(grep -c '^check: ' "$rec" 2>/dev/null || true)
  run=$(sdlc_field "$rec" checks_run || true)
  if [ "${n:-0}" != "${conf:-0}" ] || [ "$(sdlc_field "$rec" checks_configured || true)" != "${conf:-0}" ]; then
    echo "invalid|the receipt records ${n:-0} of ${conf:-0} configured checks — re-run tools/verify.sh run $slug"; return 0; fi
  if [ "${run:-}" != "${conf:-0}" ]; then
    echo "invalid|the receipt says ${run:-?} of ${conf:-0} configured checks actually ran — re-run tools/verify.sh run $slug"; return 0; fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS='|' read -r id kind rc csha osha log label <<EOF
$(printf '%s' "${line#check: }" | awk -F' *\\| *' '{print $1"|"$2"|"$3"|"$4"|"$5"|"$6"|"$7}')
EOF
    IFS='	' read -r want flag <<EOF
$(printf '%s\n' "$all" | awk -F'\t' -v i="$id" '$1 == i { print $3 "\t" $4; exit }')
EOF
    if [ -z "$want" ]; then
      echo "invalid|the receipt records a check '$id' the recipe does not configure — re-run tools/verify.sh run $slug"; return 0; fi
    if [ "$csha" != "$(printf '%s' "$want" | sdlc_sha256_stdin)" ]; then
      echo "invalid|check '$id' was recorded for a different command than the recipe's — re-run tools/verify.sh run $slug"; return 0; fi
    case "$rc" in ''|*[!0-9]*) echo "invalid|check '$id' records no numeric exit status — re-run tools/verify.sh run $slug"; return 0;; esac
    case "$kind" in build|unit|lint|runtime|e2e|data) ;; *)
      echo "invalid|check '$id' records an unknown kind '$kind' — re-run tools/verify.sh run $slug"; return 0;; esac
    if [ ! -f "$log" ]; then
      echo "invalid|check '$id' cites a log that does not exist ($log) — re-run tools/verify.sh run $slug"; return 0; fi
    if [ "$(sdlc_sha256_file "$log" 2>/dev/null || true)" != "$osha" ]; then
      echo "invalid|the log of check '$id' ($log) changed after it was recorded — re-run tools/verify.sh run $slug"; return 0; fi
    # a failure passes only as pre-existing, re-derived from the baseline: the
    # receipt's own label is never enough
    if [ "$rc" != 0 ]; then
      if sdlc_verify_preexisting_ok "$slug" "$id" "$kind" "$csha" "$flag" "$rc"; then
        pre="$pre${pre:+, }$id"
      elif [ "$label" = pre-existing ]; then
        echo "fail|check '$id' is labelled pre-existing, but no baseline for this recipe shows it failing at base — re-run tools/verify.sh baseline $slug, then tools/verify.sh run $slug"; return 0
      else
        echo "fail|check '$id' failed (exit $rc) — see $log, fix it, then re-run tools/verify.sh run $slug"; return 0
      fi
    fi
  done <<EOF
$(grep '^check: ' "$rec" 2>/dev/null || true)
EOF
  # without git the source snapshot is empty: every receipt would look current
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "blocked|not a git repository: the receipt cannot bind the source it ran over (every snapshot looks the same), so nothing shows these results are about the code on disk"; return 0; fi
  if [ "$profile" = strict ]; then
    if [ "$(sdlc_field "$rec" runtime_evidence || true)" != yes ]; then
      echo "blocked|strict profile: no runtime or e2e check ran, so review-ready cannot be claimed"; return 0; fi
    case "$(sdlc_field "$rec" runtime_instance || true)" in
      external)
        echo "blocked|strict profile: the checks ran against an EXTERNAL instance this run did not launch (--no-launch), so nothing proves it runs this source"; return 0;;
    esac
    if [ -n "$(sdlc_verify_field "$(sdlc_verify_recipe)" launch)" ] && \
       [ "$(sdlc_field "$rec" doctor || true)" != pass ]; then
      echo "blocked|strict profile: the recipe launches a runtime but no doctor command proved the launched instance was ready and is the one under test"; return 0; fi
  fi
  detail="receipt bound to this source ($(sdlc_field "$rec" recorded_at || true))"
  [ -z "$pre" ] || detail="$detail; pre-existing (failed with the same exit status at base $(sdlc_verify_baseline_label "$slug") too, not counted against this change): $pre"
  [ -z "$gapl" ] || detail="$detail; gap (recipe gap: line, not checked): $gapl"
  echo "ok|$detail"
}

# How the SHIP gates read that state — approve.sh ship, close.sh shipped,
# check-gate.sh ship, tools/handoff.sh, tools/auto.sh and status.sh all use this
# one table, so none can be more permissive than another. Sets V_VERDICT,
# V_STATE, V_DETAIL and V_FIX (the command that fixes a refusing state):
#   pass      ok
#   note      unconfigured (no recipe: runtime proof is not machine-checked)
#   accepted  blocked, and the human accepted this gap: the words passed in
#             (--accept-gap), or with `record` the ship approval's acceptance
#             of this SAME gap
#   gap       blocked, and nobody accepted it
#   refuse    every other state — fixed, never accepted
sdlc_verify_gate() { # <slug> [<the human's words>] [record]
  local st; st=$(sdlc_verify_state "$1")
  sdlc_verify_verdict "$1" "${st%%|*}" "${st#*|}" "${2-}" "${3-}"
}
sdlc_verify_verdict() { # <slug> <state> <detail> [<words>] [record] — the table, over a state already read
  local rec=".sdlc/approvals/$1.ship.approval"
  V_STATE="$2"; V_DETAIL="$3"; V_FIX=$(sdlc_verify_fix_cmd "$1" "$2" "$3")
  case "$2" in
    ok) V_VERDICT=pass;;
    unconfigured) V_VERDICT=note;;
    blocked)
      if [ -n "${4-}" ]; then V_VERDICT=accepted
      elif [ "${5-}" = record ] && [ -f "$rec" ] && [ -n "$(sdlc_field "$rec" verify_gap_accepted || true)" ] \
           && [ "$(sdlc_field "$rec" verify_gap || true)" = "$3" ]; then V_VERDICT=accepted
      else V_VERDICT=gap; fi;;
    *) V_VERDICT=refuse;;
  esac
}
# The human's --accept-gap words go verbatim into ONE `key: value` record line:
# a CR or LF would forge fields, and blank words record nobody's decision.
sdlc_verify_gap_words_issue() { # <words> → "" when usable, else the reason
  case "${1-}" in
    *"$(printf '\r')"*|*"
"*) echo "--accept-gap must be one line: the human's words go verbatim into a record line, so a CR or LF is refused"; return 0;;
  esac
  [ -n "$(printf '%s' "${1-}" | tr -d ' \t')" ] || echo "--accept-gap needs the human's words, e.g. --accept-gap \"ship it; no staging env this sprint\""
  return 0
}
# The command that addresses a verification state.
sdlc_verify_fix_cmd() { # <slug> <state> <detail>
  case "$3" in
    *"tools/verify.sh baseline"*) echo "tools/verify.sh baseline $1";;
    *) case "$2" in
         uncovered) echo "tools/verify.sh coverage $1";;
         *) echo "tools/verify.sh run $1";;
       esac;;
  esac
}

# --- delivery / review handoff ------------------------------------------------
# Backward-compatible extension of templates/delivery.md: Branch, Remote,
# Handoff and Authorized-by are OPTIONAL. A delivery.md without them behaves
# exactly as it did in v0.9.0.
sdlc_auto_handoff_target() { # <delivery.md> → review-ready | merged | deployed | local | unknown
  local del="$1" h t
  [ -f "$del" ] || { echo unknown; return 0; }
  h=$(sdlc_delivery_field "$del" Handoff | awk '{print tolower($1)}')
  case "$h" in review-ready|merged|deployed) echo "$h"; return 0;; esac
  t=$(sdlc_delivery_field "$del" Target | awk '{print tolower($1)}')
  case "$t" in local) echo local;; pr) echo review-ready;; deploy) echo deployed;; *) echo unknown;; esac
}

# --- checkpoint ---------------------------------------------------------------
# The artifacts stay the authority. The checkpoint holds ONLY pending execution
# metadata: which step is in flight, how many attempts it has had, and which
# external effects already happened (so a resume never repeats one).
sdlc_checkpoint_file() { echo ".sdlc/work/$1/checkpoint.md"; }
sdlc_checkpoint_attempts() { # <slug> <step> → n (0 when the source moved on)
  local f; f=$(sdlc_checkpoint_file "$1")
  [ -f "$f" ] || { echo 0; return 0; }
  if [ "$(sdlc_field "$f" source_digest || true)" != "$(sdlc_source_digest 2>/dev/null || echo unbound)" ]; then
    echo 0; return 0; fi
  awk -v s="$2" -F' *\\| *' '/^attempt: /{ sub(/^attempt: /,""); if ($1 == s) n = $3 } END { print n + 0 }' "$f"
}
sdlc_checkpoint_state() { # <slug> → "<state>|<detail>"; fresh | stale | none
  local f; f=$(sdlc_checkpoint_file "$1")
  [ -f "$f" ] || { echo "none|no checkpoint"; return 0; }
  if [ "$(sdlc_field "$f" source_digest || true)" != "$(sdlc_source_digest 2>/dev/null || echo unbound)" ]; then
    echo "stale|the source changed since the checkpoint — attempt counters reset, receipts invalid"; return 0; fi
  echo "fresh|step $(sdlc_field "$f" step || echo -)"
}
