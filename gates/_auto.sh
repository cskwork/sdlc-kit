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
sdlc_auto_artifact_for() { case "$1" in
  intent) echo intent.md;; spec) echo spec.md;; plan) echo plan.md;; ship) echo evidence.md;; esac; }

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
      echo "stale|$(sdlc_auto_artifact_for "$up") changed since the $stage approval — re-approve $up, then $stage"; return 0; fi
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

# --- verification receipts ----------------------------------------------------
# The recipe is .sdlc/verify.md (templates/verify.md). Receipts are written by
# tools/verify.sh from commands it executed itself, and every field a reader
# depends on is re-checked here: the log files the receipt cites must exist and
# still hash to the digests it recorded, the command digests must match the
# recipe's commands, and the number of checks must account for every configured
# one. That is CHANGE DETECTION, not authentication — a receipt says "these
# commands produced these bytes over this source", never "a trustworthy party
# ran them". An independent reviewer (roles/verifier.md) is still required.
sdlc_verify_recipe() { echo ".sdlc/verify.md"; }
sdlc_verify_receipt() { echo ".sdlc/work/$1/verify-receipt.md"; }
sdlc_verify_profile() { # → strict | advisory (default advisory; absent recipe = advisory)
  local p
  p=$(awk '/^profile: /{gsub(/\r/,""); print $2; exit}' "$(sdlc_verify_recipe)" 2>/dev/null || true)
  case "$p" in strict) echo strict;; *) echo advisory;; esac
}
sdlc_verify_recipe_digest() {
  local r; r=$(sdlc_verify_recipe)
  [ -f "$r" ] && sdlc_sha256_file "$r" || echo none
}
sdlc_verify_field() { # <recipe> <key> → value, \r stripped
  awk -v k="$2: " 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$1" 2>/dev/null | tr -d '\r'
}
# The configured checks, one per line: "<id>\t<kind>\t<command>". The single
# parser both tools/verify.sh (which runs them) and the receipt validation
# below (which re-derives their digests) use, so the two cannot drift apart.
sdlc_verify_recipe_checks() { # [recipe] → tab-separated lines
  local r="${1:-$(sdlc_verify_recipe)}"
  [ -f "$r" ] || return 0
  awk '
    function trim(x) { sub(/^[ \t]+/, "", x); sub(/[ \t\r]+$/, "", x); return x }
    index($0, "check:") == 1 {
      body = substr($0, 7); sub(/\r$/, "", body)
      p = index(body, "|"); if (p == 0) { print "\t\t" trim(body); next }
      id = trim(substr(body, 1, p - 1)); rest = substr(body, p + 1)
      q = index(rest, "|"); if (q == 0) { print id "\t" trim(rest) "\t"; next }
      kind = trim(substr(rest, 1, q - 1)); cmd = trim(substr(rest, q + 1))
      print id "\t" tolower(kind) "\t" cmd
    }' "$r"
}
# A recipe that is malformed or still half a template must be refused BEFORE
# anything is executed: `sh -c "<e.g. npm test>"` is not a verification, and the
# 60s doctor wait it burns looks like a real one in the log.
sdlc_verify_recipe_issue() { # [recipe] → "" when usable, else "<code> <message>"
  local r="${1:-$(sdlc_verify_recipe)}" v k
  [ -f "$r" ] || { echo "absent no $r"; return 0; }
  v=$(sdlc_verify_field "$r" profile)
  case "$v" in ''|strict|advisory) ;; *) echo "profile profile must be 'strict' or 'advisory' (found '$v')"; return 0;; esac
  for k in launch doctor cleanup environment; do
    v=$(sdlc_verify_field "$r" "$k")
    case "$v" in '<'*) echo "placeholder the '$k:' line is still the template placeholder ($v)"; return 0;; esac
  done
  for k in doctor_timeout check_timeout cleanup_timeout; do
    v=$(sdlc_verify_field "$r" "$k")
    case "$v" in '') ;; *[!0-9]*) echo "timeout '$k: $v' must be a whole number of seconds"; return 0;; esac
  done
  sdlc_verify_recipe_checks "$r" | awk -F'\t' '
    BEGIN { n = 0; bad = "" }
    {
      n++
      id = $1; kind = $2; cmd = $3
      if (bad != "") next
      if (id == "" || cmd == "") { bad = "malformed check line " n " needs '\''check: <id> | <kind> | <command>'\''"; next }
      if (id ~ /[^a-zA-Z0-9._-]/) { bad = "id check id '\''" id "'\'' must be [a-zA-Z0-9._-]+ (it names a log file)"; next }
      if (kind != "build" && kind != "unit" && kind != "lint" && kind != "runtime" && kind != "e2e")
        { bad = "kind check '\''" id "'\'' has kind '\''" kind "'\'' — use build|unit|lint|runtime|e2e"; next }
      if (substr(cmd, 1, 1) == "<") { bad = "placeholder check '\''" id "'\'' still holds the template placeholder (" cmd ")"; next }
      if (seen[id]++) { bad = "duplicate two checks share the id '\''" id "'\''"; next }
    }
    END {
      if (bad != "") { print bad; exit }
      if (n == 0) print "empty the recipe configures no check: line — nothing would be verified"
    }'
}
# "<state>|<detail>":
#   ok            — every configured check ran and passed over THIS source
#   fail          — a configured check failed
#   inconclusive  — the source changed WHILE the checks ran: the result belongs
#                   to no single snapshot
#   stale         — the source or the recipe changed after the receipt
#   missing       — a recipe exists but no receipt does
#   invalid       — the receipt does not hold together: a missing or rewritten
#                   log, a command that is not the recipe's, checks unaccounted
#   blocked       — strict profile without the runtime proof it demands, a
#                   failed doctor, a runtime nobody owned, or a failed cleanup
#   recipe        — .sdlc/verify.md itself is malformed or unfilled
#   unconfigured  — no .sdlc/verify.md in this project
sdlc_verify_state() { # <slug>
  local slug="$1" rec cur profile before after issue n conf run line id kind rc csha osha log want
  [ -f "$(sdlc_verify_recipe)" ] || { echo "unconfigured|no .sdlc/verify.md (templates/verify.md) — runtime proof is not machine-checked here"; return 0; }
  issue=$(sdlc_verify_recipe_issue)
  [ -z "$issue" ] || { echo "recipe|.sdlc/verify.md is not usable: ${issue#* } — fix it, then re-run tools/verify.sh run $slug"; return 0; }
  rec=$(sdlc_verify_receipt "$slug")
  profile=$(sdlc_verify_profile)
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
    *) echo "fail|a configured verification check failed — see $rec"; return 0;;
  esac
  # every configured check must be accounted for, and its log must still be the
  # one that was hashed. A receipt that cites a log nobody wrote is not evidence.
  conf=$(sdlc_verify_recipe_checks | grep -c . || true)
  n=$(grep -c '^check: ' "$rec" 2>/dev/null || true)
  run=$(sdlc_field "$rec" checks_run || true)
  if [ "${n:-0}" != "${conf:-0}" ] || [ "$(sdlc_field "$rec" checks_configured || true)" != "${conf:-0}" ]; then
    echo "invalid|the receipt records ${n:-0} of ${conf:-0} configured checks — re-run tools/verify.sh run $slug"; return 0; fi
  if [ "${run:-}" != "${conf:-0}" ]; then
    echo "invalid|the receipt says ${run:-?} of ${conf:-0} configured checks actually ran — re-run tools/verify.sh run $slug"; return 0; fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS='|' read -r id kind rc csha osha log <<EOF
