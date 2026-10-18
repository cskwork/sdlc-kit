#!/usr/bin/env bash
set -e
set -o pipefail
KIT=$(cd "$(dirname "$0")" && pwd)
err() { printf 'sdlc: %s\n' "$*" >&2; }
die() { err "$1"; exit "${2:-1}"; }
usage() {
  cat <<'USAGE'
Usage: sdlc.sh init [--knowledge path] | new slug | status [slug] [--json]
       sdlc.sh next slug | check intent|plan slug
       sdlc.sh approve intent|plan slug --human words|--agent review
       sdlc.sh review slug pass|fail [--uncommitted] [--repos "path ..."] note
       sdlc.sh score slug
       sdlc.sh close slug shipped|dropped reason | help | --version
USAGE
}
sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 | awk '{print $NF}'
  else die 'no sha256 tool available'; fi
}
one_line() { printf '%s' "$1" | tr '\r\n' '  ' | awk '{$1=$1;print}'; }
is_slug() { [[ ${#1} -le 80 && $1 =~ ^[a-z0-9][a-z0-9._-]*$ ]]; }
valid_slug() { is_slug "$1" || die 'invalid slug: lowercase letters, digits, ".", "_" and "-", starting with a letter or digit, up to 80 characters' 2; }
joined() { printf '%s' "$1" | awk 'NF{printf "%s%s", (n++ ? "; " : ""), $0} END{print ""}'; }
# Shared by every markdown reader: drops CR and each <!-- --> span, keeping the text around it.
# True when nothing but a comment was on the line, so the caller skips it.
UNCOMMENT='function uncomment(  s,out,i,touched){gsub(/\r/,"");s=$0;out="";touched=comment
  while(s!=""){if(comment){i=index(s,"-->");if(!i)break;s=substr(s,i+3);comment=0}
    else{i=index(s,"<!--");if(!i){out=out s;break}touched=1;out=out substr(s,1,i-1);s=substr(s,i+4);comment=1}}
  $0=out;return touched&&out!~/[^ \t]/}
'
value() {
  awk -v key="$2" -v presence="${3:-0}" "$UNCOMMENT"'
  {if(uncomment())next
   gsub(/[`*]/,"");if(tolower($0) ~ "^[ \t]*" key "[ \t]*:"){
     sub(/^[^:]*:[ \t]*/,"");sub(/(^|[ \t])#.*/,"");sub(/[ \t]+$/,"");if(presence)print "present";else print;exit}}
  ' "$1"
}
config() {
  gates=$(value "$STORE/config.md" human_gates)
  if [ -z "$(value "$STORE/config.md" human_gates 1)" ]; then
    lazy=$(value "$STORE/config.md" lazymode)
    case "$lazy" in 0|1) gates='intent plan';; 2|3) gates=intent;; 4) gates=;; '') if [ -n "$(value "$STORE/config.md" lazymode 1)" ]; then gates='intent plan'; else gates=intent; fi;; *) gates='intent plan';; esac
  fi
  # An unknown word fails closed, as an unknown lazymode does.
  gates=$(printf '%s' "$gates" | awk '{gsub(/,/," ");for(i=1;i<=NF;i++){v=tolower($i);if(v!="intent"&&v!="plan"){bad=$i;break}if(!seen[v]++)out=out (out==""?"":" ") v}}END{if(bad!="")print "!" bad;else print out}')
  case "$gates" in '!'*) err "unknown human_gates value '${gates#!}' (write intent, plan, or leave it empty): the human approves intent and plan"; gates='intent plan';; esac
  knowledge=$(value "$STORE/config.md" knowledge)
  bound=$(value "$STORE/config.md" repos); boundby='config repos:'
  if [ -z "$knowledge" ]; then
    if [ -d "$STORE/memory" ]; then knowledge=.sdlc/memory; else knowledge=.sdlc/knowledge; fi
  fi
}
human_gate() { case " $gates " in *" $1 "*) return 0;; *) return 1;; esac; }
find_store() {
  ROOT=$PWD
  while [ ! -f "$ROOT/.sdlc/config.md" ]; do
    # dirname of a root returns the root itself ('/', and '//' for a Git Bash UNC path).
    parent=$(dirname "$ROOT"); [ "$parent" != "$ROOT" ] || die 'no .sdlc/config.md found' 2
    ROOT=$parent
  done
  STORE=$ROOT/.sdlc
  config
}
feature() {
  slug=$1; valid_slug "$slug"; F=$STORE/work/$slug
  [ -d "$F" ] || F=$STORE/archive/$slug
  [ -d "$F" ] || die "feature not found: $slug" 2
  load_state
}
load_state() {
  seq=0; entry=0; fails=0; rp=0; rb=0; lastfail=; intent=; plan=; review=; route=; score=; closed=; planned=; scored=; rounds=0; withdrawn=; heads=; planbody=
  if [ -f "$F/.state" ]; then
    while IFS= read -r line; do
      key=${line%%:*}; val=${line#*:}; val=${val# }
      case "$key" in seq) seq=$val;; entry) entry=$val;; fails) fails=$val;; returns_plan) rp=$val;; returns_build) rb=$val;; lastfail) lastfail=$val;; intent) intent=$val;; plan) plan=$val;; review) review=$val;; route) route=$val;; score) score=$val;; closed) closed=$val;; planned) planned=$val;; scored) scored=$val;; rounds) rounds=$val;; withdrawn) withdrawn=$val;; heads) heads=$val;; planbody) planbody=$val;; esac
    done < "$F/.state"
  fi
  read -r ish iwho iseq its inote <<< "$intent"
  read -r psh pish pwho pseq pts pnote <<< "$plan"
  read -r verdict ventry vseq vsha vnote <<< "$review"
  read -r dest rid rentry rseq reason <<< "$route"
}
save_state() {
  tmp=$(mktemp "$F/.state.XXXXXX") || die 'cannot create state file'
  {
    printf 'seq: %s\nentry: %s\nfails: %s\nreturns_plan: %s\nreturns_build: %s\nlastfail: %s\n' "$seq" "$entry" "$fails" "$rp" "$rb" "$lastfail"
    printf 'planned: %s\nscored: %s\nrounds: %s\nwithdrawn: %s\n' "$planned" "$scored" "$rounds" "$withdrawn"
    for key in intent plan planbody review route score closed heads; do eval 'val=$'"$key"; [ -z "$val" ] || printf '%s: %s\n' "$key" "$val"; done
  } > "$tmp"
  mv "$tmp" "$F/.state"
}
mutable() { [ -z "$closed" ] && [ "$F" = "$STORE/work/$slug" ] || die 'feature is archived or closed'; }
event() { seq=$((seq+1)); ts=$(date -u +%Y-%m-%dT%H:%M:%SZ); }
parse() {
  [ -f "$2" ] || { printf 'X\034%s missing\n' "$(basename "$2")"; return; }
  awk -v mode="$1" -v objectives="$objectives" -v scenarios="$scenarios" -v scored="$scored" -v withdrawn="$withdrawn" "$UNCOMMENT"'
  function trim(s){sub(/^[ \t]+/,"",s);sub(/[ \t]+$/,"",s);return s}function problem(s){print "X\034" s}
  function area(id,  k,s){k=tolower(id);gsub(/[^a-z]/,"",k);s=tolower(a[3]);if(k=="area")return;ca++;if(k!~/^(outcome|scope|asis|tobe|success|constraints)$/){print "Y\034Clarity: unknown area " id;cy++;return}if(k in cs){print "Y\034Clarity: duplicate area " id;cy++;return}cs[k]="open";if(s!~/^(clear|assumed|open)$/){print "Y\034Clarity " id ": State must be clear, assumed or open";cy++}else if(tolower(a[4])~/^(<.*>|[-—–?.]*|n\/a|tbd)$/){print "Y\034Clarity " id ": How settled needs its evidence or reason";cy++}else cs[k]=s}
  function question(){if(q!=""){l=tolower(trim(q));if(l!="none"&&l!="n/a"&&l!~/^resolved:/&&l!~/— resolved:/&&l!~/-- resolved:/)print "Q\034" q;q=""}}
  function fields(s, c,j){for(j in a)delete a[j];nfields=1;for(j=1;j<=length(s);j++){c=substr(s,j,1);if(c=="\\"&&substr(s,j+1,1)=="|"){a[nfields]=a[nfields] "|";j++}else if(c=="|")nfields++;else a[nfields]=a[nfields] c}for(j=1;j<=nfields;j++)a[j]=trim(a[j]);cells=nfields-1-(a[nfields]=="");return a[2]}
  {
    if(uncomment())next
    sub(/^[ \t]*\*[ \t]+/,"- ");gsub(/[`*]/,"");raw=$0;line=trim(raw);low=tolower(line)
    if(mode=="plan"&&low~/<three lines for the human|<file or symbol>|<another reader or writer|<…>/)problem("PLAN.md contains template placeholder")
    if(low~/^## /){question();section=substr(low,4);header=0;next}
    if(mode=="intent"){if(section~/^clarity/&&line~/^\|/&&line!~/^[| :\t-]+$/)area(fields(line))
      if(section~/^understood as/&&line~/^- O[0-9]+[ \t]*:/){id=line;sub(/^[^-]*- /,"",id);sub(/[ \t]*:.*/,"",id);text=line;sub(/^[^:]*:[ \t]*/,"",text);if(text!=""&&text!~/^</){print "O\034" id;outcomes++}}
      if(section~/^blocking questions/){if(line~/^(-|[0-9]+\.)[ \t]/){question();q=line;sub(/^(-|[0-9]+\.)[ \t]+/,"",q)}else if(raw~/^[ \t]+/&&q!="")q=q " " line}
    }
    if(section~/^delivery/){v=line;sub(/^- /,"",v);if(tolower(v)~/^(target|authorized|checked with|output):/){key=v;sub(/:.*/,"",key);sub(/^[^:]*:[ \t]*/,"",v);key=tolower(key);if(key=="target"){rawtarget=v;target=tolower(v);print "T\034" target}if(key=="authorized")print "A\034" v;if(key=="checked with")print "K\034" v;if(key=="output")print "U\034" v}}
    if(mode=="plan"&&low~/risk flags:/){flags++;v=line;sub(/^.*[Rr][Ii][Ss][Kk] [Ff][Ll][Aa][Gg][Ss]:[ \t]*/,"",v);n=split(v,segments,"·");for(i=1;i<=n;i++)if(tolower(segments[i])~/(^|[^a-z0-9_])yes([^a-z0-9_]|$)/)print "R\034" trim(segments[i])}
    if(mode=="evidence"&&(low~/^- commit:/||(section~/^delivery/&&low~/^- delivered:/))){kind=low~/^- commit:/?"C":"D";v=line;sub(/^[^:]*:[ \t]*/,"",v);hash=v;sub(/[ \t].*/,"",hash);repo=v;sub(/^[^ \t]+[ \t]*/,"",repo);if(repo==v||repo=="")repo=".";if(hash!~/^[a-fA-F0-9]+$/||length(hash)<7||length(hash)>64){if(kind=="C")problem("invalid Commit: " hash)}else{print kind "\034" tolower(hash) "\034" repo;if(kind=="C")commits++}}
    if(line!~/^\|/)next
    id=fields(line);if(tolower(id)=="id"){header=cells;next}if(line~/^[| :\t-]+$/)next
    if(header&&cells>header&&((mode=="plan"&&section~/^scenarios/)||(mode=="evidence"&&section~/^results/))){x=0;for(j=header+2;j<=cells+1;j++)if(a[j]!="")x=1;if(x)problem(id ": row has " cells " cells, header has " header)}
    if(mode=="plan"&&section~/^scenarios/){
      count++;if(id!~/^S[0-9]+$/)problem("invalid scenario ID: " id);if(seen[id]++)problem("duplicate scenario: " id)
      must=tolower(a[6]);if(must=="yes"||must=="y"||must=="true"||must=="must")must=1;else if(must=="no"||must=="n"||must=="false"||must=="")must=0;else{problem("invalid Must: " a[6]);must=0}
      if(low~/<who>|<steps through|<observable/)problem("unfilled scenario: " id)
      print "S\034" id "\034" must;v=a[7];gsub(/[^A-Za-z0-9_]/," ",v);n=split(v,tokens," ");for(i=1;i<=n;i++)if(tokens[i]~/^O[0-9]+$/&&must)covered[tokens[i]]=1
    }
    if(mode=="evidence"&&section~/^results/){
      count++;if(id!~/^[A-Za-z][A-Za-z0-9._-]*$/)problem("invalid result ID: " id);if(seen[id]++)problem("duplicate result: " id)
      result=toupper(a[3]);cause=tolower(a[4]);if(result!="PASS"&&result!="FAIL"&&result!="BLOCKED")problem("invalid result: " id)
      if(result=="FAIL"&&cause!="code"&&cause!="plan")problem("FAIL needs cause code or plan: " id)
      if(result=="BLOCKED"&&(a[5]==""||a[5]~/^</))problem("BLOCKED needs Observed: " id)
      if(index(" " withdrawn " "," " id " "))problem(id " was removed by the human: delete its row")
      print "E\034" id "\034" result "\034" cause "\034" a[6]
    }
  }
  END{
    question();if(mode=="intent"){if(!outcomes)problem("Understood as needs a filled O criterion");if(target!="local"&&target!="pr"&&target!="deploy")problem("Delivery Target must be local, pr or deploy, alone on its line (" (rawtarget==""?"missing":"found \"" rawtarget "\"") "): put any detail on a \"- Note:\" line");if(!ca)print "Y\034Clarity table missing under a \"## Clarity\" heading: copy it from templates/intent.md";else{n=split("Outcome Scope AS-IS TO-BE Success Constraints",an," ");for(i=1;i<=n;i++){k=tolower(an[i]);gsub(/[^a-z]/,"",k);if(!(k in cs)){print "Y\034Clarity needs a row for " an[i];cy++}else{pts+=(cs[k]=="clear")?2:(cs[k]=="assumed");if(cs[k]!="clear")weak=weak (weak==""?"":", ") an[i] " " cs[k]}}if(!cy&&pts*100<90*2*n)print "Y\034clarity " int(pts*100/(2*n)) "% < 90%: settle " weak " by exploring, reproducing, researching or asking the requester"}}
    if(mode=="plan"){if(NR>150)problem("PLAN.md has " NR " lines; keep it to 150 and move detail into refs/");if(!flags)problem("Risk flags: line missing");if(!count)problem("Scenarios need at least one row");n=split(objectives,os," ");for(i=1;i<=n;i++)if(os[i]!=""&&!covered[os[i]])problem(os[i] " has no must scenario")}
    if(mode=="evidence"){if(!commits)problem("Commit lines missing");if(!count)problem("Results need at least one row");n=split(scenarios " " scored,ss," ");for(i=1;i<=n;i++)if(ss[i]!=""&&!seen[ss[i]]&&!missing[ss[i]]++)problem("evidence.md is missing " ss[i] ": scenarios are never removed")}
  }' "$2"
}
read_intent() {
  objectives=; iproblems=; questions=; itarget=; iauth=; cproblems=
  while IFS=$'\034' read -r type a b; do
    case "$type" in O) objectives="$objectives $a";; X) iproblems="${iproblems}${a}"$'\n';; Q) questions="${questions}${a}"$'\n';; Y) cproblems="${cproblems}${a}"$'\n';; T) itarget=$a;; A) iauth=$a;; esac
  done < <(parse intent "$F/intent.md")
}
read_plan() {
  newplanned=; scenarios=; musts=' '; pproblems=; risks=
  while IFS=$'\034' read -r type a b; do
    case "$type" in X) pproblems="${pproblems}${a}"$'\n';; R) risks="${risks}${a}; ";; S) newplanned="${newplanned}${newplanned:+ }$a:$([ "$b" = 1 ] && printf y || printf n)"; scenarios="$scenarios $a"; [ "$b" != 1 ] || musts="$musts$a ";; esac
  done < <(parse plan "$F/PLAN.md")
}
read_evidence() {
  eproblems=; commits=(); repos=(); delivered=(); drepos=(); ids=(); results=(); causes=(); logs=(); etarget=; eauth=; checked=; output=; identity=
  while IFS=$'\034' read -r type a b c d; do
    case "$type" in
      X) eproblems="${eproblems}${a}"$'\n';;
      C) commits[${#commits[@]}]=$a; repos[${#repos[@]}]=$b; identity="${identity}C|$a|$b"$'\n';;
      D) delivered[${#delivered[@]}]=$a; drepos[${#drepos[@]}]=$b;;
      E) ids[${#ids[@]}]=$a; results[${#results[@]}]=$b; causes[${#causes[@]}]=$c; logs[${#logs[@]}]=$d; identity="${identity}$a|$b|$c|$d"$'\n';;
      T) etarget=$a;; A) eauth=$a;; K) checked=$a;; U) output=$a;;
    esac
  done < <(parse evidence "$F/evidence.md")
  eid=$(printf '%s' "$identity" | sha)
}
problems() { [ -z "$1" ] || { while IFS= read -r p; do [ -z "$p" ] || err "$p"; done <<< "$1"; return 1; }; }
gate_intent() {
  greason=; ihash=
  if [ -z "$intent" ]; then greason='intent not approved'
  elif [ ! -f "$F/intent.md" ]; then greason='intent.md changed after approval'
  else ihash=$(sha < "$F/intent.md"); [ "$ish" = "$ihash" ] || greason='intent.md changed after approval'; fi
  [ -z "$greason" ]
}
stopped() {
  stopreason=
  if [ "$fails" -ge 3 ]; then stopreason='3 review FAILs this build: stop, the human decides'
  elif [ "$dest" = human ] && [ "$rentry" = "$entry" ]; then stopreason=$reason; fi
  [ -n "$stopreason" ]
}
gate_plan() {
  if stopped; then greason="stopped for the human: $stopreason; resume with approve plan --human"; return 1; fi
  if pending_plan; then greason='Evidence routed to plan: update PLAN.md and approve plan'; return 1; fi
  if ! gate_intent; then greason="intent gate closed: $greason"; return 1; fi
  if [ -z "$plan" ]; then greason='plan not approved'
  elif [ "$pish" != "$ihash" ]; then greason='intent.md changed since plan approval'
  elif [ ! -f "$F/PLAN.md" ] || [ "$psh" != "$(sha < "$F/PLAN.md")" ]; then greason='PLAN.md changed after approval'; fi
  [ -z "$greason" ]
}
pending_plan() { [ "$dest" = plan ] && [ "${rseq:-0}" -gt "${pseq:-0}" ]; }
route_current() { [ "$rid" = "$eid" ] && [ "$rentry" = "$entry" ]; }
authorized() { local v re='^yes([^a-z0-9_]|$)'; v=$(one_line "$1" | tr '[:upper:]' '[:lower:]'); [[ $v =~ $re ]]; }
delivery_authority() {
  dreason=
  case "$1" in local) return 0;; pr|deploy) :;; *) found=missing; [ -z "$1" ] || found="found \"$1\""; dreason="Delivery Target must be local, pr or deploy ($found)"; return 1;; esac
  if authorized "$eauth" || { [ "$1" = "$itarget" ] && authorized "$iauth"; }; then return 0; fi
  dreason="authorize $1"; return 1
}
plan_history() {
  removed=; dropped=; violations=
  for item in $planned; do
    id=${item%:*}; flag=${item#*:}
    case " $scenarios " in *" $id "*) if [ "$flag" = y ]; then case "$musts" in *" $id "*) :;; *) dropped="${dropped}${dropped:+; }$id"; violations="${violations}$id no longer must"$'\n';; esac; fi;;
      *) removed="${removed}${removed:+; }$id"; violations="${violations}$id removed"$'\n';;
    esac
  done
  # A scenario only QA added is removed by deleting its evidence.md row.
  [ -f "$F/evidence.md" ] || return 0
  rows=" $(parse evidence "$F/evidence.md" | awk -F'\034' '$1=="E"{printf "%s ", $2}')"
  for id in $scored; do
    case " $scenarios $planned " in *" $id "*|*" $id:"*) continue;; esac
    case "$rows" in *" $id "*) :;; *) removed="${removed}${removed:+; }$id"; violations="${violations}$id removed"$'\n';; esac
  done
}

