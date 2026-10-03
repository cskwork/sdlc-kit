<div align="center">

# sdlc-kit

### 코딩 에이전트가 자기 숙제를 자기가 채점하게 두지 마세요.

**AI 코딩 에이전트를 위한 이식 가능한 SDLC.**

Intent → spec → plan → build → evidence → maintain. 사람 승인 게이트와 새 컨텍스트 리뷰를 거치고, 교훈은 다음 실행에 남깁니다.

[![Release](https://img.shields.io/github/v/release/cskwork/sdlc-kit?style=flat-square&color=C79A55)](https://github.com/cskwork/sdlc-kit/releases/latest)
[![GitHub Pages](https://img.shields.io/badge/live_site-open-C79A55?style=flat-square)](https://cskwork.github.io/sdlc-kit/)
[![Harness neutral](https://img.shields.io/badge/harness-pi_%C2%B7_Claude_Code_%C2%B7_Codex_%C2%B7_Gemini-24211E?style=flat-square)](#빠른-시작)

[**라이브 사이트**](https://cskwork.github.io/sdlc-kit/) · [**60초 설치**](#빠른-시작) · [**계약 전문 읽기**](AGENTS.md) · [**English**](README.md)

</div>

---

코딩은 이제 빠릅니다. **틀리는 비용은 그대로 비쌉니다.**

흔한 에이전트 워크플로는 구현부터 시작합니다. 프롬프트를 받고, 코드를 쓰고, 테스트를 돌리고, 요청이 명확했다고 가정합니다. sdlc-kit은 명확화와 증거를 앞으로 당기고, 루프 내내 독립 검증을 유지합니다.

[Anthropic의 AI-Native SDLC 플레이북](https://claude.com/blog/the-ai-native-sdlc-playbook)을 옮긴 것이지만 Claude Code에 묶여 있지 않습니다. 킷은 순수 Markdown과 셸 스크립트라서, 파일을 읽고 명령을 실행할 수 있는 하네스라면 어디서든 쓸 수 있습니다.

> sdlc-kit은 독립 프로젝트이며 Anthropic과 무관합니다.

## 무엇이 다른가

| 흔한 에이전트 워크플로 | sdlc-kit |
|---|---|
| 첫 요청부터 코딩 시작 | 히스토리, 코드, 실현 가능성, 실제 제품을 먼저 살피고, 같은 변경을 이미 하는 기존 흐름도 찾음. 스스로 확인할 수 없는 것만 질문 |
| 사용자의 진단을 사실로 취급 | 주장마다 `[verified: 증거]` 또는 `[assumed: 이유]` 라벨 |
| 계획이 채팅 안에만 존재 | `intent.md`, `spec.md`, `plan.md`, `evidence.md`, `delivery.md`를 애플리케이션 git 히스토리 밖의 검색 가능한 저장소(`tools/kb.sh`)에 남김 |
| 작성자가 자기 작업을 직접 검사 | 새 컨텍스트 adversary가 스펙, 계획, diff를 공격하고, 별도의 verifier가 빌드를 끝까지 실행하며 부작용과 티켓 일치를 확인 |
| 통과한 테스트 스위트가 모든 주장을 대신함 | 주장마다 자기 증명이 붙음. 수정 전에 실패한 테스트, 리팩터링의 pin, 수치의 측정값 |
| 승인이 사라지는 채팅 메시지 | 승인 기록이 단계, 산출물, 시각, 모드를 담고 `.sdlc/approvals/`에 파일로 남음 |
| 실패한 시도는 잊힌 컨텍스트가 됨 | 교훈은 상한 있는 인덱스로, 업무 정책은 제품 영역 페이지로, 오래가는 사실은 `DOMAIN.md`로. 반복되는 교훈은 승격하며 프로젝트 검사가 1순위 |
| "끝났다"가 모호함 | 모든 실행이 `shipped`, `abandoned`, `dead-end`, `handed-off` 중 하나로 종결되고, `shipped`는 검증된 전달 기록을 요구 |

## 루프

```text
┌────────────┐     human gate     ┌────────────┐     human gate
│  1. INTENT │ ─────────────────▶ │   2. SPEC  │ ─────────────────┐
│ intent.md  │                    │  spec.md   │                  │
└─────▲──────┘                    └────────────┘                  ▼
      │                                                     ┌────────────┐
      │ new intent                                          │  3. PLAN   │
      │                                                     │  plan.md   │
┌─────┴──────┐                    ┌────────────┐             └─────┬──────┘
│ 6. MAINTAIN│ ◀───────────────── │ 5. EVIDENCE│ ◀────────────────┘
│ diagnosis  │   ship + observe   │evidence.md │   build + verify
└────────────┘                    └────────────┘
                                      ▲
                                      │ fresh-context verifier
                                ┌─────┴──────┐
                                │  4. BUILD  │
                                │code + tests│
                                └────────────┘
```

각 단계는 리뷰 가능한 산출물 하나를 만들고, 승인이 다음 단계를 엽니다. intent, spec, ship 게이트는 사람의 결정입니다. 채팅에서 승인하면 에이전트가 승인 명령을 대신 실행할 수 있고, 기록에는 `mode: delegated-chat`으로 남습니다. plan 게이트는 층이 나뉩니다. 새 컨텍스트 adversary가 모든 계획을 리뷰하고, 평범한 계획은 자동 승인됩니다(`mode: agent-adversary`). 트립와이어에 걸리면 사람 게이트가 됩니다. 트립와이어는 마이그레이션, 데이터 삭제, 공개 API나 계약 변경, 보안 경로, 인프라와 설정, 스펙 밖 범위입니다. 배포된 변경이 실패하면 Maintain 단계가 진단하고 다음 `intent.md`를 씁니다.

`.sdlc/config.md`의 `lazymode`는 사람 게이트와 자동 게이트의 경계를 옮깁니다. `init.sh`가 `lazymode: 1`을 심고, 에이전트가 원하는 레벨을 물어봅니다.

| lazymode | 사람에게 남는 게이트 |
|---|---|
| 0 | intent, spec, 트립와이어에 걸린 plan, ship (위 설계 그대로) |
| 1 (기본) | intent, spec, ship |
| 2 | intent, ship |
| 3 | intent |
| 4 | 없음. 루프가 스스로 진행 |

면제된 게이트는 `gates/approve.sh <stage> <artifact> --lazy --review "<what the review covered>"`로 승인합니다. 이 명령은 설정 레벨이 사람에게 남긴 게이트를 거부합니다. **lazymode가 옮기는 것은 누가 결정하느냐뿐이고, 리뷰를 받는지와 허용되는지는 그대로입니다.** 면제된 게이트에도 영향받는 코드와 동작의 리뷰가 따라붙습니다. 위험한 작업(데이터 손실, 공개 API, 보안 경로, 마이그레이션, 외부 배포)은 어느 레벨에서든 사람의 사전 허가가 필요하고, `--risk-authorized`로 기록됩니다. `tools/tripwire.sh`는 보조용 영어 키워드 스캔입니다. 걸리면 요구 조건이 늘지만, 깨끗하다고 면제되는 것은 없습니다.

모든 티켓이 6단계를 다 도는 것은 아닙니다.

| 루트 | 언제 | 흐름 |
|---|---|---|
| 컴팩트 | 작고 파악이 끝난 변경: 수정할 파일 확정, 기존 명령으로 성공 검증 가능, 미결 질문 없음, 이미 허가한 범위 안 | 작업 산출물은 `intent.md` 하나이고 파일, 증명, 위험, 베이스라인, 전달 목표를 함께 담음. intent(게이트) → build → ship. ship의 adversary 리뷰가 diff의 유일한 리뷰 |
| 풀 | 모호하거나, 범위가 넓거나, 위험한 일 | 6단계 전부 |

`intent.md`의 `Track:` 줄이 루트를 기록하고(기준은 `skills/1-intent`), 장애 대응도 같은 루트를 씁니다. build 중에 예상 밖의 일이 생기면 컴팩트를 풀로 승격하고 intent를 다시 승인받습니다. 범위를 잡기 어려울 만큼 흐릿한 티켓은 **map**(`map.md`: 목적지 · 정한 것 · 모르는 것 · 안 할 것)부터 만들고, 세션마다 모르는 것을 하나씩 풀어 `intent.md`를 쓸 수 있을 때까지 진행합니다.

## 빠른 시작

`bash`, `git`, coreutils가 필요합니다. macOS와 Linux에는 이미 있습니다. Windows에서는 **Git Bash**([Git for Windows](https://gitforwindows.org/)에 포함)나 WSL을 쓰고, 에이전트가 실행하는 것까지 모든 킷 명령을 거기서 돌리세요. PowerShell과 cmd로는 스크립트가 실행되지 않습니다.

```bash
# 1. 한 번 설치
git clone https://github.com/cskwork/sdlc-kit ~/sdlc-kit

# 2. 프로젝트(또는 모노레포의 배포 단위 하나)에 시드
cd /path/to/your-project
~/sdlc-kit/init.sh

# 3. 증명 명령(build, test, lint, run) 검토
#    비어 있는 명령은 에이전트가 저장소에서 찾아 채우고 한 번씩 실행
$EDITOR .sdlc/config.md
```

그다음 하네스의 프로젝트 지시 파일에 `For SDLC work, read ~/sdlc-kit/AGENTS.md and follow it.`를 추가해 라우팅 계약을 읽게 하세요.

| 하네스 | 파일 |
|---|---|
| pi, Codex CLI | `AGENTS.md` |
| Claude Code | `CLAUDE.md` |
| Gemini CLI | `GEMINI.md` |
| Cursor / 기타 에이전트 | 하네스가 읽는 지시 파일, 또는 세션에 `AGENTS.md`를 붙여넣기 |

이제 이렇게 말하면 됩니다.

```text
Start SDLC for <기능, 버그, 변경>
```

에이전트가 1단계로 라우팅해서 프로젝트를 탐색하고, 증거가 붙은 질문을 한 번에 하나씩 던집니다. `.sdlc/`가 있는 프로젝트에서는 "로그인 리다이렉트 고쳐줘" 같은 평범한 변경 요청으로도 루프가 시작됩니다. 읽기만 하는 질문으로는 시작되지 않습니다.

## 60초 예시

```text
you    Start SDLC for claims status self-service
agent  현재 API, UI 흐름, git 히스토리, 테스트 하네스를 확인했습니다.
       요청 속 주장 하나가 사실과 다릅니다. 증거는 이렇습니다...

       [심문이 한 질문씩 이어짐]

agent  intent.md가 준비됐습니다. Human summary를 검토하세요.
you    approve
agent  APPROVED: intent of claims-status (.sdlc/work/claims-status/intent.md)
       mode: delegated-chat으로 기록

       2단계는 승인된 산출물에서 시작합니다.
```

숨은 상태도, 벤더 전용 훅도 없습니다. 파일이 곧 프로토콜입니다.

## 무엇이 만들어지나

기능 하나당, **대상 프로젝트** 안에 이렇게 쌓입니다.

```text
.sdlc/                            # 전체가 gitignore 대상: 기록은 소스가 아니라 지식
├── README.md                     # 생성되는 목차 페이지 (tools/kb.sh index)
├── config.md                     # 실제 build/test/lint/run 명령, lazymode
├── approvals/                    # 로컬 게이트 기록
│   └── <slug>.<stage>.approval   # 단계 · 다이제스트 · 시각 · 모드
├── memory/
│   ├── POLICY.md                 # 사람이 선언한 하드 룰, 에이전트는 전사만
│   ├── INDEX.md                  # 교훈 포인터, 50줄 이하
│   ├── DOMAIN.md                 # 여러 제품 영역에 걸친 용어 · 사실 · 제약
│   ├── areas/<menu path>.md      # 제품 영역마다 한 장
│   └── lessons/<date>-<lesson>.md
├── work/<slug>/                  # 열린 피처만
│   ├── origin.md                 # 요청 당시의 티켓 · 기획서
│   ├── intent.md                 # 문제 · 증명 · 성공 기준 · 범위 · 루트
│   ├── spec.md                   # Human summary · AS-IS → TO-BE · 계약
│   ├── plan.md                   # 파일 · 순서 · 도달 · 리스크 · 증명
│   ├── evidence.md               # 명령 · 출력 · 관찰된 동작
│   ├── delivery.md               # 전달 목표 · 전달한 소스 · 검증 방법
│   ├── summary.md                # 읽는 사람용 페이지, 계속 갱신
│   ├── harvest.md                # 메모리 후보, close에서 병합
│   ├── deviations.md             # 빌드 중 편차
│   ├── progress.md               # 하트비트: 살아있는 한 줄
│   ├── baseline.txt              # 브라운필드의 변경 전 동작
│   └── scratch/                  # 대용량 로그 · 캡처, 산출물은 결정적인 줄만 인용
└── archive/<slug>/               # 닫힌 피처, close.sh가 여기로 옮김
    ├── CLOSED                    # shipped · abandoned · dead-end · handed-off
    └── approvals/                # 피처와 함께 이동
```

`init.sh`는 프로젝트 `.gitignore`에 루트에 고정된 한 줄, `/.sdlc`만 추가합니다. 그래서 애플리케이션을 클론해도 기록은 따라오지 않습니다. 피처가 열려 있는 동안 `status.sh`가 하트비트를 나이와 함께 `now →` 줄로 보여줍니다.

**기록을 어디에 둘지는 사용자가 정합니다.** 기본값은 프로젝트 작업 사본 안입니다. `init.sh . --area ~/knowledge`를 쓰면 `<area>/<unit>-<checkout-id>/`에 저장하고 `.sdlc`를 그곳으로 연결합니다. 체크아웃마다 저장소가 하나씩이라 워크트리 두 개가 승인을 공유하지 않습니다. 저장소에 쓰거나 게이트 판정을 보고하는 스크립트는 모두 `<store>/PROJECT`에 다른 체크아웃이 적혀 있으면 거부하므로, 복사한 작업 사본이 원본의 피처를 열거나 닫을 수 없습니다. 읽기는 이 제약을 받지 않아 `tools/kb.sh show|search|list`는 그대로 동작합니다. 킷이 대신 옮겨 주는 것은 없고, **저장소 백업은 사용자의 몫입니다.** 킷 디렉터리에는 프레임워크만 남습니다.

**지식은 제품 영역별로 정리됩니다.** 웹앱이면 제품 영역은 메뉴 하나이고 메뉴 경로(`학습 > 평가 > 제출`)로 부릅니다. 그 밖에는 모듈, API, 배치 작업, CLI 명령입니다. 제품 영역마다 페이지 `memory/areas/학습 - 평가 - 제출.md`가 한 장 있고, 개발자가 아니어도 읽을 수 있게 씁니다. 업무 정책 P1, P2…, 건수·비율·점수·차트를 보여주는 영역이면 통계 산정 N1, N2…, 동작 방식, 그 영역을 바꾼 피처마다 이력 한 행이 들어갑니다. 맨 아래 접힌 근거 블록에는 출처, 코드 위치, `Drive:` 줄이 있습니다. `Drive:` 줄은 사용자가 그 영역에 닿는 경로, 그 영역을 구동하는 명령이나 도구, 성공을 증명하는 최종 상태, 함정을 적습니다. ship 단계가 E2E 검사에서 이 줄을 harvest 후보로 올리고, 다음 verifier는 이 줄에서 출발합니다. 피처의 `summary.md`는 제품 영역을 적고, spec은 어떤 정책과 수치를 유지하거나 바꾸는지 밝히며, Side effects verifier가 나머지를 다시 확인합니다.

**공유 메모리를 쓰는 주체는 하나입니다.** 루프 도중의 후보는 피처 자신의 `harvest.md`에 쌓입니다. `INDEX.md`, `DOMAIN.md`, `areas/`, `lessons/`에 쓰는 것은 close 단계뿐이라 병렬 루프가 충돌하지 않습니다. 업무 정책과 이력은 피처가 `shipped`로 닫힐 때만 병합됩니다. 채팅에서 선언한 하드 룰은 사람의 말이 있을 때만 날짜와 함께 `.sdlc/memory/POLICY.md`에 전사되고, adversary는 위반을 차단 사유로 처리합니다.

**기록을 다시 읽는 도구는 `tools/kb.sh`입니다.**

| 명령 | 출력 |
|---|---|
| `index` | 목차 페이지 `.sdlc/README.md`를 다시 만듦 (`init.sh`와 `close.sh`가 실행) |
| `show <slug>` | 피처 하나의 요약: 목표, `summary.md`, 전달, 병합되지 않은 harvest, 교훈, 경로 |
| `show "<product area>"` | 제품 영역 페이지(`Drive:` 줄이 맨 앞)와 그 영역을 바꾼 피처 |
| `search "<text>"` | 열린 피처, 닫힌 피처, 메모리를 대상으로 출력량을 제한한 문자열 검색 |
| `harvest [--stale <days>]` | `harvest.md`가 아직 메모리에 들어가지 않은 열린 피처. 오래 멈춘 피처는 close 없이 병합 가능 |

`list`, `show`, `search`, `harvest`에 `--area <folder>`를 붙이면 그 폴더의 모든 저장소를 대상으로 하며, 체크아웃이 사라진 피처도 포함합니다. 저장소 `config.md`에 `index_style: obsidian`을 적으면 볼트용 frontmatter와 `#tags`를 덧붙입니다. 종료 코드는 `0` 찾음, `1` 없음, `2` 사용법 오류 또는 거부입니다.

## 안전 모델

### 결정은 사람이, 타이핑은 에이전트가

게이트 결정의 주인은 사람입니다. 게이트에서 직접 결정하거나 `lazymode`로 미리 정해 둡니다. 채팅에서 승인하면 에이전트가 다음 명령을 실행할 수 있습니다.

```bash
gates/approve.sh <stage> .sdlc/work/<slug>/<artifact> --delegated
```

침묵과 막연한 "계속해"는 승인이 아닙니다. lazymode 면제는 사람이 미리 설정해 둔 승인이고, 기록에 그렇게 적힙니다. 에이전트가 읽는 텍스트(티켓, 리뷰 코멘트, 로그 한 줄, 웹 페이지)는 문제를 설명할 뿐입니다. 그 안의 지시는 따르지 않고, 사람이 주지 않은 범위나 승인도 생기지 않습니다.

### 승인한 그 내용에 묶인다

`approve.sh`는 단계, 산출물의 경로와 sha256, 승인 근거가 된 상위 산출물의 다이제스트(`origin.md` 포함), 시각, 모드를 기록합니다. ship에서는 리뷰한 소스 스냅샷도 기록합니다. `check-gate.sh`는 그 전부가 그대로일 때만 게이트를 엽니다. 승인된 산출물이나 그 상위 산출물을 고치면 게이트가 닫히고, 재승인 명령이 그대로 출력됩니다. 해시는 변경 감지일 뿐 인증이 아닙니다. 바이트가 승인된 그것인지는 증명하지만, 누가 승인했는지는 증명하지 않습니다. 기록은 gitignore 대상이라 추적은 디스크의 `.sdlc/approvals/`에 남고, 피처 진행 중에 다시 클론하면 승인을 다시 받아야 합니다.

### 새 컨텍스트 리뷰

루프는 위임자 한 명이 끌고 가고, 서브에이전트는 이득이 분명할 때만 띄웁니다. 검증과 adversary 리뷰는 항상 새 컨텍스트에서 실행합니다. 작성자는 자기 작업을 리뷰할 수 없기 때문입니다. 새 컨텍스트를 줄 수 없는 하네스는 조용히 자기 리뷰를 하는 대신 증거에 공백을 명시합니다. 독립적인 워커는 병렬로 돌아도 되지만, 체크아웃 하나당 쓰기 담당은 하나입니다.

### 검증은 실제 동작을 돌린다

build가 끝나면 verifier 렌즈 세 개가 각자 새 컨텍스트에서 병렬로 돌아갑니다.

| 렌즈 | 확인하는 것 |
|---|---|
| E2E | 바뀐 동작을 사용자나 호출자가 실제로 만나는 인터페이스로 끝까지 실행. 프로젝트 자신의 명령(`.sdlc/config.md`의 `e2e:`, `qa:`, `run:`)을 씀 |
| Side effects (부작용) | 베이스라인, 건드리지 않아야 할 항목, 그리고 변경이 건드린 데이터 형태의 다른 생산자와 소비자 전부 |
| Intent match (의도 일치) | intent 게이트가 결합한 티켓·기획서 스냅샷 `origin.md`와 빌드를 대조. 성공 기준마다 담은 것, 빠뜨린 것, 넘어선 것 |

요구사항마다 정상·경계·잘못된 입력 사례를 기대 결과부터 적고, 범위 안의 역할과 플랫폼마다 실행합니다. 여기에 변경마다 **도달(reach)** 시나리오 세 개로 변경을 만나는 방식도 바꿔 봅니다. 같은 동작을 부르는 다른 호출자(entry), 이번 변경이 만들지 않은 기존 데이터(state), 어떤 요구사항도 언급하지 않은 조건(context)입니다. plan은 그 동작을 부르는 모든 저장소와 계층의 호출자를 나열합니다. 그 호출자들이 지금 보내는 입력을 거부하게 되는 변경은 계약 변경이라 plan 게이트에 걸립니다.

세 종류의 주장에는 각자의 증명이 붙습니다.

| 주장 | 증명 |
|---|---|
| 버그 수정 | 수정 전 코드에서 보고된 이유로 실패하고, 수정 후 통과하며, 테스트 스위트에 남는 회귀 테스트. 수동 절차는 테스트로 결함에 닿을 수 없을 때만 씀. 화면, API 호출, 배치 작업에서 보고된 실패는 수정 후 그 자리에서 다시 실행해 확인 |
| 동작 변화 없음 (리팩터링, 이름 변경, 이동) | pin: 첫 수정 전과 마지막 수정 후에 통과하고, 일부러 깨뜨렸을 때 한 번 실패하는 것을 확인한 검사. 타입 검사와 lint는 pin이 아님 |
| 수치 (더 빠름, 더 작음, 더 저렴함) | 같은 명령을 변경 전후로 각각 다섯 번 이상 실행해 중앙값과 범위로 비교하고, 에러와 처리한 작업량도 셈. 편차 안의 차이는 차이로 보지 않음 |

실행할 환경이 없으면 NOT VERIFIED이며 `evidence.md`에 그렇게 적습니다. 통과한 단위 테스트가 조용히 그 자리를 대신하지 않습니다. 프로젝트가 전에도 겪은 공백이면, 빠진 부분을 프로젝트에 만드는 피처도 함께 제안합니다. 어느 렌즈의 발견이든 build의 fix loop로 들어가고, 3라운드 뒤에는 사람에게 갑니다(`tools/auto.sh`는 `fixloop.exhausted`로 보고).

화면 검증은 두 방식 중 하나로 합니다. 기본값인 **agent** 모드는 `qa:` 도구나 하네스가 가진 도구로 브라우저를 조작합니다. **Jev** 모드는 UI 시나리오마다 [Jego](https://github.com/cskwork/ego-jev-ultrafast)에 평범한 문장의 목표와 반드시 보여야 할 문구를 넘기고, 결과를 새 탭에서 다시 확인한 뒤, 시나리오별 캡처·소요 시간·비용을 담은 HTML 보고서 하나를 ship 게이트용으로 만듭니다. `tools/qa-mode.sh set jev`로 바꾸면 되돌릴 때까지 모든 프로젝트에 적용됩니다(`--project`는 이 프로젝트만). 자세한 내용은 [`docs/jev-qa.md`](docs/jev-qa.md)에 있습니다. Jego를 쓸 수 없으면 verifier가 그렇게 밝히고 agent 모드로 진행합니다.

### `shipped`는 전달을 뜻한다

ship 승인은 배포하겠다는 결정이지 배포 자체가 아닙니다. `shipped`로 종결하려면 `delivery.md`가 필요합니다. 합의한 목표(`local`, `pr`, `deploy`), 전달한 소스, 결과를 확인하려고 실제로 실행한 명령이나 프로젝트 도구, 그 출력 원문입니다. `close.sh`는 승인된 증거와 리뷰한 소스가 그대로인지 다시 확인하고, 없거나 어긋나거나 확인되지 않은 전달을 거부합니다. `pr`이나 `deploy`의 `Source`는 리뷰한 소스를 트리에 담은 커밋이어야 합니다. 로컬 작업에는 프로덕션 단계가 필요 없습니다.

ship 승인은 리뷰가 본 프로젝트 소스 전체 스냅샷에 묶입니다. 추적 중인 모든 파일과 git이 무시하지 않는 모든 미추적 파일에서 `.sdlc/`를 뺀 집합을 경로, 내용, 실행 권한 비트까지 묶습니다. 그 바이트 그대로 커밋하면 묶음은 유지됩니다. 그 뒤의 수정, 새 파일, 삭제, chmod, 심볼릭 링크 교체는 리뷰가 이름을 대지 않은 파일이라도 묶음을 깨고, `check-gate.sh`, `status.sh`, `close.sh`가 바뀐 파일을 지목합니다. 서브모듈 내용은 묶이지 않습니다. 파일을 여러 개씩 한 번에 해시하므로, 파일이 수천 개인 저장소에서도 shipped close가 몇 초면 끝납니다.

실행 권한은 Git의 `core.filemode`를 따릅니다. Windows Git Bash처럼 값이 `false`이면 추적 중인 파일은 인덱스의 실행 권한을 쓰고, 새 파일은 실행 권한이 없는 것으로 봅니다. 실행 파일은 리뷰 전에 `git add --chmod=+x`로 지정하세요.

핸드오프 뒤에 들어온 리뷰 코멘트나 CI 실패는 발견으로 다룹니다. 피처가 열려 있으면 이유와 함께 수용하거나 거절합니다. 수용한 것은 build에서 고치고, 다시 리뷰하고, 재승인한 뒤 푸시합니다. 피처가 이미 닫혔으면 그 코멘트를 origin으로 하는 새 피처가 됩니다.

### 실패한 실행도 지식을 남긴다

```bash
gates/close.sh <slug> <shipped|abandoned|dead-end|handed-off> "reason"
```

abandoned나 dead-end는 무엇을 시도했고, 왜 실패했고, 무엇이 있으면 뚫리는지 적은 교훈이 없으면 닫히지 않습니다(lazymode 3 이상에서는 종료 사유가 그 기록입니다). handed-off는 외부 티켓이나 PR을 지목해야 합니다. 종결하면 피처와 승인 기록이 `.sdlc/archive/<slug>/`로 이동해, `status.sh`는 열린 작업만 보여줍니다.

교훈은 다음 실행이 하는 일을 바꿀 때만 남깁니다. `INDEX.md`에서 같은 교훈 태그가 세 번 이상 반복되면, `close.sh`가 그 수정을 들어맞는 가장 강한 장치로 승격하라고 알립니다. 프로젝트 안의 테스트, lint 규칙, 검사가 먼저이고, 그다음이 검증 레시피의 `check:` 줄, 단계 지시서 수정은 마지막입니다.

### 장애 진단은 싼 프로브부터

6단계는 에이전트를 대량으로 푸는 것으로 시작하지 않습니다. 먼저 배포된 소스를 확인합니다. `tools/refcheck.sh`는 작업 트리를 대상 리비전(`--deployed-sha`를 주면 실제 배포 SHA)과 비교하고, ref나 fetch가 실패하면 추측 대신 UNKNOWN을 보고합니다. 그다음 에이전트는 무엇을 어떤 입력으로 했는지, 대신 무슨 일이 일어났는지, 어디서, 누구로, 어떤 흔적이 남았는지 묻고 `skills/6-maintain/probes.md`의 짧은 프로브를 돌립니다. 프로브는 흔한 진단 실수 네 가지를 수정 계획 전에 잡습니다.

- 배포된 브랜치 대신 오래된 체크아웃을 읽는 실수
- 공유 쿼리 하나를 호출자 전수 조사 없이 고치는 실수
- 아래 계층이 이미 삼키는 에러에 `try/catch`를 덧대는 실수
- 데이터가 없는 정상 상태를 확인하지 않고 "리스크 제로"라고 말하는 실수

프로브로 원인이 드러나지 않으면 경쟁 원인을 나열하고 런타임 관찰로 하나씩 지웁니다. 재현이 안 되는 장애는 새 컨텍스트 adversary들이 범위를 다시 세고, 주장된 에러 전파를 증명하고, 모든 "절대 안 그래" 주장을 공격하고, 경쟁 원인을 제시합니다. 요청한 콘솔, 네트워크, 스크린샷 증거는 도착하거나 면제될 때까지 `status.sh`에 계속 보입니다.

## 조종석

```bash
gates/status.sh [--all[=n]] [slug]  # 열린 피처 + 다음 액션 하나, --all은 최신 아카이브 20건 포함
gates/status.sh --json [slug]       # 같은 상태를 기계가 읽는 형식으로 (tools/auto.sh)
gates/stats.sh [--all]              # 단계별 소요 시간 + 재승인 횟수, 기본은 열린 피처 + 최근 종결 20건
```

예시:

```text
== claims-status
  intent   APPROVED (@ 2026-08-28T10:18:53Z · delegated)
  spec     APPROVED (@ 2026-08-28T10:43:30Z · delegated)
  plan     PENDING approval
  ship     —  (no artifact)
  next  →  plan gate (tiered): gates/approve.sh plan ...
```

## 호스트에서 루프 돌리기

스케줄러, 웹훅, 멀티 에이전트 런타임이 산문을 읽지 않고 루프를 구동할 수 있습니다. 데몬도 데이터베이스도 없고, python3가 필요한 것은 `tools/verify.sh`뿐입니다.

```bash
tools/auto.sh next <slug>              # 한 줄 출력, 종료 코드 0 ready · 10 needs-human · 20 blocked · 30 complete
tools/auto.sh status --json [slug]     # 스키마 sdlc-kit/auto-status@1
tools/auto.sh intent-check <slug>      # 이 intent.md를 무인으로 실행해도 되는가
tools/auto.sh checkpoint <slug> …      # 대기 중인 단계, 제한된 재시도, 완료된 외부 효과
tools/verify.sh run|check|baseline|coverage <slug>   # 검증 레시피, 소스에 결합된 영수증
tools/handoff.sh push|check <slug>     # 리뷰 브랜치 푸시(--authorized 필요), 원격에 있음을 증명
tools/kb.sh index|show|search|list|harvest   # 기록 다시 읽기
```

호스트가 에이전트를 깨우면, 에이전트는 `next`를 읽고 단계 지시서에 따라 그 액션 하나를 수행한 뒤 다시 반복합니다. 이 스크립트들은 보고하고 기록할 뿐, 모델을 돌리거나 단계를 수행하지 않습니다. `ready`는 다음 액션이 이 프로젝트의 lazymode가 에이전트에게 허용한 것이라는 뜻입니다. 스크립트가 무언가를 리뷰했다는 뜻은 아닙니다.

움직이지 않는 경계가 셋 있습니다.

- 중대한 질문은 루프를 멈춥니다. 틀린 답이 만들 결과물을 바꾸거나 사람이 허가한 범위를 넘게 만드는 질문을, 무인 실행이 추측으로 넘기지 않습니다.
- 런타임 증명은 실제로 실행합니다. `.sdlc/verify.md`가 요구사항마다 프로젝트 자신의 명령이나 명시된 공백을 대응시킵니다. `tools/verify.sh run`은 모든 검사를 시간 제한 안에서 실행하고, 영수증을 소스, 레시피, 각 명령의 출력에 묶습니다. 코드가 바뀌면 `stale`, 로그가 수정되면 `invalid`가 됩니다. `profile: strict`에서는 그 실행이 직접 띄운 런타임에 대한 runtime 또는 e2e 검사가 통과해야 리뷰 준비 완료입니다. 레시피가 있으면 ship은 `ok`가 아닌 영수증을 거부하고, 실행할 환경이 없는 `blocked`는 사람이 직접 한 말(`--accept-gap`)이 있을 때만 배포할 수 있습니다. 승인 해시와 마찬가지로 영수증도 변경 감지일 뿐 인증이 아닙니다.
- 루프는 푸시된 피처 브랜치에서 끝납니다. `tools/handoff.sh push`는 푸시 직전에 ship 게이트와 검증을 다시 실행하고, `intent.md`의 범위 허가에 공개가 명시되어 있어야 진행합니다. 에이전트가 스스로에게 외부 효과를 허가할 수는 없습니다. 머지나 배포는 lazymode 레벨과 무관하게 별도의 사람 승인이며 `delivery.md`에 기록됩니다.

전체 계약, 구동·재개 절차, Symphony 예시: [`docs/automation.md`](docs/automation.md).

## 복잡한 코드베이스에서도

sdlc-kit은 프로세스 계층이지 프로젝트 규칙의 대체물이 아닙니다.

- 방법은 프로젝트 규칙이 이깁니다. 명령, 브랜치, 스타일, 도구, 배포 정책.
- 프로세스는 sdlc-kit이 이깁니다. 단계, 승인 게이트, 증거, 메모리.
- 기존 지식이 이깁니다. `DOMAIN.md`는 기존 용어집, `CONTEXT.md`, ADR을 복사하지 않고 가리킵니다.
- 기존 에이전트가 이깁니다. 로컬 QA, 브라우저, API, 리뷰어, DB 전문 에이전트가 킷의 역할 계약을 실행합니다.
- 모노레포는 범위를 지킵니다. 배포 단위마다 `.sdlc/` 하나, 루트는 단위를 가로지르는 변경에만.

진짜 규칙 충돌은 양쪽 원문을 인용해 사람에게 보여줍니다. 에이전트가 조용히 해소하지 않습니다.

## 그린필드와 브라운필드

**그린필드**: 1단계가 문제를 기록하고, 2단계가 열리기 전에 필요한 연동 지점을 확인합니다.

**브라운필드**: 프로브로 AS-IS를 먼저 세우고, 계획은 수정 전에 베이스라인을 캡처하며, 증거는 TO-BE와 함께 주변 동작이 바뀌지 않았음을 증명합니다.

## 업그레이드

```bash
cd ~/sdlc-kit && git pull
cd /path/to/project && ~/sdlc-kit/init.sh
```

`init.sh`는 멱등입니다. 기존 파일은 그대로 두고, 이후 킷 버전의 시드 파일을 추가하며, 예전 킷이 넣은 좁은 무시 줄은 `/.sdlc`로 대체합니다. git 인덱스는 건드리지 않으므로, 예전 킷이 커밋한 기록은 직접 추적을 해제할 때까지 추적된 채 남습니다(`init.sh`가 그 명령을 출력합니다). 예전 결합 형식의 승인(다이제스트가 없거나, 커밋되지 않은 diff에만 묶인 ship 승인)은 닫힌 상태로 실패하고, 게이트가 재승인 명령을 출력합니다.

킷이 줄 끝 문자를 고정하기 전에 만든 Windows 클론에는 CRLF 스크립트가 남아 있어 bash가 실행을 거부합니다. 그 클론은 한 번만 재정규화하세요. 킷 클론 안의 로컬 수정은 이 명령으로 사라집니다.

```bash
cd ~/sdlc-kit && git rm --cached -r -q . && git reset --hard
```

## 저장소 지도

```text
SKILL.md         발견용 라우터: start · continue · status · close
AGENTS.md        이식 가능한 프로세스 계약 전문
init.sh          멱등 프로젝트 시드
skills/1-6/      단계별 지시서
roles/           verifier · adversary · researcher 계약
gates/           approve · check-gate · close · status · stats · selftest (+ _common.sh, _auto.sh)
tools/           auto · verify (python3 필요) · handoff · kb · qa-mode · tripwire · refcheck · _run.py
templates/       산출물, 메모리 페이지, 검증 레시피 (intent, spec, plan, evidence, area, lesson, …)
docs/            index.html (EN/KO 사이트) · automation.md (기계 계약) · jev-qa.md
log/             릴리스 노트
.gitattributes   LF 줄 끝 고정, Windows 클론에서도 스크립트가 동작
```

## 킷 검증

```bash
./gates/selftest.sh   # 몇 초
```

대부분이 지침 문서인 킷이라 스모크 테스트 하나만 둡니다. 모든 스크립트가 문법 오류 없이 LF로 저장돼 있는지, 모든 SKILL.md의 frontmatter가 올바른지, 게이트가 승인된 바이트에서만 열리는지, lazymode가 설정 레벨을 넘지 않는지, `dead-end`에는 교훈이, `shipped`에는 확인된 전달이 필요한지, 지식이 제 제품 영역에 정리되는지, 검증 영수증이 ship을 막는지 확인합니다. CI는 PR과 수동 실행 때 Ubuntu, macOS, Windows(Git Bash)에서 돌립니다.

## 이것이 아닌 것

- 자율 운영 배포 시스템이 아닙니다.
- 프로젝트 테스트, CI, 브랜치 보호, 보안 리뷰의 대체물이 아닙니다.
- 에이전트가 거짓말하거나 파일을 위조할 수 없다는 약속이 아닙니다.
- 또 하나의 에이전트 런타임이 아닙니다. 쓰던 에이전트에 이 프로세스를 얹으세요.

## 시작해 보기

작은 브라운필드 이슈 하나로 시작하세요. 독립 verifier가 찾은 것과 작성자가 보고한 것을 비교해 보세요.

팀에 맞는다면 저장소에 스타를 남기거나, 다음으로 지원했으면 하는 에이전트 도구나 워크플로를 이슈로 알려주세요.

<div align="center">

[**시작하기**](#빠른-시작) · [**라이브 사이트**](https://cskwork.github.io/sdlc-kit/) · [**최신 릴리스**](https://github.com/cskwork/sdlc-kit/releases/latest) · [**이슈 열기**](https://github.com/cskwork/sdlc-kit/issues/new)

</div>