$(printf '%s' "${line#check: }" | awk -F' *\\| *' '{print $1"|"$2"|"$3"|"$4"|"$5"|"$6}')
EOF
    want=$(sdlc_verify_recipe_checks | awk -F'\t' -v i="$id" '$1 == i { print $3; exit }')
    if [ -z "$want" ]; then
      echo "invalid|the receipt records a check '$id' the recipe does not configure — re-run tools/verify.sh run $slug"; return 0; fi
    if [ "$csha" != "$(printf '%s' "$want" | sdlc_sha256_stdin)" ]; then
      echo "invalid|check '$id' was recorded for a different command than the recipe's — re-run tools/verify.sh run $slug"; return 0; fi
    case "$rc" in ''|*[!0-9]*) echo "invalid|check '$id' records no numeric exit status — re-run tools/verify.sh run $slug"; return 0;; esac
    case "$kind" in build|unit|lint|runtime|e2e) ;; *)
      echo "invalid|check '$id' records an unknown kind '$kind' — re-run tools/verify.sh run $slug"; return 0;; esac
    if [ ! -f "$log" ]; then
      echo "invalid|check '$id' cites a log that does not exist ($log) — re-run tools/verify.sh run $slug"; return 0; fi
    if [ "$(sdlc_sha256_file "$log" 2>/dev/null || true)" != "$osha" ]; then
      echo "invalid|the log of check '$id' ($log) changed after it was recorded — re-run tools/verify.sh run $slug"; return 0; fi
  done <<EOF
$(grep '^check: ' "$rec" 2>/dev/null || true)
EOF
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
  echo "ok|receipt bound to this source ($(sdlc_field "$rec" recorded_at || true))"
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
