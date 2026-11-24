# Store upkeep for sdlc.sh, sourced by it (not run alone): the .state lock, the memory index, the
# close-time memory decision and log pruning, and the dream brief. Uses sdlc.sh's helpers and globals.
# A command that writes .state holds $F/.state.lock (mkdir is atomic everywhere) from load to save, so
# two runs on one slug cannot both read the old state and the later write drop the earlier one. A lock
# whose owner pid is gone, or that never got a pid within a minute, is reclaimed.
# Reclaiming is serialized by a second mkdir lock and re-checks the owner inside it. Without that, a waiter
# that read a dead owner could remove a lock another waiter had just taken after the owner's own exit
# removed it, and two runs would hold the lock. Inside the reclaim lock, a lock dir whose owner is dead
# cannot change: the dead owner never removes it, no one can mkdir over it, and other reclaimers wait.
# The window left: a reclaimer that stalls over a minute inside the reclaim lock has it broken by another.
lock_stale() {
  { [ -n "$1" ] && ! kill -0 "$1" 2>/dev/null; } || { [ -z "$1" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; }
}
reclaim_lock() {
  local mutex=$LOCK.reclaim owner
  if ! mkdir "$mutex" 2>/dev/null; then
    [ -z "$(find "$mutex" -maxdepth 0 -mmin +1 2>/dev/null)" ] || rmdir "$mutex" 2>/dev/null || :
    return 0
  fi
  owner=$(cat "$LOCK/pid" 2>/dev/null) || owner=
  if [ -d "$LOCK" ] && lock_stale "$owner"; then rm -rf "$LOCK"; fi
  rmdir "$mutex" 2>/dev/null || :
}
lock_state() {
  local tries=0 owner limit=$(( ${SDLC_LOCK_WAIT:-30} * 10 ))
  LOCK=$F/.state.lock
  while ! mkdir "$LOCK" 2>/dev/null; do
    [ -d "$F" ] || die "feature moved while waiting for its lock: $slug"
    owner=$(cat "$LOCK/pid" 2>/dev/null) || owner=
    if [ -d "$LOCK" ] && lock_stale "$owner"; then reclaim_lock; [ -d "$LOCK" ] || continue; fi
    [ "$tries" -lt "$limit" ] || die "$slug is locked by another sdlc.sh run${owner:+ (pid $owner)}: retry when it ends, or remove $LOCK if no run is alive"
    sleep 0.1; tries=$((tries+1))
  done
  printf '%s\n' "$$" > "$LOCK/pid"
  trap 'rm -rf "$LOCK"' EXIT
}
# A number from config.md key $1, else $2.
setting() { local v; v=$(value "$STORE/config.md" "$1"); case "$v" in ''|*[!0-9]*) printf '%s' "$2";; *) printf '%s' "$v";; esac; }
memdir() { case "$memory" in /*|[A-Za-z]:*) MEM=$memory;; *) MEM=$ROOT/$memory;; esac; }
kb() { du -sk "$1" 2>/dev/null | awk '{print $1+0}'; }
# Every page of the memory folder (*.md, not INDEX.md, nothing under a dot name), one path per line, sorted.
memory_pages() { (cd "$MEM" && find . -name '.*' ! -name . -prune -o -type f -name '*.md' -print) | sed 's|^\./||' | grep -v '^INDEX\.md$' | LC_ALL=C sort || :; }
# One line for page $1, fields split by \034: summary (a Summary: line, else the first heading), [verified: …] count,
# the short sha of the last verified tag that names one (path @ sha), [unconfirmed] count, [source: …] count,
# 1 when a line starts with MOVED TO (a merged page's stub), 1 when it has a "## Current picture" heading.
page_facts() {
  awk "$UNCOMMENT"'{if(uncomment())next}
  !sum&&tolower($0)~/^[ \t>*_-]*summary[ \t*_]*:/{s=$0;sub(/^[^:]*:[ \t*_]*/,"",s);sub(/[ \t]+$/,"",s);if(s!="")sum=s}
  !head&&/^#+[ \t]+[^ \t]/{h=$0;sub(/^#+[ \t]+/,"",h);sub(/[ \t#]+$/,"",h);head=h}
  /^[ \t]*MOVED TO[ \t]/{moved=1} tolower($0)~/^##[ \t]+current picture[ \t]*$/{pic=1}
  {l=$0;while((i=index(l,"[verified:"))>0){n++;l=substr(l,i+1);j=index(l,"]");tag=j?substr(l,1,j):l;if(match(tag,/@[ \t]*[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]/)){s=substr(tag,RSTART,RLENGTH);sub(/^@[ \t]*/,"",s);last=tolower(s)}}
   l=tolower($0);while((i=index(l,"[unconfirmed"))>0){u++;l=substr(l,i+1)}
   l=tolower($0);while((i=index(l,"[source:"))>0){src++;l=substr(l,i+1)}}
  END{printf "%s\034%d\034%s\034%d\034%d\034%d\034%d\n",(sum!=""?sum:head),n,last,u,src,moved,pic}' "$1"
}
# Relative link targets of page $1, one per line: Markdown links and <angle> links, anchors and URLs dropped.
page_links() {
  awk "$UNCOMMENT"'{if(uncomment())next;l=$0
   while((i=index(l,"]("))>0){l=substr(l,i+2);if(substr(l,1,1)=="<"){j=index(l,">");t=substr(l,2,j-2)}else{j=index(l,")");t=j?substr(l,1,j-1):l;sub(/[ \t].*/,"",t)}
    sub(/#.*/,"",t);if(t!=""&&t!~/^[A-Za-z][A-Za-z0-9+.-]*:/)print t}}' "$1"
}
# The ## Core section of INDEX.md (hand-kept, above the generated block): its non-blank lines and bytes.
core_size() { LC_ALL=C awk "$UNCOMMENT"'/^<!-- sdlc:index start/{exit} {if(uncomment())next} /^## /{c=(tolower($0)~/^## core[ \t]*$/);next} /^# /{c=0;next} c&&/[^ \t]/{n++;b+=length($0)+1} END{print n+0, b+0}' "$1"; }
CORE_STUB='## Core

<!-- The few rules every agent needs, one line each: the rule, then a link to the page that proves it. Hand-kept,
at most 25 lines and memory_core_kb; the dreamer promotes and demotes them. -->
'
# Rebuilds the block between the sdlc:index markers in INDEX.md, one line per page grouped by folder;
# text outside the block is the human's and stays (a ## Core stub is added above the block when missing).
# Prints a one-line count and a lint line, and warns on budgets and on each lint finding.
memory_index() {
  local page dir group= bytes summary nv last nu ns moved pic line block tmp total=0 top=0 pages=0 missing=0 maxtop maxtotal
  local core= cl cb maxcore pagekb link dangling=0 stubs=0 nobasis=0 big=0 nopic=0
  memdir; [ -d "$MEM" ] || die "no memory folder: $MEM (config.md memory:)"
  pagekb=$(setting memory_page_kb 16)
  block=$(printf '%s\n' '<!-- sdlc:index start: rebuilt by sdlc.sh memory index; edit the pages, not these lines -->' '## Pages')
  while IFS= read -r page; do
    [ -n "$page" ] || continue
    pages=$((pages+1)); bytes=$(wc -c < "$MEM/$page" | awk '{print $1+0}'); total=$((total+bytes))
    case "$page" in */*) dir=${page%/*}/;; *) dir=./; top=$((top+bytes));; esac
    if [ "$dir" != "$group" ]; then group=$dir; block="$block"$'\n'"### $dir"; fi
    IFS=$'\034' read -r summary nv last nu ns moved pic < <(page_facts "$MEM/$page")
    if [ -z "$summary" ]; then missing=$((missing+1)); err "memory page without a summary: $page (start it with a \"# title\" or a \"Summary:\" line)"; summary='(no summary: start the page with a "# title" line)'; fi
    # 120 bytes of summary at most, cut on a character boundary (a cut UTF-8 sequence is dropped whole).
    summary=$(printf '%s' "$summary" | LC_ALL=C awk '{if(length($0)<=120){print;exit}s=substr($0,1,120);for(c=128;c<192;c++)cont=cont sprintf("%c",c);while(s!=""&&index(cont,substr(s,length(s))))s=substr(s,1,length(s)-1);if(s!=""&&substr(s,length(s))>sprintf("%c",191))s=substr(s,1,length(s)-1);print s "…"}')
    line="- [$page](<$page>) — $summary ·"
    if [ "$moved" = 1 ]; then stubs=$((stubs+1)); err "memory page is a MOVED TO stub: $page (repoint links to its target, then delete it)"; line="$line moved"
    else
      if [ "$nv" -gt 0 ]; then line="$line verified $nv${last:+ @ ${last:0:7}}"; else line="$line unverified"; fi
      [ "$ns" -eq 0 ] || line="$line, source $ns"
      [ "$nu" -eq 0 ] || line="$line, unconfirmed $nu"
      [ $((nv+ns+nu)) -gt 0 ] || [ "$page" = glossary.md ] || { nobasis=$((nobasis+1)); err "memory page without a basis tag: $page ([verified: …], [source: …] or [unconfirmed] on each fact)"; }
      if [ "$bytes" -gt $((pagekb*1024)) ]; then big=$((big+1)); err "memory page over memory_page_kb $pagekb: $page ($(( (bytes+1023)/1024 )) KB): split it or push detail into folder pages"; fi
      if [ "$bytes" -gt 8000 ] && [ "$pic" != 1 ]; then nopic=$((nopic+1)); err "memory page over 8000 bytes without a \"## Current picture\" section: $page"; fi
    fi
    block="$block"$'\n'"$line · $(( (bytes+1023)/1024 )) KB"
  done < <(memory_pages)
  [ "$pages" -gt 0 ] || block="$block"$'\n''(no pages yet)'
  block="$block"$'\n''<!-- sdlc:index end -->'
  [ -f "$MEM/INDEX.md" ] && grep -qi '^## core[[:space:]]*$' "$MEM/INDEX.md" || core=$CORE_STUB
  tmp=$(mktemp "$MEM/.INDEX.md.XXXXXX") || die 'cannot write INDEX.md'
  if [ -f "$MEM/INDEX.md" ] && grep -q '^<!-- sdlc:index start' "$MEM/INDEX.md" && grep -q '^<!-- sdlc:index end' "$MEM/INDEX.md"; then
    CORE=$core BLOCK=$block awk '/^<!-- sdlc:index start/{if(ENVIRON["CORE"]!="")print ENVIRON["CORE"];print ENVIRON["BLOCK"];skip=1;next} skip&&/^<!-- sdlc:index end/{skip=0;next} !skip' "$MEM/INDEX.md" > "$tmp" || { rm -f "$tmp"; die 'cannot rebuild INDEX.md'; }
  elif [ -f "$MEM/INDEX.md" ]; then { cat "$MEM/INDEX.md"; printf '\n'; [ -z "$core" ] || printf '%s\n' "$core"; printf '%s\n' "$block"; } > "$tmp"
  else
    { printf '# Memory index\n\nWhat this project taught us that the code cannot tell cheaply: verified facts, rules and traps\nworth reusing. Read ## Core and this list first, then open only the pages a line points to for your question;\nwith no line for it, grep this folder.\n\n'
      printf '%s\n%s\n' "$core" "$block"; } > "$tmp"
  fi
  if [ -f "$MEM/INDEX.md" ] && cmp -s "$tmp" "$MEM/INDEX.md"; then rm -f "$tmp"; else mv "$tmp" "$MEM/INDEX.md"; fi
  # Links that point at no file, from every page and INDEX.md, relative to the linking page.
  while IFS= read -r page; do
    [ -n "$page" ] || continue
    case "$page" in */*) dir=$MEM/${page%/*};; *) dir=$MEM;; esac
    while IFS= read -r link; do
      link=${link//%20/ }; case "$link" in /*) [ -e "$link" ];; *) [ -e "$dir/$link" ];; esac && continue
      dangling=$((dangling+1)); err "memory link points at no file: $page -> $link"
    done < <(page_links "$MEM/$page")
  done < <(memory_pages; echo INDEX.md)
  top=$((top + $(wc -c < "$MEM/INDEX.md")))
  read -r cl cb < <(core_size "$MEM/INDEX.md")
  maxtop=$(setting memory_top_kb 64); maxtotal=$(setting memory_total_kb 256); maxcore=$(setting memory_core_kb 2)
  printf 'Indexed %s pages in %s/INDEX.md (Core %s lines, top level %s KB, all pages %s KB)%s.\n' "$pages" "$MEM" "$cl" "$(( (top+1023)/1024 ))" "$(( (total+1023)/1024 ))" "$( [ "$missing" -eq 0 ] || printf '; %s without a summary' "$missing")"
  printf 'Lint: %s dangling links, %s MOVED TO stubs, %s pages without a basis tag, %s over memory_page_kb %s, %s over 8000 bytes without ## Current picture.\n' "$dangling" "$stubs" "$nobasis" "$big" "$pagekb" "$nopic"
  [ "$cl" -le 25 ] && [ "$cb" -le $((maxcore*1024)) ] || err "memory Core is $cl lines, $(( (cb+1023)/1024 )) KB, over 25 lines or memory_core_kb $maxcore: keep only rules every agent needs, one line and a link each; move the rest into pages (sdlc.sh dream)"
  [ "$top" -le $((maxtop*1024)) ] || err "memory top level is $(( (top+1023)/1024 )) KB, over memory_top_kb $maxtop: move detail from INDEX.md and top-level pages into folder pages (sdlc.sh dream)"
  [ "$total" -le $((maxtotal*1024)) ] || err "memory pages total $(( (total+1023)/1024 )) KB, over memory_total_kb $maxtotal: merge duplicates and prune stale pages (sdlc.sh dream)"
  return 0
}
# The Memory: line of evidence.md, comments and emphasis removed.
memory_line() { awk "$UNCOMMENT"'{if(uncomment())next;gsub(/[`*]/,"");l=$0;sub(/^[ \t]*-[ \t]*/,"",l);if(tolower(l)~/^memory[ \t]*:/){sub(/^[^:]*:[ \t]*/,"",l);sub(/[ \t]+$/,"",l);print l;exit}}' "$F/evidence.md"; }
# close shipped needs a memory decision: the pages updated (paths in the memory folder), or none — why.
memory_decision() {
  local m item low hint
  memdir; m=$(memory_line); low=$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')
  hint="name the memory pages this slug updated (paths in $memory, comma-separated) or write 'none — <why nothing here is worth keeping>'"
  case "$m" in ''|'<'*) die "evidence.md needs a Memory: line under Shipping: $hint";; esac
  if [[ $low =~ ^none([^a-z0-9_]|$) ]]; then
    [[ $low =~ ^none[[:space:]]*(—|–|-|--|:)[[:space:]]*[^[:space:]] ]] || die "Memory: none needs its reason: $hint"
    return 0
  fi
  while IFS= read -r item; do
    item=${item%% — *}; item=${item%% (*}; item=$(one_line "$item"); item=${item#./}; item=${item#"$memory"/}
    [ -n "$item" ] || continue
    case "$item" in /*|*../*) die "Memory: '$item' must be a path inside the memory folder";; esac
    [ -f "$MEM/$item" ] || die "Memory: '$item' is not a page in the memory folder ($memory): $hint"
  done < <(printf '%s\n' "$m" | tr ',' '\n')
}
# Removes reproducible caches (config.md prune:) under the slug's logs/, keeping evidence: Markdown,
# JSON reports, screenshots and every file evidence.md cites as a Log. Prints what it freed.
prune_logs() {
  local names name before after args=() keep=() path
  [ -d "$F/logs" ] || return 0
  if [ -n "$(value "$STORE/config.md" prune 1)" ]; then names=$(value "$STORE/config.md" prune); else names='gradle-home .gradle node_modules build .m2 target'; fi
  for name in ${names//,/ }; do case "$name" in */*|.|..) err "prune: '$name' is not a folder name: skipped";; *) args+=(${args[0]+-o} -name "$name");; esac; done
  [ "${#args[@]}" -gt 0 ] || return 0
  if [ -f "$F/evidence.md" ]; then while IFS= read -r path; do [ -z "$path" ] || keep+=(! -path "$F/$path"); done < <(parse evidence "$F/evidence.md" | awk -F'\034' '$1=="E"{print $5}'); fi
  before=$(kb "$F/logs")
  while IFS= read -r -d '' path; do
    find "$path" ! -type d ! \( -name '*.md' -o -name '*.json' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.gif' -o -name '*.webp' \) ${keep[0]+"${keep[@]}"} -exec rm -f {} + 2>/dev/null || :
    find "$path" -depth -type d -empty -exec rmdir {} \; 2>/dev/null || :
  done < <(find "$F/logs" -type d \( "${args[@]}" \) -print0 -prune)
  after=$(kb "$F/logs")
  [ "$before" -le "$after" ] || printf 'Pruned %s KB of reproducible caches from logs/ (%s).\n' "$((before-after))" "$names"
}
# Closes (shipped or dropped) newer than ISO time $1 (empty: all), one "slug<TAB>result<TAB>time" line each.
closed_since() {
  local s line
  for s in "$STORE"/archive/*/.state; do
    [ -f "$s" ] || continue
    line=$(awk '/^closed: (shipped|dropped) /{print $2 "\t" $3;exit}' "$s"); [ -n "$line" ] || continue
    [ -z "$1" ] || [[ ${line#*$'\t'} > $1 ]] || continue
    printf '%s\t%s\n' "$(basename "$(dirname "$s")")" "$line"
  done
}
dream_state() { awk -F': ' -v k="$1" '$1==k{print substr($0,length(k)+3);exit}' "$MEM/.dream-state" 2>/dev/null || :; }
# Due once dream_every slugs closed since the last dream, or once dream_max_days passed with at least one
# close (never dreamed counts as that many days). No close since the last dream: never due.
dream_due() {
  local last epoch closes every maxdays days
  last=$(dream_state last); epoch=$(dream_state last_epoch)
  closes=$(closed_since "$last" | awk 'END{print NR}'); every=$(setting dream_every 3); maxdays=$(setting dream_max_days 14)
  if [ -n "$epoch" ]; then days=$(( ($(date +%s) - epoch) / 86400 )); else days=$maxdays; fi
  duereason="$closes/$every closes since ${last:-the start}"
  if [ "$closes" -ge "$every" ]; then return 0; fi
  if [ "$closes" -ge 1 ] && [ "$days" -ge "$maxdays" ]; then if [ -n "$epoch" ]; then duereason="$duereason, $days/$maxdays days"; else duereason="$duereason, never dreamed"; fi; return 0; fi
  return 1
}
# config.md key $1 as written (value() drops `, * and # comments, which a shell command needs).
raw_setting() { awk -v key="$1" "$UNCOMMENT"'{if(uncomment())next;if(tolower($0)~"^[ \t]*" key "[ \t]*:"){sub(/^[^:]*:[ \t]*/,"");sub(/[ \t]+$/,"");print;exit}}' "$STORE/config.md"; }
# The transcripts: command for slug $1 ({slug}, and {since} = the last dream's UTC time), run in the project
# root. Each output line is a path or a path:line hit; anything after path:line is dropped, so no transcript
# text reaches the brief. Prints at most $2 distinct hits, each cut to 300 bytes, under a count line.
transcript_hits() {
  local cmd=$transcripts out rc=0
  cmd=${cmd//\{slug\}/$1}; cmd=${cmd//\{since\}/${last:-1970-01-01T00:00:00Z}}
  out=$(cd "$ROOT" && sh -c "$cmd" 2>/dev/null) || rc=$?
  printf '%s\n' "$out" | LC_ALL=C awk -v max="$2" -v rc="$rc" '{gsub(/\r/,"")} !/[^ \t]/{next}
   {if(match($0,/:[0-9]+(:|$)/)){d=substr($0,RSTART+1,RLENGTH-1);sub(/:$/,"",d);$0=substr($0,1,RSTART-1) ":" d}
    if(length($0)>300)$0=substr($0,1,300) "…"; if(seen[$0]++)next; if(++n<=max)hit[n]=$0}
   END{c="none found";if(n)c=n " hits";if(n>max)c=c ", first " max;if(rc>1)c=c " (command exited " rc ")";print "    - Transcripts: " c
    for(i=1;i<=n&&i<=max;i++)print "      - " hit[i]}'
}
# config.md peers: other memory stores the dreamer greps but never edits. Space- or comma-separated paths,
# ~ and globs allowed, relative ones from the project root. Lists each match with its file count and size,
# never its content.
peer_list() {
  local raw p m n kb hits
  raw=$(raw_setting peers); raw=${raw//,/ }
  [ -n "${raw//[[:space:]]/}" ] || { printf -- '- Peers: none (config.md peers: is empty)\n'; return 0; }
  printf -- '- Peers (read-only: grep them for the facts you touch, never edit them):\n'
  ( cd "$ROOT" || exit 0; set -f
    for p in $raw; do
      [ "${p#\~}" = "$p" ] || p=$HOME${p#\~}
      set +f; shopt -s nullglob; hits=($p); shopt -u nullglob; set -f
      [ "${#hits[@]}" -gt 0 ] || { printf '  - %s — no match\n' "$p"; continue; }
      for m in "${hits[@]}"; do
        case $m in /*) ;; *) m=$ROOT/$m;; esac
        n=$(find "$m" -type f 2>/dev/null | awk 'END{print NR}'); kb=$(du -sk "$m" 2>/dev/null | awk '{print $1+0}')
        printf '  - %s — %s files, %s KB\n' "$m" "$n" "${kb:-0}"
      done
    done )
}
# The files under archived slug folder $1's logs/, relative, at most $2 named.
slug_logs() {
  [ -d "$1/logs" ] || { printf '    - Logs: none\n'; return 0; }
  (cd "$1/logs" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) | awk -v max="$2" -v d="$1/logs" '{n++;if(n<=max)l=l (n>1?", ":"") $0} END{t="";if(n)t=": " l;if(n>max)t=t ", …";printf "    - Logs: %s — %d files%s\n", d, n, t}'
}
dream() {
  local last head top slug result ts s transcripts max index cursor=
  memdir; [ -d "$MEM" ] || die "no memory folder: $MEM (config.md memory:)"
  if [ "${1:-}" = --check ]; then if dream_due; then printf 'due: %s\n' "$duereason"; exit 10; fi; printf 'not due: %s\n' "$duereason"; exit 0; fi
  if [ "${1:-}" = --done ]; then shift; dream_done "$@"; return; fi
  last=$(dream_state last); transcripts=$(raw_setting transcripts); max=$(setting transcripts_max 20)
  top=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null) && head=$(git -C "$top" rev-parse --short HEAD 2>/dev/null) || head=
  index=$( (memory_index 2>/dev/null || :) )
  cat "$KIT/roles/dreamer.md"
  printf '\n## This run\n\n- Memory folder: %s\n- Index: %s/INDEX.md — refresh it with `%s/sdlc.sh memory index` after editing pages\n' "$MEM" "$MEM" "$KIT"
  printf -- '- Size: %s; budgets: memory_top_kb %s (INDEX.md and top-level pages), memory_total_kb %s (all pages), memory_core_kb %s and 25 lines (## Core), memory_page_kb %s (one page)\n' \
    "$(printf '%s\n' "$index" | sed -n 's/^Indexed \([0-9]*\) pages in .*(\(.*\)).*/\1 pages, \2/p')" "$(setting memory_top_kb 64)" "$(setting memory_total_kb 256)" "$(setting memory_core_kb 2)" "$(setting memory_page_kb 16)"
  printf '%s\n' "$index" | sed -n 's/^Lint: /- Lint: /p'
  printf -- '- Code at HEAD: %s\n' "${head:+$top @ $head}$( [ -n "$head" ] || printf 'no commit at the project root: verify against the files as they are')"
  if [ -n "$transcripts" ]; then printf -- '- Transcripts: `%s` — hits per slug below; grep them, never read whole files\n' "$transcripts"
  else printf -- '- Transcripts: none (config.md transcripts: is empty); check sessions against each slug'"'"'s logs/ only\n'; fi
  peer_list
  printf -- '- Last dream: %s\n- Slugs closed since:%s\n' "${last:-never}" "$(closed_since "$last" | awk 'END{if(!NR)print " none"}')"
  while IFS=$'\t' read -r slug result ts; do
    s=$STORE/archive/$slug
    if [ "$result" = shipped ]; then
      F=$s; printf '  - %s (shipped %s) — Memory: %s — %s/evidence.md, %s/review.md (last round only)\n' "$slug" "$ts" "$( [ -f "$s/evidence.md" ] && memory_line || :)" "$s" "$s"
    else printf '  - %s (dropped %s) — nothing to harvest unless %s/intent.md holds a reusable fact\n' "$slug" "$ts" "$s"; fi
    [ -z "$transcripts" ] || transcript_hits "$slug" "$max"
    slug_logs "$s" "$max"
    [[ $ts < $cursor ]] || cursor=$ts
  done < <(closed_since "$last")
  printf -- '- Report: append it to %s/.dream-log.md\n' "$MEM"
  printf -- '- When done: `%s/sdlc.sh dream --done%s` records this run (slugs closed later stay due)\n' "$KIT" "${cursor:+ --through $cursor}"
}
# Records a finished dream over the slugs closed after the last one up to ISO time --through (default: every
# close so far): .dream-state's last, last_epoch and slugs, and a .dream-log.md line if the dreamer wrote none.
dream_done() {
  local through= note= slugs tmp now last
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --through) [ "$#" -ge 2 ] && [[ $2 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || die 'dream --done --through needs an ISO UTC time such as 2026-11-16T09:00:00Z' 2; through=$2; shift 2;;
      --note) [ "$#" -ge 2 ] || die 'dream --done --note needs text' 2; note=$(one_line "$2"); shift 2;;
      *) die 'dream [--check | --done [--through time] [--note text]]' 2;;
    esac
  done
  last=$(dream_state last)
  slugs=$(closed_since "$last" | awk -F'\t' -v t="$through" 't==""||$3<=t{print $1}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
  [ -n "$through" ] || through=$(closed_since "$last" | awk -F'\t' '$3>m{m=$3}END{print m}')
  [ -n "$through" ] || through=$last
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ ! -f "$MEM/.dream-log.md" ] || [ -f "$MEM/.dream-state" ] && [ ! "$MEM/.dream-log.md" -nt "$MEM/.dream-state" ]; then
    printf -- '- %s dream done (recorded by sdlc.sh, no report from the dreamer): slugs %s%s\n' "$now" "${slugs:-none}" "${note:+; $note}" >> "$MEM/.dream-log.md"
  fi
  tmp=$(mktemp "$MEM/.dream-state.XXXXXX") || die 'cannot write .dream-state'
  printf 'last: %s\nlast_epoch: %s\nslugs: %s\n' "$through" "$(date +%s)" "$slugs" > "$tmp"; mv "$tmp" "$MEM/.dream-state"
  printf 'Dream recorded through %s: %s.\n' "${through:-the start}" "${slugs:-no slugs}"
}
# After close moved the slug to $1. Its lock moved with it, so a run waiting on the lock saw the feature
# gone; remove it here. Then warn on size and refresh the memory index.
archived() {
  local size warnmb
  F=$1; LOCK=$F/.state.lock; rm -rf "$LOCK"
  size=$(kb "$F"); warnmb=$(setting archive_warn_mb 50)
  [ "$size" -le $((warnmb*1024)) ] || err "archived $slug is still $((size/1024)) MB (archive_warn_mb $warnmb): move large logs out or add their cache folders to config.md prune:"
  memdir; [ ! -d "$MEM" ] || ( memory_index ) || err 'memory index not refreshed: run sdlc.sh memory index'
}
store_command() {
  case "$1" in
    memory) [ "$#" -eq 2 ] && [ "$2" = index ] || die 'memory index' 2; memory_index;;
    dream) [ "$#" -eq 1 ] || { [ "$#" -eq 2 ] && [ "$2" = --check ]; } || [ "$2" = --done ] || die 'dream [--check | --done [--through time] [--note text]]' 2; shift; dream "$@";;
  esac
}
