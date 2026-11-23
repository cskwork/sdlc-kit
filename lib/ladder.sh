# The event log, stats, and the stage ladder for sdlc.sh, sourced by it (not run alone). Uses sdlc.sh's
# helpers and globals.
#
# Every command that changes .state appends one line to $F/events.log, which moves with the folder into
# archive/: ISO UTC time, command, the phase after it, result, one-line detail, tab-separated. The file
# is only ever appended to, and only best-effort: a failed append warns and never undoes the change.
# stats reads it; status --json reads its first and last time.
#
# A store whose config.md has `stages: dev, stg, prd` ships in steps: sdlc.sh ship records each stage
# reached as a `stage:` line in .state, bound to the scored evidence and the build entry it routed
# (<evidence id>:<entry>), so a new score or a re-approved plan starts the ladder again. A record is keyed
# by the repository's identity: its git common dir, the same for every worktree and the main checkout, so
# Commit lines for two folders of one repository share it, and a stage shipped from the main checkout
# counts for a Commit made in a since-removed worktree. score stores each Commit line's identity in .state
# (`repo:` lines) for that. A stage sha matches when its tree equals the Commit's (exact) or it contains the
# Commit (contains: a merge that promoted it). That line is the one place a stage is recorded; the event log
# keeps the command and the output that checked it. close shipped then needs the last stage, or --at a
# recorded one with a reason.

