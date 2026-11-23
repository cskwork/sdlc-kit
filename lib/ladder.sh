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
# by the git toplevel of the repository shipped, as close matches Shipped lines, so Commit lines for two
# folders of one repository share it. That line is the one place a stage is recorded; the event log keeps
# the command and the output that checked it. close shipped then needs the last stage, or --at a recorded
# one with a reason.

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
# The first and last event times of feature folder $1, tab-separated (empty when it has no events.log).
event_span() { [ -f "$1/events.log" ] && awk -F'\t' 'NR==1{f=$1} {l=$1} END{printf "%s\t%s", f, l}' "$1/events.log" || :; }
# Seconds since 1970 of an ISO UTC time (awk: no mktime in every awk). Shared by status and stats.
EPOCH='function epoch(t,  y,m,d,era,yoe,doy,doe){y=substr(t,1,4)+0;m=substr(t,6,2)+0;d=substr(t,9,2)+0;if(m<=2)y--;era=int((y>=0?y:y-399)/400);yoe=y-era*400;doy=int((153*(m+(m>2?-3:9))+2)/5)+d-1;doe=yoe*365+int(yoe/4)-int(yoe/100)+doy;return (era*146097+doe-719468)*86400+substr(t,12,2)*3600+substr(t,15,2)*60+substr(t,18,2)}
'
# The creation time of folder $1 in seconds, empty when the file system does not keep one.
born() { local b; b=$(stat -c %W "$1" 2>/dev/null) || b=$(stat -f %B "$1" 2>/dev/null) || b=; case "$b" in ''|0|-*|*[!0-9]*) :;; *) printf '%s' "$b";; esac; }
# What stage records bind: the scored evidence and the build entry it routed.
stage_bind() { printf '%s:%s' "$rid" "$entry"; }
# The status --json fields after review_fails: age, last event, and the stage ladder. The age runs from the
# earlier of the folder's creation and the first event, so a slug made by an older kit keeps its age.
status_extra() {
  local first last start= b now bind
  IFS=$'\t' read -r first last < <(event_span "$F"; printf '\n')
  now=$(date +%s); b=$(born "$F")
  [ -z "$first" ] || start=$(awk -v t="$first" "$EPOCH"'BEGIN{print epoch(t)}')
  if [ -n "$b" ] && { [ -z "$start" ] || [ "$b" -lt "$start" ]; }; then start=$b; fi
  printf ',"ageDays":%s,"lastEventAt":' "$( [ -n "$start" ] && printf '%s' $(( (now - start) / 86400 )) || printf null )"
  if [ -n "$last" ]; then json "$last"; else printf null; fi
  stage_now; printf ',"stage":'; if [ -n "$stagename" ]; then json "$stagename"; else printf null; fi
  printf ',"stages":['
  local sep= name ssha sts sbind stop srepo; bind=$(stage_bind)
  while IFS=$'\t' read -r name ssha sts sbind stop srepo; do
    [ -n "$name" ] || continue
    printf '%s{"stage":' "$sep"; json "$name"; printf ',"sha":'; json "$ssha"; printf ',"repo":'; json "$srepo"; printf ',"ts":'; json "$sts"
    printf ',"current":%s}' "$( [ "$sbind" = "$bind" ] && printf true || printf false )"; sep=,
  done < <(printf '%s' "$stagerecs")
  printf ']'
}
# config.md stages: into stagelist (the words, for messages) and the array stages, read without globbing.
# A name outside letters, digits, ".", "_" and "-", or a name listed twice, is refused.
stage_list() {
  local s seen=' '
  stagelist=$(value "$STORE/config.md" stages | tr ',' ' ' | awk '{$1=$1;print}')
  stages=(); read -r -a stages < <(printf '%s\n' "$stagelist")
  for s in ${stages[@]+"${stages[@]}"}; do
    [[ $s =~ ^[A-Za-z0-9._-]+$ ]] || die "config.md stages: '$s' is not a stage name (letters, digits, '.', '_' and '-')"
    case "$seen" in *" $s "*) die "config.md stages: names $s twice: $stagelist";; esac; seen="$seen$s "
  done
}
# The position (1-based) of stage $1 in stages, 0 when it is not listed.
stage_pos() { local i; for ((i=0;i<${#stages[@]};i++)); do [ "${stages[i]}" != "$1" ] || { printf '%s' "$((i+1))"; return; }; done; printf 0; }
# True when a stage $1 record for repository toplevel $2 is bound to the current evidence and entry.
has_stage() { printf '%s' "$stagerecs" | awk -F'\t' -v s="$1" -v b="$(stage_bind)" -v t="$2" '$1==s&&$4==b&&$5==t{f=1} END{exit !f}'; }
# The distinct git toplevels of the evidence Commit lines into tops, and the first Commit path of each into
# topnames. With $1 = strict, a path that is not in a repository stops; otherwise (status) it keys as itself.
commit_tops() {
  local i t seen=$'\n'; tops=(); topnames=()
  for ((i=0;i<${#repos[@]};i++)); do
    repo_path "${repos[i]}"
    t=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || { [ "${1:-}" != strict ] || die "not a git repository: ${repos[i]}"; t=$REPO; }
    case "$seen" in *$'\n'"$t"$'\n'*) continue;; esac; seen="$seen$t"$'\n'
    tops[${#tops[@]}]=$t; topnames[${#topnames[@]}]=${repos[i]}
  done
}
# The latest stage recorded for the current evidence into stagename, and " · at <stage> (n/N)" into
# stagenote for the status line and next; both empty when no stage is recorded for it.
stage_now() {
  local n
  stagename=$(printf '%s' "$stagerecs" | awk -F'\t' -v b="$(stage_bind)" '$4==b{s=$1} END{print s}'); stagenote=
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
# ship <slug> <stage> <sha> [repo] --checked <command> --output <line>: records one stage of the ladder.
ship_command() {
  local susage='ship <slug> <stage> <sha> [repo] --checked "<command>" --output "<deciding line>"' args=() schecked= soutput= stage ssha srepo pos i ci= stop full s
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
  stop=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || die "not a git repository: $srepo"
  for ((i=0;i<${#commits[@]};i++)); do
    repo_path "${repos[i]}"; [ "$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" != "$stop" ] || { ci=$i; break; }
  done
  [ -n "$ci" ] || die "no Commit line for repo '$srepo' in evidence.md: ship a repository QA verified"
  repo_path "${repos[ci]}"; ship_tree_check "$REPO" "${commits[ci]}" "$ssha" "$target"
  # A later stage needs every earlier one recorded for this evidence first; a stage is recorded once per repository.
  ! has_stage "$stage" "$stop" || die "$stage is already recorded for this evidence in ${repos[ci]}: ship the next stage, or score new evidence to start the ladder again"
  for s in "${stages[@]}"; do [ "$s" != "$stage" ] || break; has_stage "$s" "$stop" || die "out of order: ship $s before $stage (config.md stages: $stagelist)"; done
  full=$(git -C "$REPO" rev-parse --verify -q "$ssha^{commit}")
  event; stagerecs="${stagerecs}$stage"$'\t'"$full"$'\t'"$ts"$'\t'"$(stage_bind)"$'\t'"$stop"$'\t'"${repos[ci]}"$'\n'; save_state
  log_event ship "$stage" "$full ${repos[ci]} · checked: $schecked · output: $soutput"
  printf 'Recorded %s at %s (%s/%s) for %s.\n' "$slug" "$stage" "$pos" "${#stages[@]}" "${repos[ci]}"
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