filled() { [ -n "$1" ] && [[ $1 != \<* ]]; }
# Prints the number of VERDICT lines in review.md (HTML comments skipped), how many rounds after the first
# $1 are not PASS, and the newest verdict word (last: it may be empty).
verdicts() {
  [ -f "$F/review.md" ] || { printf '0\n'; return; }
  awk -v k="${1:-0}" "$UNCOMMENT"'{if(uncomment())next;gsub(/[`*]/,"");if(tolower($0)~/^[ \t]*verdict[ \t]*:/){n++;sub(/^[^:]*:[ \t]*/,"");v=toupper($0);if(v~/(PASS|FAIL)[ \t]*[|\/][ \t]*(PASS|FAIL)/)v="UNDECIDED";else sub(/[^A-Z].*$/,"",v);if(n>k&&v!="PASS")bad++}}END{print n+0, bad+0, v}' "$F/review.md"
}
qa_action() {
  local need= id
  for id in $scenarios $scored; do case " $need " in *" $id "*) :;; *) need="${need}${need:+ }$id";; esac; done
  action="run QA on $need, fill evidence.md, sdlc.sh score"
}
derive() {
  STATE=READY; phase=intent; action=; exitcode=0
  if [ -n "$closed" ] || [ "$F" = "$STORE/archive/$slug" ]; then STATE=DONE; phase=done; action=$closed
  elif [ ! -f "$F/.state" ]; then STATE=BLOCKED; phase=legacy; action="legacy v0 feature: finish it with kit v0.27.0, or sdlc.sh close $slug dropped"
  elif stopped; then STATE=NEEDS-HUMAN; phase=build; [ "$fails" -ge 3 ] || phase=evidence; action="stopped for the human: $stopreason; resume with approve plan --human"
  else
    read_intent
    if [ -n "$iproblems" ]; then action=$(joined "$iproblems")
    elif [ -n "$questions" ]; then STATE=NEEDS-HUMAN; action=$(joined "$questions")
    elif ! gate_intent; then if [ -n "$cproblems" ]; then action="$greason; $(joined "$cproblems")"; else action="$greason; approve intent --agent"; if human_gate intent; then STATE=NEEDS-HUMAN; action="$greason; approve intent --human"; fi; fi
    elif pending_plan; then phase=plan; action="re-scout ($reason), update PLAN.md, approve plan"
    else
      phase=plan; read_plan
      if [ -n "$pproblems" ]; then action=$(joined "$pproblems")
      elif ! gate_plan; then action="$greason; approve plan --agent"; if human_gate plan || [ -n "$risks" ]; then STATE=NEEDS-HUMAN; action="$greason; approve plan --human $risks"; fi
      else
        read_evidence
        if [ "$verdict" != pass ] || [ "$ventry" != "$entry" ]; then phase=build; action='implement PLAN.md, commit any change, review'; if [ "$dest" = build ] && [ "$entry" -eq "$((rentry+1))" ]; then action="fix $(printf '%s' "$lastfail" | tr ',' ' ') (return $rb/3), commit, review"; fi
        elif [ ! -f "$F/evidence.md" ]; then phase=evidence; qa_action
        elif [ -n "$eproblems" ]; then phase=evidence; action=$(joined "$eproblems")
        elif ! route_current; then phase=evidence; qa_action
        elif [ "$dest" = deliver ]; then
          # Before Delivery is filled, the delivery goes to intent.md's target.
          phase=deliver; target=$etarget; case "$target" in local|pr|deploy) :;; *) target=$itarget;; esac
          if ! delivery_authority "$target"; then STATE=NEEDS-HUMAN; action=$dreason
          else action="deliver, fill Delivery, sdlc.sh close $slug shipped"; fi
        else phase=evidence; qa_action; fi
      fi
    fi
  fi
  case "$STATE" in NEEDS-HUMAN) exitcode=10;; BLOCKED) exitcode=20;; DONE) exitcode=30;; esac
}
json() { printf '%s' "$1" | awk 'BEGIN{printf "\"";for(j=1;j<32;j++)control[sprintf("%c",j)]=j}{if(NR>1)printf "\\n";for(i=1;i<=length($0);i++){c=substr($0,i,1);if(c=="\\"||c=="\"")printf "\\%s",c;else if(c in control)printf "\\u%04x",control[c];else printf "%s",c}}END{printf "\""}'; }
show_score() {
  printf 'SCORE %s\nFAIL %s\nBLOCKED %s\nROUTE %s — %s\n' "$display_score" "${fail_display:-none}" "${blocked_display:-none}" "$dest" "$reason"
}
score_counts() {
  total=${#ids[@]}; passed=0; must_total=0; must_pass=0; must_blocked=0; fail_display=; blocked_display=; code_ids=; plan_ids=; repeat_ids=; nfails=0
  for id in $scenarios; do case "$musts" in *" $id "*) must_total=$((must_total+1));; esac; done
  for ((i=0;i<total;i++)); do
    id=${ids[i]}; result=${results[i]}; cause=${causes[i]}
    [ "$result" != PASS ] || passed=$((passed+1))
    case "$musts" in *" $id "*) [ "$result" != PASS ] || must_pass=$((must_pass+1)); [ "$result" != BLOCKED ] || must_blocked=1;; esac
    if [ "$result" = BLOCKED ]; then blocked_display="${blocked_display}${blocked_display:+ }$id"; fi
    if [ "$result" = FAIL ]; then
      nfails=$((nfails+1)); fail_display="${fail_display}${fail_display:+ }$id($cause)"
      if [ "$cause" = plan ]; then plan_ids="${plan_ids}${plan_ids:+,}$id"
      else code_ids="${code_ids}${code_ids:+,}$id"; case ",$lastfail," in *",$id,"*) repeat_ids="${repeat_ids}${repeat_ids:+,}$id";; esac; fi
    fi
  done
  pct=$(awk -v p="$passed" -v t="$total" 'BEGIN{printf "%.1f",t?p*100/t:0}')
  display_score="$passed/$total ($pct%) · must $must_pass/$must_total"
}
validate_evidence() {
  problems "$eproblems" || return 1
  for ((i=0;i<${#ids[@]};i++)); do
    if [ "${results[i]}" != BLOCKED ]; then
      path=${logs[i]}; case "/${path//\\//}/" in //|//*|/[A-Za-z]:*|/\<*|*/../*) err "${ids[i]} needs a non-empty log inside the feature folder"; return 1;; esac
      [ -s "$F/$path" ] || { err "missing or empty log: $path"; return 1; }
    fi
  done
}
# HEAD and toplevel of the project root's repository and of every repository inside the root (or only
# of config repos: or review --repos, spaces or commas between entries), tab-separated pairs on one line: a review PASS
# binds them all. With review --uncommitted, a repository with uncommitted changes records HEAD+tree,
# the tree its working tree would commit, so a commit-gated project can review first and commit that
# exact change after. Without it, nothing is fingerprinted and HEAD alone is bound, as in v2.1.0.
review_heads() {
  root_repo
  if [ -n "$bound" ]; then
    read -r -a list <<< "${bound//,/ }"
    [ "${#list[@]}" -gt 0 ] || die "$boundby '$bound' lists no repository: name one, or leave it empty to bind every repository"
    proot=$(cd "$ROOT" && pwd -P)
    for path in "${list[@]}"; do
      # "." names the repository holding the project root; any other entry is a repository's own top folder.
      case "$path" in /*|[A-Za-z]:*|\<*) die "$boundby '$path' must be a path relative to the project root";; esac
      repo_path "$path"; preal=$(cd "$REPO" 2>/dev/null && pwd -P) || preal=
      case "$preal/" in "$proot"/*) :;; *) die "$boundby '$path' is not a directory under the project root";; esac
      top=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || die "$boundby '$path' is not in a git repository"
      [ "$preal" = "$proot" ] || [ "$preal" = "$(cd "$top" && pwd -P)" ] || die "$boundby '$path' is not the top folder of a git repository (it is inside $top)"
    done
  fi
  { if [ -n "$bound" ]; then for path in "${list[@]}"; do printf '%s\n' "$ROOT/$path"; done
    else
      git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || :
      { find "$ROOT" \( -name node_modules -o -name .sdlc \) -prune -o -name .git -print -prune 2>/dev/null || :; } | while IFS= read -r g; do dirname "$g"; done
    fi
  } | { seen=$'\n'; while IFS= read -r dir; do
    top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) && head=$(git -C "$top" rev-parse -q --verify HEAD 2>/dev/null) || continue
    # The root's repository comes from rev-parse and from find: inspect it once.
    case "$seen" in *$'\n'"$top"$'\n'*) continue;; esac; seen="$seen$top"$'\n'
    if [ -n "$uncommitted" ]; then changes "$top" "$top"; else dirty=; fi
    if [ -n "$dirty" ]; then
      rc=0; tree=$(worktree_tree "$top") || rc=$?
      case "$rc" in 0) head="$head+$tree";; 3) :;; *) exit 1;; esac
    fi
    printf '%s\t%s\n' "$head" "$top"
  done; } | sort -u | awk '{printf "%s%s", (NR>1 ? "\t" : ""), $0}'
}
# True when review_heads' record still holds HEAD-only: every bound repository is at the HEAD it recorded.
# A bound working tree (review --uncommitted, head+tree) never equals HEAD, so it never carries.
heads_unchanged() {
  local rhead top; [ -n "$heads" ] || return 1
  while IFS=$'\t' read -r rhead top; do
    [ "$(git -C "$top" rev-parse -q --verify HEAD 2>/dev/null)" = "$rhead" ] || return 1
  done < <(printf '%s' "$heads" | awk -F'\t' '{for(j=1;j<NF;j+=2)print $j "\t" $(j+1)}')
}
# PLAN.md without its Scenarios section, hashed: what a diff review judged the code against.
plan_body() { awk "$UNCOMMENT"'{if(uncomment())next;l=tolower($0);sub(/^[ \t]+/,"",l);gsub(/[`*]/,"",l)} l~/^## /{skip=(substr(l,4)~/^[ \t]*scenarios/)} !skip' "$F/PLAN.md" | sha; }
# The tree id that git add -A would commit in repository $1, store and untracked nested repositories
# excluded, built in a copy of its index. The store leaves the copy after add, so it stays out whether it
# is untracked, ignored or partly tracked (git add refuses an exclude naming an ignored path). When git add
# cannot read the working tree, exit 3 after one line saying why: the caller binds HEAD alone, as v2.1.0
# did. Called in a command substitution, so its traps are its own; tmp is global for the EXIT trap, which
# runs after the function returns.
worktree_tree() {
  local gitdir tree path cause specs=(.)
  for path in "${nested[@]}"; do specs[${#specs[@]}]=":(top,exclude,literal)$path"; done
  tmp=; trap 'rm -rf "$tmp"' EXIT; trap 'exit 130' INT TERM HUP
  tmp=$(mktemp -d) || die 'cannot create a temporary folder'
  gitdir=$(git -C "$1" rev-parse --absolute-git-dir) || die "not a git repository: $1"
  if [ -f "$gitdir/index" ]; then cp -p "$gitdir/index" "$tmp/index"; else GIT_INDEX_FILE=$tmp/index git -C "$1" read-tree HEAD; fi || die "cannot copy the index: $1"
  cause=$(GIT_INDEX_FILE=$tmp/index git -C "$1" add -A -- "${specs[@]}" 2>&1 >/dev/null) ||
    { err "cannot fingerprint the uncommitted changes in $1 (${cause%%$'\n'*}): the PASS binds its HEAD only"; exit 3; }
  for path in "${store_paths[@]}"; do
    GIT_INDEX_FILE=$tmp/index git -C "$1" rm -r -q -f --cached --ignore-unmatch -- ":(top,literal)$path" >/dev/null || die "cannot fingerprint the working tree: $1"
  done
  tree=$(GIT_INDEX_FILE=$tmp/index git -C "$1" write-tree) || die "cannot fingerprint the working tree: $1"
  printf '%s' "$tree"
}
# Uncommitted changes in repository $1, as git status run in $2 lists them, into dirty. The store is left
# out, and so is every untracked nested repository (a worktree or clone inside it, listed by ls-files
# with a trailing slash): it is never part of a commit, and git add would stage it as a gitlink. Its
# path goes to nested and excludes. Tracked gitlinks are not untracked and stay in.
changes() {
  local path
  store_excludes "$1"; nested=()
  dirty=$(git -C "$2" status --porcelain -- . "${excludes[@]}") || die "cannot inspect working tree: $2"
  [ -n "$dirty" ] || return 0
  while IFS= read -r -d '' path; do
    case "$path" in */) nested[${#nested[@]}]=${path%/}; excludes[${#excludes[@]}]=":(top,exclude,literal)${path%/}";; esac
  done < <(git -C "$1" ls-files -o --exclude-standard -z)
  [ "${#nested[@]}" -eq 0 ] || dirty=$(git -C "$2" status --porcelain -- . "${excludes[@]}") || die "cannot inspect working tree: $2"
}
root_repo() {
  roottop=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null) || roottop=
  rootprefix=$(git -C "$ROOT" rev-parse --show-prefix 2>/dev/null) || rootprefix=
}
# Pathspecs that keep the store out of repository $1's status and fingerprint.
# store_paths holds the same stores relative to the toplevel.
store_excludes() {
  local path
  excludes=(':(exclude).sdlc'); store_paths=(.sdlc)
  [ "$1" != "$roottop" ] || store_paths[${#store_paths[@]}]=${rootprefix}.sdlc
  ptop=$(cd "$1" && pwd -P); physical_store=$(cd "$STORE" && pwd -P)
  case "$physical_store" in "$ptop"/*) store_paths[${#store_paths[@]}]=${physical_store#"$ptop"/};; esac
  for path in "${store_paths[@]:1}"; do excludes[${#excludes[@]}]=":(top,exclude,literal)$path"; done
}
repo_path() { case "$1" in /*|[A-Za-z]:*|\<*) die "repo path must be relative: $1";; esac; REPO=$ROOT/$1; }
# $2 names the evidence line whose repository path is $1.
repo_dir() { repo_path "$1"; [ -d "$REPO" ] || die "$2 path '$1' is not a directory under the project root: write '- $2: <sha> <relative-path>'"; }
validate_commits() {
  # Repositories are compared by git's own toplevel path, so any path into a repository is bound to the review.
  # A Commit repository the last review did not see (outside the project root) is refused.
  root_repo
  for ((i=0;i<${#commits[@]};i++)); do
    repo_dir "${repos[i]}" Commit
    full=$(git -C "$REPO" rev-parse --verify -q "${commits[i]}^{commit}") || die "unknown commit: ${commits[i]}"
    head=$(git -C "$REPO" rev-parse HEAD) || die "not a git repository: ${repos[i]}"
    [ "$head" = "$full" ] || die "HEAD differs from Commit: ${repos[i]}"
    top=$(git -C "$REPO" rev-parse --show-toplevel) || die "not a git repository: ${repos[i]}"
    reviewed=$(printf '%s' "$heads" | awk -F'\t' -v top="$top" '{for(j=1;j<NF;j+=2)if($(j+1)==top){print $j;exit}}')
    [ -n "$reviewed" ] || die "${repos[i]} was not under review: commit, then review again from the project root; config repos: ${bound:+(now: $bound) }or review --repos names the repositories a review binds"
    rbase=${reviewed%%+*}; rtree=; [ "$rbase" = "$reviewed" ] || rtree=${reviewed#*+}
    # A PASS on uncommitted changes binds their tree. The Commit is the reviewed HEAD or descends from it, holds
    # the bound tree inside its path, and outside it changes nothing since that HEAD that the tree does not hold.
    # Changes left uncommitted outside the path do not count, as when a commit is reviewed.
    if [ -n "$rtree" ]; then
      # An unreachable tree can be pruned (gc.pruneExpire, two weeks by default): say so rather than call the Commit wrong.
      git -C "$REPO" cat-file -e "$rtree^{tree}" 2>/dev/null || die "the reviewed tree $rtree of ${repos[i]} is gone (git gc?): review again"
      store_excludes "$top"
      { [ "$full" = "$rbase" ] || git -C "$REPO" merge-base --is-ancestor "$rbase" "$full"; } &&
        git -C "$REPO" diff --quiet "$full" "$rtree" -- . "${excludes[@]}" &&
        changed=$(git -C "$REPO" diff --no-renames --name-only "$rbase" "$full" -- ':/' "${excludes[@]}") &&
        differs=$(git -C "$REPO" diff --no-renames --name-only "$full" "$rtree" -- ':/' "${excludes[@]}") &&
        [ -z "$(printf '%s\n%s\n' "$changed" "$differs" | awk 'NF&&seen[$0]++')" ] ||
        die "Commit ${commits[i]} is not the reviewed uncommitted change: commit exactly it (tree $rtree) on top of the reviewed commit $rbase, or review again"
    else
      [ "$full" = "$rbase" ] || die "Commit ${commits[i]} is not the reviewed commit $rbase: commit, then review again"
    fi
    changes "$top" "$REPO"
    [ -z "$dirty" ] || die "dirty tree in ${repos[i]}: $dirty"
  done
}
command=${1:-help}; [ "$#" -eq 0 ] || shift
case "$command" in
  help) [ "$#" -eq 0 ] || die 'unexpected arguments' 2; usage; exit;;
  --version) [ "$#" -eq 0 ] || die 'unexpected arguments' 2; cat "$KIT/VERSION"; exit;;
  init)
    custom=; if [ "$#" -gt 0 ]; then [ "$#" -eq 2 ] && [ "$1" = --knowledge ] && [ -n "$2" ] || die 'init [--knowledge path]' 2; custom=$2; fi
    if [ -f .sdlc/config.md ]; then printf 'Existing .sdlc/config.md left as is.\n'; exit; fi
    mkdir -p .sdlc/work .sdlc/archive
    tmp=$(mktemp .sdlc/config.md.XXXXXX)
    awk -v kit="$KIT" -v k="$custom" '/^kit:/{print "kit: " kit;next}/^knowledge:/{if(k!=""){print "knowledge: " k;next}}{print}' "$KIT/templates/config.md" > "$tmp"
    mv "$tmp" .sdlc/config.md
    ROOT=$PWD; STORE=$PWD/.sdlc; config
    case "$knowledge" in /*|[A-Za-z]:*) :;; *) mkdir -p "$knowledge";; esac
    # Records stay out of git through the clone-local exclude list, so init never changes a tracked file.
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && ! git check-ignore -q .sdlc 2>/dev/null; then
      exclude=$(git rev-parse --git-path info/exclude); mkdir -p "$(dirname "$exclude")"
      [ ! -s "$exclude" ] || [ -z "$(tail -c 1 "$exclude")" ] || printf '\n' >> "$exclude"
      # No trailing slash, so a symlinked .sdlc is ignored too; glob characters in the folder path are escaped.
      printf '/%s.sdlc\n' "$(git rev-parse --show-prefix | sed 's/[][*?\\]/\\&/g')" >> "$exclude"
      if git check-ignore -q .sdlc 2>/dev/null; then printf 'Ignored .sdlc/ in %s (this clone only; no tracked file changed).\n' "$exclude"
      else err "could not make git ignore .sdlc/ through $exclude: add it to your ignore rules"; fi
    fi
    printf 'Initialized .sdlc/. Fill config.md, then sdlc.sh new <slug>.\n'; exit;;
esac
find_store
case "$command" in
  new)
    [ "$#" -eq 1 ] || die 'new <slug>' 2; slug=$1; valid_slug "$slug"
    [ ! -e "$STORE/work/$slug" ] && [ ! -e "$STORE/archive/$slug" ] || die "feature already exists: $slug"
    F=$STORE/work/$slug; mkdir -p "$F/refs" "$F/logs"
    awk -v slug="$slug" -v today="$(date +%Y-%m-%d)" '{gsub(/<slug>/,slug);if($0~/^- Date:/)$0="- Date: " today;print}' "$KIT/templates/intent.md" > "$F/intent.md"
    load_state; save_state; printf 'Created %s. Fill intent.md until its Clarity reaches 90%%, then approve intent.\n' "$slug";;
  status)
    selected=; asjson=0
    for arg in "$@"; do case "$arg" in --json) [ "$asjson" -eq 0 ] || die 'duplicate --json' 2; asjson=1;; *) [ -z "$selected" ] || die 'status [slug] [--json]' 2; selected=$arg; valid_slug "$selected";; esac; done
    if [ "$asjson" -eq 1 ]; then printf '{"store":'; json "$STORE"; printf ',"human_gates":'; json "$gates"; printf ',"features":['
    else printf 'Store: %s · human_gates: %s · kit: %s\n' "$STORE" "$gates" "$(cat "$KIT/VERSION")"; fi
    paths=(); if [ -n "$selected" ]; then feature "$selected"; paths[0]=$F; else for path in "$STORE"/work/*; do
      [ -d "$path" ] || continue; if is_slug "$(basename "$path")"; then paths[${#paths[@]}]=$path; else err "skipped $(basename "$path"): not a valid slug"; fi
    done; fi
    sep=
    for path in "${paths[@]}"; do
      feature "$(basename "$path")"; derive
      if [ "$asjson" -eq 0 ]; then printf '%s %s %s %s score=%s\n' "$slug" "$phase" "$STATE" "$action" "${score:--}"
      else
        printf '%s{"slug":' "$sep"; json "$slug"; printf ',"phase":'; json "$phase"; printf ',"state":'; json "$STATE"; printf ',"action":'; json "$action"; printf ',"score":'; json "$score"; printf ',"route":'; json "$dest"
        printf ',"returns_plan":%s,"returns_build":%s,"review_fails":%s}' "$rp" "$rb" "$fails"; sep=,
      fi
    done
    [ "$asjson" -eq 0 ] || printf ']}\n';;
  next) [ "$#" -eq 1 ] || die 'next <slug>' 2; feature "$1"; derive; printf '%s %s: %s\n' "$STATE" "$phase" "$action"; exit "$exitcode";;
  check|approve)
    if [ "$command" = check ]; then [ "$#" -eq 2 ] || die 'check intent|plan <slug>' 2
    else [ "$#" -eq 4 ] || die 'approve intent|plan <slug> --human|--agent note' 2; fi
    which=$1; case "$which" in intent|plan) :;; *) die 'gate must be intent or plan' 2;; esac
    feature "$2"
    if [ "$command" = check ]; then
      if "gate_$which"; then printf 'GATE OPEN\n'; else printf 'GATE CLOSED: %s\n' "$greason"; exit 1; fi
    else
      mutable; [ -f "$F/.state" ] || die 'legacy feature cannot be approved'
      case "$3" in --human) who=human;; --agent) who=agent;; *) die 'choose --human or --agent' 2;; esac
      note=$(one_line "$4"); [ -n "$note" ] || die 'approval note required' 2
      if [ "$which" = plan ] && [ "$who" = agent ] && stopped; then die "stopped for the human: $stopreason; resume with approve plan --human"; fi
      read_intent; problems "$iproblems" || exit 1; problems "$questions" || exit 1
      if [ "$which" = intent ]; then
        if [ "$who" = agent ] && human_gate intent; then die 'intent needs --human approval'; fi
        hash=$(sha < "$F/intent.md"); if [ "$ish" = "$hash" ]; then printf 'intent already approved\n'; exit; fi; problems "$cproblems" || exit 1
        event; intent="$hash $who $seq $ts $note"
      else
        gate_intent || die "$greason"; read_plan; problems "$pproblems" || exit 1
        if [ "$who" = agent ]; then human_gate plan && die 'plan needs --human approval'; [ -z "$risks" ] || die "risk flags need --human approval: $risks"; fi
        plan_history
        if [ "$who" = agent ]; then problems "$violations" || exit 1
        elif [ -n "$violations" ]; then
          annotation=; [ -z "$removed" ] || annotation="removed: $removed"; [ -z "$dropped" ] || annotation="${annotation}${annotation:+; }must dropped: $dropped"
          note="$note ($annotation)"; kept=; for id in $scored; do case "; $removed;" in *"; $id;"*) :;; *) kept="${kept}${kept:+ }$id";; esac; done; scored=$kept
          for id in $(printf '%s' "$removed" | tr ';' ' '); do withdrawn="${withdrawn}${withdrawn:+ }$id"; done
        fi
        hash=$(sha < "$F/PLAN.md")
        if [ "$who" = agent ] && pending_plan && [ "$psh" = "$hash" ]; then die 'PLAN.md unchanged since Evidence routed to plan'; fi
        if [ "$psh" = "$hash" ] && [ "$pish" = "$ihash" ] && [ -z "$removed" ] && ! pending_plan && ! stopped; then printf 'plan already approved\n'; exit; fi
        # Only the human or a counted return to plan resets the review FAIL cap; an agent re-approval keeps it.
        keep=$fails; if [ "$who" = human ] || pending_plan; then keep=0; fi
        # The build's review PASS carries over when nothing it judged moved: every HEAD it bound is unchanged
        # and so is PLAN.md outside Scenarios, as when only a scenario or its procedure is retried.
        # A plan gap check that passed may add a round; any later round that is not PASS stops the carry.
        body=$(plan_body); carry=; read -r _ newbad _ <<< "$(verdicts "$rounds")"
        if [ "$verdict" = pass ] && [ "${newbad:-0}" = 0 ] && [ "$ventry" = "$entry" ] && [ "$planbody" = "$body" ] && [ "$pish" = "$ihash" ] && heads_unchanged; then
          case "$vnote" in 'carried: '*) carry=$vnote;; *) carry="carried: $vnote";; esac
        fi
        event; plan="$hash $ihash $who $seq $ts $note"; entry=$((entry+1)); fails=$keep; planbody=$body; planned=$newplanned
        if [ -n "$carry" ]; then review="pass $entry $seq $vsha $carry"; else review=; heads=; fi
        left=; for id in $withdrawn; do case " $scenarios " in *" $id "*) :;; *) left="${left}${left:+ }$id";; esac; done; withdrawn=$left
        # Rounds already in review.md (the plan gap check) cannot pass the build.
        read -r rounds _ <<< "$(verdicts)"
      fi
      save_state; printf '%s approved. Run sdlc.sh next %s.\n' "$which" "$slug"
      [ -z "${carry:-}" ] || printf 'review PASS carried: the reviewed HEADs and PLAN.md outside Scenarios are unchanged. Phase 4: run QA, fill evidence.md, score.\n'
    fi;;
  review)
    rusage='review <slug> pass|fail note, or review <slug> pass --uncommitted note; --repos "path ..." before the note names the repositories to bind'
    [ "$#" -ge 3 ] || die "$rusage" 2
    rslug=$1; rverdict=$2; shift 2; uncommitted=; rrepos=
    # --repos replaces config repos: for this review only.
    while [ "$#" -gt 1 ]; do case "$1" in --uncommitted) [ -z "$uncommitted" ] || die "$rusage" 2; uncommitted=1; shift;;
      --repos) [ "$#" -gt 2 ] && [ -z "$rrepos" ] || die "$rusage" 2; rrepos=1; bound=$(one_line "$2"); boundby='review --repos'; shift 2;; *) die "$rusage" 2;; esac; done
    case "$1" in --uncommitted|--repos) die "$rusage" 2;; esac
    [ -z "$rrepos" ] || [ -n "$bound" ] || die 'review --repos lists no repository: name one, or leave --repos out' 2
    set -- "$rslug" "$rverdict" "$1"; feature "$1"; mutable
    case "$2" in pass|fail) :;; *) die 'review verdict must be pass or fail' 2;; esac
    [ -z "$uncommitted$rrepos" ] || [ "$2" = pass ] || die '--uncommitted binds a PASS, as --repos does: review <slug> fail note' 2
    note=$(one_line "$3"); [ -n "$note" ] || die 'review note required' 2
    gate_plan || die "$greason"
    read -r nrounds _ actual_verdict <<< "$(verdicts)"
    [ -n "$actual_verdict" ] || die 'review.md has no VERDICT line'
    [ "$nrounds" -gt "$rounds" ] || die 'review.md has no new round since the last review or plan approval: the reviewer appends one'
    [ "$actual_verdict" = "$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')" ] || die "review.md's last VERDICT is $actual_verdict"
    vsha=$(git -C "$ROOT" rev-parse -q --verify HEAD 2>/dev/null) || vsha=-
    # Only a PASS binds heads: score needs one, and a FAIL is never scored.
    heads=; [ "$2" != pass ] || heads=$(review_heads)
    event; review="$2 $entry $seq $vsha $note"; rounds=$nrounds
    if [ "$2" = fail ]; then fails=$((fails+1)); printf 'review FAIL %s/3\n' "$fails"; [ "$fails" -lt 3 ] || printf '3 review FAILs this build: stop, the human decides\n'
    else printf 'review PASS. Phase 4: run QA, fill evidence.md, score.\n'; if printf '%s' "$heads" | awk -F'\t' '{for(j=1;j<NF;j+=2)if($j~/^[0-9a-f]+\+[0-9a-f]+$/)f=1}END{exit !f}'; then printf 'Uncommitted changes are bound, untracked unignored files included: a Commit must hold exactly those inside its path, on top of the reviewed HEAD. Amending or rebasing the reviewed HEAD itself needs a new review; a commit made on top of it may be reworded.\n'; fi; fi
    save_state;;
  score)
    [ "$#" -eq 1 ] || die 'score <slug>' 2; feature "$1"; mutable; gate_plan || die "$greason"
    read_intent; read_plan; read_evidence
    replay=0
    # A build return increments entry, so its unchanged evidence can replay until the next review.
    if [ "$rid" = "$eid" ] && [ "$dest" = build ] && [ "$entry" -eq "$((rentry+1))" ] && [ "$ventry" != "$entry" ]; then replay=1; fi
    if ! { [ "$verdict" = pass ] && [ "$ventry" = "$entry" ]; } && [ "$replay" -ne 1 ]; then die 'review PASS required for current build entry'; fi
    validate_evidence || exit 1; validate_commits; score_counts
    if route_current || [ "$replay" -eq 1 ]; then show_score; exit; fi
    scoring_entry=$entry
    if [ -n "$plan_ids" ]; then want=plan; reason="plan failures: $plan_ids"
    elif [ -n "$repeat_ids" ]; then want=plan; reason="$repeat_ids failed again after a build return"
    elif [ "$must_pass" -eq "$must_total" ] && [ "$((passed*100))" -ge "$((95*total))" ]; then want=deliver; reason='every must PASS; threshold met'
    elif [ "$must_blocked" -eq 1 ] || [ "$nfails" -eq 0 ]; then want=human; reason='BLOCKED scenarios need the human'
    else want=build; reason="code failures: $code_ids"; fi
    dest=$want
    case "$want" in
      plan) if [ "$rp" -ge 3 ]; then dest=human; reason="cap: 3 returns to plan; $reason"; else rp=$((rp+1)); reason="return $rp/3; $reason"; lastfail=; fi;;
      build) if [ "$rb" -ge 3 ]; then dest=human; reason="cap: 3 returns to build; $reason"; else rb=$((rb+1)); reason="return $rb/3: $(printf '%s' "$code_ids" | tr ',' ' ')"; entry=$((entry+1)); fails=0; lastfail=$code_ids; fi;;
      deliver) lastfail=;;
    esac
    for id in "${ids[@]}"; do case " $scored " in *" $id "*) :;; *) scored="${scored}${scored:+ }$id";; esac; done
    event; route="$dest $eid $scoring_entry $seq $reason"; score="$passed/$total $pct must $must_pass/$must_total"; save_state; show_score;;
  close)
    [ "$#" -eq 3 ] || die 'close <slug> shipped|dropped reason' 2; feature "$1"; mutable
    note=$(one_line "$3"); [ -n "$note" ] || die 'close reason required' 2
    [ ! -e "$STORE/archive/$slug" ] || die "archive already exists: $slug"
    case "$2" in
      dropped) :;;
      shipped)
        [ -f "$F/.state" ] || die 'legacy feature cannot ship'
        gate_plan || die "$greason"
        read_intent; read_plan; read_evidence
        [ "$dest" = deliver ] && route_current || die 'current evidence and build need a deliver route'
        validate_evidence || exit 1
        delivery_authority "$etarget" || die "$dreason"
        filled "$checked" && filled "$output" || die 'Delivery Checked with and Output required'
        for ((i=0;i<${#commits[@]};i++)); do
          repo_dir "${repos[i]}" Commit; commit_repo=$REPO; matchsha=; nodir=
          source_repo=$(git -C "$commit_repo" rev-parse --show-toplevel) || die "not a git repository: ${repos[i]}"
          for ((j=0;j<${#delivered[@]};j++)); do
            # A Delivered line for another repository (a deploy repository not checked out here, say) is skipped.
            repo_path "${drepos[j]}"
            delivered_repo=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || { [ -d "$REPO" ] || nodir=${drepos[j]}; continue; }
            [ "$delivered_repo" != "$source_repo" ] || matchsha=${delivered[j]}
          done
          [ -n "$matchsha" ] || die "Delivered missing for repo: ${repos[i]}: add '- Delivered: <sha> ${repos[i]}'${nodir:+ (the line for '$nodir' was skipped: it is not a folder under the project root)}"
          git -C "$commit_repo" rev-parse --verify -q "$matchsha^{commit}" >/dev/null || die "unknown Delivered commit: $matchsha"
          git -C "$commit_repo" diff --quiet "${commits[i]}" "$matchsha" || die 'Delivered tree differs from verified Commit'
          if [ "$etarget" != local ]; then remote=$(git -C "$commit_repo" branch -r --contains "$matchsha"); [ -n "$remote" ] || die 'Delivered commit is not on any remote'; fi
        done;;
      *) die 'close result must be shipped or dropped' 2;;
    esac
    event; closed="$2 $ts $note"; save_state; mkdir -p "$STORE/archive"; mv "$F" "$STORE/archive/$slug"
    printf 'Archived %s (%s).\n' "$slug" "$2";;
  *) die "unknown command: $command" 2;;
esac