# Appends the event for the change just saved. ts is event()'s time when it ran (load_state clears it), else
# now: new has no seq.
log_event() {
  local after detail
  [ -n "$ts" ] || ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # The phase after the change, derived from the saved state in a subshell so no global moves.
  after=$( load_state; derive; printf '%s' "$phase" ) || after=unknown
  detail=$(one_line "${3:-}" | tr '\t' ' '); [ -n "$detail" ] || detail=-
  # stderr first, so a failed redirection's own message is dropped for the warning. Not `if !`: bash 3.2
  # reports a failed redirection on a group under `!` as success.
  { printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$1" "$after" "$2" "$detail"; } 2>/dev/null >> "$F/events.log" ||
    err "events.log not written: $F/events.log (the $1 itself is recorded in .state)"
}
# Seconds since 1970 of an ISO UTC time (awk: no mktime in every awk). Shared by status and stats.
EPOCH='function epoch(t,  y,m,d,era,yoe,doy,doe){y=substr(t,1,4)+0;m=substr(t,6,2)+0;d=substr(t,9,2)+0;if(m<=2)y--;era=int((y>=0?y:y-399)/400);yoe=y-era*400;doy=int((153*(m+(m>2?-3:9))+2)/5)+d-1;doe=yoe*365+int(yoe/4)-int(yoe/100)+doy;return (era*146097+doe-719468)*86400+substr(t,12,2)*3600+substr(t,15,2)*60+substr(t,18,2)}
'
# The creation time of folder $1 in seconds into btime, empty when the file system does not keep one. Which
# stat form works (GNU -c %W, BSD -f %B) is learned on the first call, so later calls fork once.
born() {
  btime=
  case "${statform:-}" in
    gnu) btime=$(stat -c %W "$1" 2>/dev/null) || btime=;;
    bsd) btime=$(stat -f %B "$1" 2>/dev/null) || btime=;;
    *) if btime=$(stat -c %W "$1" 2>/dev/null); then statform=gnu; elif btime=$(stat -f %B "$1" 2>/dev/null); then statform=bsd; else btime=; fi;;
  esac
  case "$btime" in ''|0|-*|*[!0-9]*) btime=;; esac
}
# The status --json fields after review_fails: age, last event, and the stage ladder. The age runs from the
# earlier of the folder's creation and the first event, so a slug made by an older kit keeps its age. status
# runs this per feature, so it forks at most twice (one awk over events.log, one stat) and uses the run's
# NOW; with no stages recorded it forks nothing more. Stage records bind <evidence id>:<entry>.
status_extra() {
  local first= last= start= fcmd= bind=$rid:$entry age=null sep= name ssha sts sbind sid smatch srepo current
  if [ -f "$F/events.log" ]; then
    IFS=$'\t' read -r first last start fcmd < <(awk -F'\t' "$EPOCH"'NR==1{f=$1;c=$2} {l=$1} END{if(NR)printf "%s\t%s\t%s\t%s\n", f, l, epoch(f), c}' "$F/events.log") || : # an empty log prints nothing
  fi
  # Only a slug whose log does not start with new can be older than its first event.
  if [ "$fcmd" != new ]; then born "$F"; if [ -n "$btime" ] && { [ -z "$start" ] || [ "$btime" -lt "$start" ]; }; then start=$btime; fi; fi
  [ -z "$start" ] || age=$(( (${NOW:-$(date +%s)} - start) / 86400 ))
  # An ISO time needs no escaping.
  printf ',"ageDays":%s,"lastEventAt":' "$age"; if [ -n "$last" ]; then printf '"%s"' "$last"; else printf null; fi
  if [ -z "$stagerecs" ]; then printf ',"stage":null,"stages":[]'; return; fi
  stage_now; printf ',"stage":'; if [ -n "$stagename" ]; then printf '"%s"' "$stagename"; else printf null; fi
  printf ',"stages":['
  while IFS=$'\t' read -r name ssha sts sbind sid smatch srepo; do
    [ -n "$name" ] || continue
    if [ "$sbind" = "$bind" ]; then current=true; else current=false; fi
    # Stage names, shas, match words and ISO times need no escaping; a repository path may.
    printf '%s{"stage":"%s","sha":"%s","repo":' "$sep" "$name" "$ssha"; json "$srepo"; printf ',"ts":"%s","match":"%s","current":%s}' "$sts" "$smatch" "$current"; sep=,
  done < <(printf '%s' "$stagerecs")
  printf ']'
}
# config.md stages: into stagelist (the names, for messages) and the array stages, read without globbing.
# Read raw (raw_setting keeps `, * and #, which value() would drop): items are separated by commas or
# spaces; an empty item between commas, a name outside letters, digits, ".", "_" and "-", or a name listed
# twice is refused.
stage_list() {
  local raw s seen=' '
  # config.md does not change during a run: read it once.
  [ -z "${stagesread:-}" ] || return 0; stagesread=1
  raw=$(raw_setting stages)
  if [ -n "${raw//[[:space:],]/}" ]; then case ",${raw//[[:space:]]/}," in *,,*) die "config.md stages: has an empty item: '$raw'";; esac; else raw=; fi
  stagelist=$(printf '%s' "$raw" | tr ',' ' ' | awk '{$1=$1;print}')
  stages=(); read -r -a stages < <(printf '%s\n' "$stagelist")
  for s in ${stages[@]+"${stages[@]}"}; do
    [[ $s =~ ^[A-Za-z0-9._-]+$ ]] || die "config.md stages: '$s' is not a stage name (letters, digits, '.', '_' and '-')"
    case "$seen" in *" $s "*) die "config.md stages: names $s twice: $stagelist";; esac; seen="$seen$s "
  done
}
# The position (1-based) of stage $1 in stages, 0 when it is not listed.
stage_pos() { local i; for ((i=0;i<${#stages[@]};i++)); do [ "${stages[i]}" != "$1" ] || { printf '%s' "$((i+1))"; return; }; done; printf 0; }
# True when a stage $1 record for repository identity $2 is bound to the current evidence and entry.
has_stage() { printf '%s' "$stagerecs" | awk -F'\t' -v s="$1" -v b="$rid:$entry" -v t="$2" '$1==s&&$4==b&&$5==t{f=1} END{exit !f}'; }
# The identity of the repository holding folder $1 (its git common dir, resolved, shared by every worktree
# of it) and the folder's path inside its checkout, tab-separated; fails when $1 is not in a repository.
repo_identity() {
  local common prefix
  common=$(cd "$1" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null) && prefix=$(git -C "$1" rev-parse --show-prefix 2>/dev/null) &&
    common=$(cd "$1" && cd "$common" && pwd -P) || return 1
  printf '%s\t%s' "$common" "$prefix"
}
# score's record of each Commit line: identity, path inside the checkout, Commit path; one line each.
repo_ids() {
  local i id
  for ((i=0;i<${#commits[@]};i++)); do
    repo_path "${repos[i]}"; id=$(repo_identity "$REPO") || die "not a git repository: ${repos[i]}"
    printf '%s\t%s\n' "$id" "${repos[i]}"
  done
}
# Commit line $1's repository into cid and its path inside the checkout into cprefix: the identity score
# stored, else (an older .state) the folder's own. A gone folder with nothing stored stops with $2 = strict,
# else (status) it keys as its path.
commit_identity() {
  local line
  line=$(printf '%s' "$repoids" | awk -F'\t' -v r="${repos[$1]}" '$3==r{print $1 "\t" $2; exit}')
  if [ -z "$line" ]; then repo_path "${repos[$1]}"; line=$(repo_identity "$REPO") || {
    [ "${2:-}" != strict ] || die "Commit path '${repos[$1]}' is not a repository folder under the project root, and this slug was scored before the kit stored repository identities: restore the folder, or score again"
    line=$REPO$'\t'; }; fi
  IFS=$'\t' read -r cid cprefix < <(printf '%s\n' "$line")
}
# The distinct repositories of the evidence Commit lines into tops, and the first Commit path of each into
# topnames ($1 as for commit_identity).
commit_tops() {
  local i seen=$'\n'; tops=(); topnames=()
  for ((i=0;i<${#repos[@]};i++)); do
    commit_identity "$i" "${1:-}"
    case "$seen" in *$'\n'"$cid"$'\n'*) continue;; esac; seen="$seen$cid"$'\n'
    tops[${#tops[@]}]=$cid; topnames[${#topnames[@]}]=${repos[i]}
  done
}
# close shipped: each Commit line needs a Shipped line for a folder of the same repository whose tree is the
# verified one (and, beyond local, on a remote). The check runs in the Commit folder, or in the Shipped
# line's folder once a worktree that held the Commit is gone: the main checkout shares its objects.
close_shipped() {
  local i j did dprefix matchsha mdir nodir cdir
  for ((i=0;i<${#commits[@]};i++)); do
    commit_identity "$i" strict; matchsha=; mdir=; nodir=
    for ((j=0;j<${#delivered[@]};j++)); do
      # A Shipped line for another repository (a deploy repository not checked out here, say) is skipped.
      repo_path "${drepos[j]}"
      IFS=$'\t' read -r did dprefix < <(repo_identity "$REPO"; printf '\n') || :
      [ -n "$did" ] || { [ -d "$REPO" ] || nodir=${drepos[j]}; continue; }
      [ "$did" != "$cid" ] || { matchsha=${delivered[j]}; mdir=$REPO; }
    done
    [ -n "$matchsha" ] || die "Shipped missing for repo: ${repos[i]}: add '- Shipped: <sha> ${repos[i]}'${nodir:+ (the line for '$nodir' was skipped: it is not a folder under the project root)}"
    repo_path "${repos[i]}"; cdir=$REPO; [ -d "$cdir" ] || cdir=$mdir
    ship_tree_check "$cdir" "${commits[i]}" "$matchsha" "$etarget"
  done
}
# The latest stage recorded for the current evidence into stagename, and " · at <stage> (n/N)" into
# stagenote for the status line and next; both empty when no stage is recorded for it.
stage_now() {
  local n
  stagenote=; stagename=; [ -n "$stagerecs" ] || return 0
  stagename=$(printf '%s' "$stagerecs" | awk -F'\t' -v b="$rid:$entry" '$4==b{s=$1} END{print s}'); stagenote=
  [ -n "$stagename" ] || return 0
  stage_list; n=$(stage_pos "$stagename"); [ "$n" != 0 ] || n='?'
  stagenote=" · at $stagename ($n/${#stages[@]})"
}
# derive's action on a deliver route with authority: with a ladder, the next stage to ship comes first.
deliver_action() {
  local s next= i
  stage_list
  if [ "${#stages[@]}" -eq 0 ]; then action="ship, fill Shipping, sdlc.sh close $slug shipped; before shipping: sdlc.sh check ship $slug"; return; fi
  # The first stage some Commit repository has not reached for this evidence.
  commit_tops
  for s in "${stages[@]}"; do for ((i=0;i<${#tops[@]};i++)); do has_stage "$s" "${tops[i]}" || { next=$s; break 2; }; done; done
  if [ -n "$next" ]; then action="ship to $next, then sdlc.sh ship $slug $next <sha> [repo] --checked <command> --output <line>; before shipping: sdlc.sh check ship $slug"
  else action="every stage shipped: fill Shipping, sdlc.sh close $slug shipped"; fi
}
# Shipped commit $3 in repository folder $1 holds the tree of verified Commit $2 and, for a target other
# than local ($4), is on a remote. Shared by close shipped and ship.
ship_tree_check() {
  git -C "$1" rev-parse --verify -q "$3^{commit}" >/dev/null || die "unknown Shipped commit: $3"
  git -C "$1" diff --quiet "$2" "$3" || die 'Shipped tree differs from verified Commit'
  if [ "$4" != local ]; then remote=$(git -C "$1" branch -r --contains "$3"); [ -n "$remote" ] || die 'Shipped commit is not on any remote'; fi
}
# For ship: stage commit $3 in folder $1 matches verified Commit $2 when its tree is the same (exact) or it
# contains the Commit (contains: a --no-ff merge that promoted it with other changes), into smatch; beyond
# local ($4) it must be on a remote.
ship_match() {
  git -C "$1" rev-parse --verify -q "$3^{commit}" >/dev/null || die "unknown stage commit: $3"
  if git -C "$1" diff --quiet "$2" "$3"; then smatch=exact
  elif git -C "$1" merge-base --is-ancestor "$2" "$3" 2>/dev/null; then smatch=contains
  else die "stage commit $3 neither has the verified tree of Commit $2 nor contains it"; fi
  if [ "$4" != local ]; then remote=$(git -C "$1" branch -r --contains "$3"); [ -n "$remote" ] || die 'Shipped commit is not on any remote'; fi
}
# ship <slug> <stage> <sha> [repo] --checked <command> --output <line>: records one stage of the ladder.
ship_command() {
  local susage='ship <slug> <stage> <sha> [repo] --checked "<command>" --output "<deciding line>"' args=() schecked= soutput= stage ssha srepo pos i ci= sdir sid sprefix cid cprefix match smatch full s
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --checked) [ "$#" -ge 2 ] && [ -z "$schecked" ] || die "$susage" 2; schecked=$(one_line "$2" | tr '\t' ' '); shift 2;;
      --output) [ "$#" -ge 2 ] && [ -z "$soutput" ] || die "$susage" 2; soutput=$(one_line "$2" | tr '\t' ' '); shift 2;;
      *) args[${#args[@]}]=$1; shift;;
    esac
  done
  { [ "${#args[@]}" -eq 3 ] || [ "${#args[@]}" -eq 4 ]; } && [ -n "$schecked" ] && [ -n "$soutput" ] || die "$susage" 2
  stage=${args[1]}; ssha=${args[2]}; srepo=${args[3]:-.}
  [[ $ssha =~ ^[0-9a-fA-F]{7,64}$ ]] || die "invalid sha: $ssha" 2
  feature "${args[0]}"; mutable; [ -f "$F/.state" ] || die 'legacy feature cannot ship'
  stage_list; [ "${#stages[@]}" -gt 0 ] || die 'no stages: in config.md: list the stages in order (stages: dev, stg, prd), or ship with sdlc.sh close shipped'
  pos=$(stage_pos "$stage"); [ "$pos" != 0 ] || die "unknown stage '$stage': config.md stages: $stagelist"
  gate_plan || die "$greason"
  read_intent; read_plan; read_evidence
  [ "$dest" = deliver ] && route_current || die 'current evidence and build need a deliver route'
  validate_evidence || exit 1
  delivery_authority "$target" || die "$dreason"
  repo_path "$srepo"; [ -d "$REPO" ] || die "repo '$srepo' is not a directory under the project root"
  sdir=$REPO; IFS=$'\t' read -r sid sprefix < <(repo_identity "$sdir"; printf '\n') || :; [ -n "$sid" ] || die "not a git repository: $srepo"
  # The folder is the one a Commit line names, in that checkout or another worktree or the main checkout of
  # the same repository (same path inside it); every Commit line of that repository must match the sha,
  # checked here in the given folder, which shares the repository's objects.
  for ((i=0;i<${#commits[@]};i++)); do commit_identity "$i"; [ "$cid" != "$sid" ] || [ "$cprefix" != "$sprefix" ] || { ci=$i; break; }; done
  [ -n "$ci" ] || die "no Commit line for repo '$srepo' in evidence.md: ship a repository QA verified"
  match=exact
  for ((i=0;i<${#commits[@]};i++)); do commit_identity "$i"; [ "$cid" = "$sid" ] || continue; ship_match "$sdir" "${commits[i]}" "$ssha" "$target"; [ "$smatch" = exact ] || match=contains; done
  # A later stage needs every earlier one recorded for this evidence first; a stage is recorded once per repository.
  ! has_stage "$stage" "$sid" || die "$stage is already recorded for this evidence in $srepo: ship the next stage, or score new evidence to start the ladder again"
  for s in "${stages[@]}"; do [ "$s" != "$stage" ] || break; has_stage "$s" "$sid" || die "out of order: ship $s before $stage (config.md stages: $stagelist)"; done
  full=$(git -C "$sdir" rev-parse --verify -q "$ssha^{commit}")
  event; stagerecs="${stagerecs}$stage"$'\t'"$full"$'\t'"$ts"$'\t'"$rid:$entry"$'\t'"$sid"$'\t'"$match"$'\t'"$srepo"$'\n'; save_state
  log_event ship "$stage" "$full $srepo ($match) · checked: $schecked · output: $soutput"
  printf 'Recorded %s at %s (%s/%s) for %s (%s).\n' "$slug" "$stage" "$pos" "${#stages[@]}" "$srepo" "$match"
}
# close shipped with a ladder: every Commit repository reached the last stage, or --at's recorded one.
# Without stages: nothing more, and --at is refused.
stage_close() {
  local want i
  stage_list
  if [ "${#stages[@]}" -eq 0 ]; then [ -z "$closeat" ] || die 'close --at needs stages: in config.md'; return 0; fi
  want=${stages[${#stages[@]}-1]}
  if [ -n "$closeat" ]; then [ "$(stage_pos "$closeat")" != 0 ] || die "unknown stage '$closeat': config.md stages: $stagelist"; want=$closeat; fi
  commit_tops strict
  for ((i=0;i<${#tops[@]};i++)); do
    has_stage "$want" "${tops[i]}" || die "stage $want not recorded for ${topnames[i]}: sdlc.sh ship $slug $want <sha> ${topnames[i]} --checked <command> --output <line>$( [ -n "$closeat" ] || printf ', or close --at <recorded stage> "<reason>" when the last one is out of reach')"
  done
  [ -z "$closeat" ] || note="$note (closed at $closeat of $stagelist)"
}
# stats [--json] [--since YYYY-MM-DD]: counts, phase times, score rounds, returns, BLOCKED reasons and
# closes per week over open and archived slugs. A slug without events.log counts as legacy, and one whose
# events.log does not start with new (it was in flight when the kit began logging) as partial: neither has
# phase timings.
stats_command() {
  local asjson=0 since= path name kind evented closedts first
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) [ "$asjson" -eq 0 ] || die 'duplicate --json' 2; asjson=1; shift;;
      --since) [ "$#" -ge 2 ] && [[ $2 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [ -z "$since" ] || die 'stats [--json] [--since YYYY-MM-DD]' 2; since=$2; shift 2;;
      *) die 'stats [--json] [--since YYYY-MM-DD]' 2;;
    esac
  done
  # One record stream, \t-separated, typed by its first field, for one awk: F feature, E event, B blocked row.
  { for path in "$STORE"/work/* "$STORE"/archive/*; do
      [ -d "$path" ] || continue; name=$(basename "$path"); is_slug "$name" || continue
      case "$path" in "$STORE"/work/*) kind=open;; *) kind=archived;; esac
      # A name in both folders is read where feature() finds it: work.
      [ "$kind" = open ] || [ ! -d "$STORE/work/$name" ] || continue
      feature "$name"; derive; evented=0
      if [ -f "$F/events.log" ]; then first=$(awk -F'\t' 'NR==1{print $2;exit}' "$F/events.log"); if [ "$first" = new ]; then evented=1; else evented=2; fi; fi
      closedts=-; [ -z "$closed" ] || closedts=$(printf '%s' "$closed" | awk '{print $1 "\t" $2}')
      [ "$closedts" != - ] || closedts=$'-\t-'
      printf 'F\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$kind" "$phase" "$STATE" "$rp" "$rb" "$evented" "$closedts"
      [ "$evented" -eq 0 ] || [ ! -f "$F/events.log" ] || awk -v s="$name" 'NF{print "E\t" s "\t" $0}' "$F/events.log"
      [ ! -f "$F/evidence.md" ] || parse evidence "$F/evidence.md" | awk -F'\034' -v s="$name" '$1=="B"{o=$3;gsub(/\t/," ",o);print "B\t" s "\t" o}'
    done; } | awk -F'\t' -v since="$since" -v asjson="$asjson" -v store="$STORE" "$EPOCH"'
  BEGIN{for(j=1;j<32;j++)ctl[sprintf("%c",j)]=j}
  function civil(z,  era,doe,yoe,y,doy,mp,d,m){z+=719468;era=int((z>=0?z:z-146096)/146097);doe=z-era*146097;yoe=int((doe-int(doe/1460)+int(doe/36524)-int(doe/146096))/365);y=yoe+era*400;doy=doe-(365*yoe+int(yoe/4)-int(yoe/100));mp=int((5*doy+2)/153);d=doy-int((153*mp+2)/5)+1;m=mp+(mp<10?3:-9);if(m<=2)y++;return sprintf("%04d-%02d-%02d",y,m,d)}
  function dur(s){if(s>=86400)return sprintf("%.1fd",s/86400);if(s>=3600)return sprintf("%.1fh",s/3600);return sprintf("%dm",int(s/60))}
  function sortn(arr,n,  i,j,t){for(i=2;i<=n;i++){t=arr[i];for(j=i-1;j>=1&&arr[j]>t;j--)arr[j+1]=arr[j];arr[j+1]=t}}
  function rank(arr,n,p){return arr[(n*p==int(n*p))?(n*p<1?1:n*p):int(n*p)+1]}
  function q(s,  i,c,o){o="";for(i=1;i<=length(s);i++){c=substr(s,i,1);if(c=="\\"||c=="\"")o=o "\\" c;else if(c in ctl)o=o sprintf("\\u%04x",ctl[c]);else o=o c}return "\"" o "\""}
  $1=="F"{if($3=="archived"&&since!=""&&($9=="-"||substr($10,1,10)<since))next
    inc[$2]=1;slugs++;if($3=="open")open++;else archived++;if(!$8)legacy++;if($8==2){partial++;part[$2]=1};k=$4 "\t" $5;if(!(k in cnt))ck[++nck]=k;cnt[k]++
    retp+=$6;retb+=$7;if($6+$7>0)retslugs++
    if($9!="-"&&(since==""||substr($10,1,10)>=since)){w=civil(int(epoch($10)/86400)-(int(epoch($10)/86400)+3)%7);if(!(w in wk))wn[++nw]=w;wk[w]++;if($9=="shipped")ship[w]++;else drop[w]++}
    next}
  $1=="E"{if(!($2 in inc))next;t=epoch($3)
    if(!($2 in part)&&($2 in lastt)&&(since==""||substr(lastts[$2],1,10)>=since)){p=lastp[$2];if(!(p in seenp))pn[++np]=p;seenp[p]=1;if(!(($2,p) in per)){cntp[p]++;slp[p,cntp[p]]=$2};per[$2,p]+=t-lastt[$2]}
    lastt[$2]=t;lastts[$2]=$3;lastp[$2]=$5
    if($4=="score"&&(since==""||substr($3,1,10)>=since)){rounds++;r[$2]++}
    next}
  $1=="B"{if(!($2 in inc))next;o=$3;if(o=="")o="(no Observed)";if(!(o in bc))bn[++nb]=o;bc[o]++;next}
  END{
    order="intent plan build evidence deliver";no=split(order,ord," ");for(i=1;i<=np;i++)if(index(" " order " "," " pn[i] " ")==0)ord[++no]=pn[i]
    for(i=1;i<=no;i++){p=ord[i];if(!(p in seenp))continue;n=cntp[p];for(j=1;j<=n;j++)v[j]=per[slp[p,j],p];sortn(v,n);med[p]=rank(v,n,0.5);p90[p]=rank(v,n,0.9);tn[p]=n}
    rs=0;for(s in r){rs++;rv[rs]=r[s]};sortn(rv,rs);rmax=rs?rv[rs]:0;rmed=rs?rank(rv,rs,0.5):0
    for(i=1;i<=nb;i++)for(j=i+1;j<=nb;j++)if(bc[bn[j]]>bc[bn[i]]||(bc[bn[j]]==bc[bn[i]]&&bn[j]<bn[i])){t=bn[i];bn[i]=bn[j];bn[j]=t}
    for(i=1;i<=nw;i++)for(j=i+1;j<=nw;j++)if(wn[j]<wn[i]){t=wn[i];wn[i]=wn[j];wn[j]=t}
    top=nb<5?nb:5
    if(asjson){
      printf "{\"store\":%s,\"since\":%s,\"slugs\":{\"total\":%d,\"open\":%d,\"archived\":%d,\"legacy\":%d,\"partial\":%d}", q(store), (since==""?"null":q(since)), slugs, open, archived, legacy, partial
      printf ",\"counts\":[";for(i=1;i<=nck;i++){split(ck[i],kk,"\t");printf "%s{\"phase\":%s,\"state\":%s,\"n\":%d}",(i>1?",":""),q(kk[1]),q(kk[2]),cnt[ck[i]]}
      printf "],\"phaseTimes\":[";c=0;for(i=1;i<=no;i++){p=ord[i];if(!(p in tn))continue;printf "%s{\"phase\":%s,\"slugs\":%d,\"medianSeconds\":%d,\"p90Seconds\":%d}",(c++?",":""),q(p),tn[p],med[p],p90[p]}
      printf "],\"scoreRounds\":{\"total\":%d,\"slugs\":%d,\"median\":%d,\"max\":%d}", rounds, rs, rmed, rmax
      printf ",\"returns\":{\"plan\":%d,\"build\":%d,\"slugs\":%d}", retp, retb, retslugs
      printf ",\"blocked\":[";for(i=1;i<=top;i++)printf "%s{\"reason\":%s,\"n\":%d}",(i>1?",":""),q(bn[i]),bc[bn[i]]
      printf "],\"closesPerWeek\":[";for(i=1;i<=nw;i++)printf "%s{\"week\":%s,\"shipped\":%d,\"dropped\":%d}",(i>1?",":""),q(wn[i]),ship[wn[i]],drop[wn[i]]
      printf "]}\n";exit}
    printf "Store: %s%s\nSlugs: %d (open %d, archived %d); left out of timings: legacy (no events.log) %d, partial (logging began mid-flight) %d\n", store, (since==""?"":" · since " since), slugs, open, archived, legacy, partial
    print "By phase and state:";for(i=1;i<=nck;i++){split(ck[i],kk,"\t");printf "  %s %s: %d\n",kk[1],kk[2],cnt[ck[i]]}
    print "Time per phase (median · p90 over slugs):";c=0;for(i=1;i<=no;i++){p=ord[i];if(!(p in tn))continue;c++;printf "  %s: %s · %s (%d slugs)\n",p,dur(med[p]),dur(p90[p]),tn[p]}
    if(!c)print "  none recorded"
    printf "Score rounds: %d over %d slugs (median %d, max %d)\nReturns: %d to plan, %d to build (%d slugs)\n", rounds, rs, rmed, rmax, retp, retb, retslugs
    print "BLOCKED reasons" (top?" (top " top ")":"") ":";for(i=1;i<=top;i++)printf "  %d× %s\n",bc[bn[i]],bn[i];if(!top)print "  none"
    print "Closes per week (Monday):";for(i=1;i<=nw;i++)printf "  %s: %d shipped, %d dropped\n",wn[i],ship[wn[i]],drop[wn[i]];if(!nw)print "  none"
  }'
}
