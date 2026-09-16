<div align="center">

# sdlc-kit

### 코딩 에이전트가 자기 숙제를 자기가 채점하게 두지 마세요.

**AI 코딩 에이전트를 위한 이식 가능한 SDLC.**

Intent → spec → plan → build → evidence → maintain. 사람 승인 게이트, 새 컨텍스트 리뷰, 다음 실행을 위한 교훈이 함께 돕니다.

[![Release](https://img.shields.io/github/v/release/cskwork/sdlc-kit?style=flat-square&color=C79A55)](https://github.com/cskwork/sdlc-kit/releases/latest)
[![GitHub Pages](https://img.shields.io/badge/live_site-open-C79A55?style=flat-square)](https://cskwork.github.io/sdlc-kit/)
[![Harness neutral](https://img.shields.io/badge/harness-pi_%C2%B7_Claude_Code_%C2%B7_Codex_%C2%B7_Gemini-24211E?style=flat-square)](#빠른-시작)

[**라이브 사이트**](https://cskwork.github.io/sdlc-kit/) · [**60초 설치**](#빠른-시작) · [**계약 전문 읽기**](AGENTS.md) · [**English**](README.md)

</div>

---

코딩은 이제 빠릅니다. **틀리는 비용은 그대로 비쌉니다.**

흔한 에이전트 워크플로는 구현부터 시작합니다. 프롬프트를 받고, 코드를 쓰고, 테스트를 돌리고, 요청이 명확했다고 가정합니다. sdlc-kit은 명확화와 증거를 앞으로 당기고, 루프 내내 독립 검증을 유지합니다.

- 에이전트는 질문하기 전에 먼저 조사합니다.
- `intent.md`의 모든 주장에 `[verified]` 또는 `[assumed]` 라벨이 붙습니다.
- 새 컨텍스트의 adversary가 스펙을 먼저 공격한 뒤에 사람이 승인합니다.
- 평범한 계획은 adversary 리뷰만 통과하면 자동 승인됩니다. 마이그레이션, 삭제, API, 보안, 인프라 변경은 사람에게 올라옵니다.
- 구현은 작성자가 아닌 별도의 verifier가 승인된 산출물과 대조합니다.
- 실패한 시도는 교훈과 도메인 지식으로 남아 다음 실행을 돕습니다.

[Anthropic의 AI-Native SDLC 플레이북](https://claude.com/blog/the-ai-native-sdlc-playbook)을 옮긴 것이지만 Claude Code에 묶여 있지 않습니다. 구현체는 순수 Markdown과 셸 스크립트입니다. 파일을 읽고 명령을 실행할 수 있는 하네스라면 어디서든 돌아갑니다.

> sdlc-kit은 독립 프로젝트이며 Anthropic과 무관합니다.

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

각 단계는 리뷰 가능한 산출물 하나를 만듭니다. intent, spec, ship 게이트는 사람의 결정입니다. 채팅에서 승인하면 에이전트가 승인 명령을 대신 실행할 수 있고, 기록에는 `mode: delegated-chat`으로 남습니다. plan 게이트는 층이 나뉩니다. 새 컨텍스트 adversary가 모든 계획을 리뷰하고, 평범한 계획은 자동 승인되며(`mode: agent-adversary`), 트립와이어에 걸리는 계획은 사람 게이트가 됩니다. 트립와이어는 마이그레이션, 데이터 삭제, 공개 API, 보안 경로, 인프라와 설정, 스펙 밖 범위입니다.

`lazymode`는 그 사람/자동 경계를 옮깁니다. `init.sh`가 `.sdlc/config.md`에 `lazymode: 1`을 심고, 에이전트가 원하는 레벨을 물어봅니다. 레벨별로 사람이 쥐는 게이트는 이렇습니다. **0** intent, spec, plan 트립와이어, ship(설계 그대로 전부) · **1**(기본) intent, spec, ship · **2** intent, ship · **3** intent · **4** 없음, 루프가 자율로 돕니다. 면제된 게이트는 `gates/approve.sh <stage> <artifact> --lazy --review "<무엇을 리뷰했는지>"`로 자동 승인되고, `mode: lazy`와 리뷰 기록이 함께 남습니다. **lazymode가 옮기는 것은 "누가 결정하는가"뿐입니다.** 리뷰 자체나 권한은 면제되지 않습니다. 면제된 게이트도 영향 받는 코드와 동작을 실제로 리뷰해야 하고, 위험한 작업(데이터 손실, 공개 API, 보안 경로, 마이그레이션, 외부 배포)은 어느 레벨에서든 사람이 미리 허가한 사실이 `--risk-authorized`로 기록되어야 합니다. `tripwire.sh`는 영어 키워드 스캔이라 보조 수단일 뿐입니다. 걸리면 요구 조건이 늘어나지만, 깨끗하다고 해서 아무것도 면제되지 않습니다. 승인은 여전히 기록되고, `approve.sh --lazy`는 설정 레벨이 사람에게 남긴 게이트를 거부합니다.

배포된 변경이 실패하면 Maintain 단계가 진단하고 다음 `intent.md`를 씁니다.

모든 티켓이 6단계를 다 도는 것은 아닙니다. 작고 파악이 끝난 변경 — 수정할 파일과 심볼 확정, 기존 명령으로 성공 검증 가능, 미결 질문 없음, 이미 허가받은 범위 안 — 은 **컴팩트 루트**를 탑니다. 작업 산출물은 `intent.md` 하나이고(파일 · 증명 · 위험 · 전달 목표를 함께 담습니다), intent(게이트) → build → ship로 바로 가며, ship의 adversary 리뷰가 diff의 유일한 리뷰가 됩니다(intent.md에 `Track: compact`, 예전 표기 `micro`도 그대로 인식, 기준은 `skills/1-intent`). 장애 대응도 같은 컴팩트 루트를 씁니다. 별도의 압축 루프는 없습니다. 모호하거나 범위가 넓거나 위험한 일은 풀 루트로 가고, 도중에 승격하면 지름길을 허가했던 intent 승인을 다시 받습니다. 반대로 한 번에 파악이 안 되는 티켓은 **map**(`map.md`: 목적지 · 정한 것 · 모르는 것 · 안 할 것)부터 만들고, 세션마다 미결 하나씩 풀어 intent.md를 쓸 수 있을 때까지 진행합니다.

루프 도중의 교훈·도메인 후보는 피처 자신의 `harvest.md`에만 쌓입니다. 공유 메모리(`INDEX.md`, `DOMAIN.md`, `lessons/`)를 쓰는 주체는 close 단계 하나뿐이라 병렬 루프가 충돌하지 않습니다. 채팅에서 선언한 하드 룰은 — 사람의 말이 있을 때만, 날짜와 함께 — `.sdlc/memory/POLICY.md`에 전사되고, adversary는 위반을 차단 사유로 처리합니다.

## 무엇이 다른가

| 흔한 에이전트 워크플로 | sdlc-kit |
|---|---|
| 첫 요청부터 코딩 시작 | 히스토리, 코드, 실현 가능성, 브라우저, API, DB를 먼저 뒤진 뒤에 사용자를 심문 |
| 사용자의 진단을 사실로 취급 | 주장마다 `[verified: 증거]` 또는 `[assumed: 이유]` 라벨 |
| 계획이 채팅 안에만 존재 | 지속 기록(`intent.md`, `spec.md`, `plan.md`, `evidence.md`, `delivery.md`)을 코드와 함께 커밋, 대용량 로그는 `scratch/`에 보존 |
| 작성자가 자기 검사를 직접 실행 | 작성자 컨텍스트가 없는 verifier와 adversary가 리뷰 |
| 승인이 사라지는 채팅 메시지 | 승인 기록이 단계, 산출물, 시각, 모드를 담고 `.sdlc/approvals/`에 파일로 남음 |
| 실패한 시도는 잊힌 컨텍스트가 됨 | 교훈은 상한 있는 인덱스로, 확인된 사실은 `DOMAIN.md`로 |
| 만능 워커 하나가 전부 수행 | 로컬 QA, 리뷰어, 브라우저, API, DB 전문 에이전트가 있으면 역할 계약을 그쪽에 위임 |
| "끝났다"가 모호함 | 모든 실행이 `shipped`, `abandoned`, `dead-end`, `handed-off` 중 하나로 종결되고, `shipped`는 승인만으로는 부족하며 검증된 전달 기록을 요구 |

## 빠른 시작

`bash`, `git`, coreutils가 필요합니다. macOS와 Linux에는 이미 있습니다. Windows에서는 [Git for Windows](https://gitforwindows.org/)에 포함된 **Git Bash**나 WSL을 쓰고, 에이전트가 실행하는 것까지 모든 킷 명령을 거기서 돌리세요. PowerShell과 cmd로는 스크립트가 실행되지 않습니다.

```bash
# 1. 한 번 설치
git clone https://github.com/cskwork/sdlc-kit ~/sdlc-kit

# 2. 프로젝트(또는 모노레포의 배포 단위 하나)에 시드
cd /path/to/your-project
~/sdlc-kit/init.sh

# 3. 프로젝트의 실제 증명 명령 채우기
$EDITOR .sdlc/config.md
```

그다음 하네스가 라우팅 계약을 읽게 하세요.

| 하네스 | 프로젝트 지시문 |
|---|---|
| **pi** | 프로젝트 `AGENTS.md`에 추가: `For SDLC work, read ~/sdlc-kit/AGENTS.md and follow it.` |
| **Claude Code** | 같은 포인터를 `CLAUDE.md`에 |
| **Codex CLI** | 같은 포인터를 `AGENTS.md`에 |
| **Gemini CLI** | 같은 포인터를 `GEMINI.md`에 |
| **Cursor / 기타** | 하네스가 읽는 지시 파일에 포인터를 넣거나, 세션에 `AGENTS.md`를 붙여넣기 |

이제 이렇게 말하면 됩니다.

```text
Start SDLC for <기능, 버그, 변경>
```

에이전트가 1단계로 라우팅해서 프로젝트를 탐색하고, 증거가 붙은 질문을 한 번에 하나씩 던집니다.

## 60초 예시

```text
you    Start SDLC for claims status self-service
agent  현재 API, UI 흐름, git 히스토리, 테스트 하네스를 확인했습니다.
       요청 속 주장 하나가 사실과 다릅니다. 증거는 이렇습니다...

       [심문이 한 질문씩 이어짐]

agent  intent.md가 준비됐습니다. Human summary를 검토하세요.
you    approve
agent  APPROVED: intent of claims-status (.sdlc/work/claims-status/intent.md)
       mode: delegated-chat

       2단계는 승인된 산출물에서 이어집니다.
```

숨은 상태가 없습니다. 벤더 전용 훅도 필요 없습니다. 파일이 곧 프로토콜입니다.

## 무엇이 만들어지나

기능 하나당, **대상 프로젝트** 안에 이렇게 쌓입니다.

```text
.sdlc/
├── config.md                         # 실제 build/test/lint/run 명령
├── approvals/                        # gitignore 대상
│   └── <slug>.<stage>.approval       # 단계 · 시각 · 모드
├── memory/
│   ├── POLICY.md                     # 사람이 선언한 하드 룰, 에이전트는 전사만
│   ├── INDEX.md                      # 교훈 포인터, 50줄 이하
│   ├── DOMAIN.md                     # 용어 · 확인된 사실 · 제약
│   └── lessons/<date>-<lesson>.md
├── work/<slug>/                      # 열린 피처만
│   ├── intent.md                     # 문제 · 증명 · 성공 기준 · 범위
│   ├── spec.md                       # Human summary · AS-IS → TO-BE · 계약
│   ├── plan.md                       # 파일 · 순서 · 리스크 · 증명
│   ├── evidence.md                   # 명령 · 출력 · 관찰된 동작
│   ├── delivery.md                   # 전달 목표 · 전달한 소스 · 검증 방법
│   ├── deviations.md                 # 빌드 중 편차 기록 — gitignore 대상
│   ├── progress.md                   # 하트비트: 살아있는 한 줄, gitignore 대상 (규칙 9)
│   ├── baseline.txt                  # 브라운필드의 변경 전 동작 — gitignore 대상
│   ├── harvest.md                    # 루프 중 교훈·도메인 후보, close에서 병합 — gitignore 대상
│   └── scratch/                      # 대용량 로그 · 캡처 · 트레이스 — gitignore 대상
└── archive/<slug>/                   # 닫힌 피처, close.sh가 여기로 옮김
    ├── CLOSED                        # shipped · abandoned · dead-end · handed-off
    └── approvals/                    # 피처의 승인 기록도 함께 이동, 여전히 gitignore 대상
```

`init.sh`는 프로젝트 `.gitignore`에 열두 줄을 추가합니다. `work/`와 `archive/` 양쪽의 `approvals/`, `baseline.txt`, `deviations.md`, `harvest.md`, `scratch/`, `progress.md`입니다. git에 남는 것은 지속 기록입니다. `config.md`, `memory/`, 그리고 피처마다 `intent.md`, `spec.md`, `plan.md`, `map.md`, `evidence.md`, `delivery.md`, 아카이브의 `CLOSED`. 결정과 최종 증거는 작업 사본 없이도 1년 뒤에 읽을 수 있어야 하기 때문입니다. 대용량 출력은 `scratch/`에 남고 evidence.md는 결정적인 줄만 인용합니다. 예전 킷으로 심은 프로젝트에서 `init.sh`를 다시 돌리면 그때 추가했던 `spec.md`·`evidence.md` 무시 줄을 제거하며, git 인덱스는 건드리지 않습니다. 피처가 열려 있는 동안 `status.sh`가 하트비트를 나이와 함께 `now →` 줄로 보여주며, `watch -n5 cat .sdlc/work/<slug>/progress.md`로 실시간 추적할 수 있습니다.

공개 sdlc-kit 저장소는 프레임워크만 담습니다. 커밋되는 산출물(intent, plan, map, memory)은 그것이 설명하는 프로젝트 안에서 함께 버전 관리됩니다. 무시되는 나머지는 그것을 만든 작업 사본 안에만 남습니다.

## 안전 모델

### 결정은 사람이, 타이핑은 에이전트가

게이트 결정의 주인은 사람입니다. 게이트에서 직접 결정하거나, `.sdlc/config.md`의 `lazymode`로 미리 정해 둡니다. 채팅에서 명시적으로 승인하면 에이전트가 대신 실행할 수 있습니다.

```bash
gates/approve.sh <stage> .sdlc/work/<slug>/<artifact> --delegated
```

승인 기록은 명시적으로 남습니다. 침묵과 막연한 "계속해"는 승인이 아닙니다. lazymode 면제는 사람이 미리 설정해 둔 승인이고, 기록에 그렇게 적힙니다.

### 승인한 그 내용에 묶인다

`approve.sh`는 단계, 정규화된 `.sdlc/work/<slug>/<artifact>` 경로, 그 산출물의 sha256, 승인 근거가 된 상위 산출물들의 다이제스트, 시각, 모드를 기록하고, ship 단계에서는 리뷰한 소스 스냅샷까지 함께 묶습니다(기록 옆 `<slug>.ship.source`에 남습니다). `check-gate.sh`는 그 전부가 그대로일 때만 게이트를 엽니다. 승인된 산출물을 고치거나 상위 산출물을 실질적으로 다시 쓰면 게이트가 닫히고, 재승인 명령이 그대로 출력됩니다. 해시는 변경 감지일 뿐 인증이 아닙니다. 바이트가 승인된 그것인지는 증명하지만, 누가 승인했는지는 증명하지 않습니다. 다이제스트가 없는 예전 킷의 기록은 같은 안내와 함께 닫힌 상태로 실패합니다. 이 기록은 gitignore 대상이라, 추적은 git 히스토리가 아니라 디스크의 `.sdlc/approvals/` 디렉토리(닫힌 피처는 `.sdlc/archive/<slug>/approvals/`로 이어짐)입니다. `status.sh`와 `stats.sh`는 그 파일을 직접 읽으므로 게이트 상태와 재승인 횟수는 그대로 나옵니다. 달라지는 것은 지속성입니다. 새로 클론하면 승인 기록이 따라오지 않아, 피처를 진행하던 중에 다시 클론하면 승인을 다시 받아야 합니다. 추적의 정직함은 에이전트 규칙과 디스크에 남은 그 기록에서 나옵니다.

### 새 컨텍스트 리뷰

루프는 기본적으로 위임자 한 명이 끌고 갑니다. 단계마다 서브에이전트를 띄우는 것은 의무가 아니고, 이득이 분명할 때만 씁니다. 대신 절대 생략하지 않는 것이 있습니다. 검증과 adversary 리뷰는 새 컨텍스트에서 돌아야 합니다. 작성자가 자기 작업을 리뷰할 수는 없기 때문입니다. 하네스가 새 컨텍스트를 줄 수 없으면, 조용히 자기 리뷰를 하는 대신 증거에 공백으로 명시합니다. 독립적인 워커는 병렬로 돌아도 됩니다. 체크아웃 하나당 쓰기 담당은 하나입니다.

### `shipped`는 전달을 뜻한다

ship 승인은 배포하겠다는 결정이지 배포 자체가 아닙니다. `shipped`로 종결하려면 `delivery.md`가 필요합니다. 합의한 목표(`local`, `pr`, `deploy`), 전달한 소스, 결과를 확인하려고 실제로 실행한 명령이나 프로젝트 도구, 그리고 그 출력 원문입니다. `close.sh`는 ship 승인을 다시 확인하고(승인된 증거 그대로, 리뷰한 소스 그대로) 없거나 어긋나거나 확인되지 않은 전달을 거부합니다. `pr`이나 `deploy`의 `Source`는 리뷰한 소스를 실제로 담고 있는 커밋이어야 합니다. close가 그 커밋의 트리를 리뷰 스냅샷과 비교하므로, 그냥 존재하기만 하는 커밋은 거부됩니다. 로컬 작업에는 프로덕션 단계가 필요 없습니다.

ship 승인이 묶는 것은 리뷰가 본 프로젝트 소스 전체 스냅샷입니다. 추적 중인 모든 파일과 git이 무시하지 않는 모든 미추적 파일에서 `.sdlc/`를 뺀 집합을, 경로·내용·실행 권한 비트까지 함께 묶습니다. 그 바이트 그대로 스테이징하거나 커밋하는 것은 묶음을 깨지 않고, 리뷰 시점에 이미 커밋되어 있던 작업도 함께 묶입니다. 반면 리뷰 후의 수정, 새 파일 추가, 삭제, chmod, 심볼릭 링크 교체는 묶음을 깹니다. 리뷰가 이름을 대지 않은 파일이라도 마찬가지입니다. `check-gate.sh`, `status.sh`, `close.sh`가 같은 표현으로 알리고 바뀐 파일을 지목합니다. 예전 킷이 남긴 ship 승인은 커밋되지 않은 diff만 묶었으므로, 그 사실을 밝히며 닫힌 상태로 실패합니다. 서브모듈 내용은 묶이지 않습니다. git이 C-quote로 감싸 출력하는 경로명 — 탭, 개행, 큰따옴표, 백슬래시가 든 이름 — 은 묶을 수 없습니다. `approve.sh ship`은 그 이름을 지목하며 승인을 거부하고, 리뷰 뒤에 그런 파일이 생기면 이름을 바꾸거나 무시 목록에 넣을 때까지 게이트를 invalid source로 닫습니다. 유니코드와 공백이 든 이름은 정상 동작합니다.

실행 권한은 Git의 `core.filemode` 설정에 따라 판단합니다. Windows Git Bash처럼 값이 `false`이면 추적 중인 파일은 Git 인덱스의 실행 권한을 사용하고 새 파일은 실행 권한이 없는 것으로 처리합니다. 실행 파일로 지정하려면 리뷰 전에 `git add --chmod=+x` 또는 `git update-index --chmod=+x`를 사용하세요. 리뷰 후 인덱스의 실행 권한을 바꾸면 승인이 무효화됩니다. `core.filemode=true`인 환경에서는 파일 시스템의 chmod 변경을 직접 검사합니다.

그 전에 검증은 실제 동작을 돌립니다. 바뀐 동작을 사용자나 호출자가 실제로 만나는 인터페이스로 끝까지 실행하되, 변경 범위에 맞춰 프로젝트 자신의 명령(`.sdlc/config.md`의 `e2e:`, `qa:`, `run:`)을 씁니다. 실행할 환경이 없으면 NOT VERIFIED이며 evidence.md에 그렇게 적습니다. 통과한 단위 테스트가 조용한 대체물이 되는 일은 없습니다.

### 실패한 실행도 지식을 남긴다

```bash
gates/close.sh <slug> <shipped|abandoned|dead-end|handed-off> "reason"
```

abandoned나 dead-end는 교훈이 없으면 닫히지 않습니다(lazymode 3 이상에서는 필수 입력인 종료 사유가 기록을 대신합니다). 무엇을 시도했고, 왜 실패했고, 무엇이 있으면 뚫리는지를 적습니다. handed-off는 외부 티켓이나 PR을 반드시 지목해야 합니다. 감사 추적이 킷 밖에서도 끊기지 않게 하기 위해서입니다. 종결은 곧 아카이브입니다. 피처 디렉토리와 승인 기록이 `.sdlc/archive/<slug>/`로 이동해 `status.sh`는 열린 작업만 보여줍니다.

### 장애 진단은 싼 프로브부터

6단계는 에이전트를 대량으로 풀지 않습니다. 배포된 소스를 먼저 확인합니다. `refcheck.sh`는 작업 트리의 내용을 스테이징·비스테이징·미추적까지 모두 대상 리비전과 비교하고, 릴리스 시스템이 알려주는 실제 배포 SHA가 있으면 `--deployed-sha`로 받고, ref나 fetch가 실패하면 추측 대신 UNKNOWN을 보고합니다. 그다음 어떤 통제가 뚫렸는지 묻고, 요청한 재현 증거를 추적하고, `skills/6-maintain/probes.md`의 짧은 프로브를 돌립니다.

프로브는 수정 계획에 도달하기 전에 흔한 진단 실수 네 가지를 잡습니다.

- 배포된 브랜치 대신 오래된 체크아웃을 읽는 실수
- 공유 쿼리 하나를 호출자 전수 조사 없이 고치는 실수
- 아래 계층이 이미 삼키는 에러에 `try/catch`를 덧대는 실수
- 데이터 없는 정상 상태를 확인하지 않고 "리스크 제로"라고 말하는 실수

재현이 안 되는 장애는 새 컨텍스트 adversary들이 범위를 다시 세고, 주장된 에러 전파를 증명하고, 모든 "절대 안 그래" 주장을 공격하고, 경쟁 원인을 제시합니다. 받지 못한 콘솔, 네트워크, 스크린샷 증거는 사람이 받거나 면제할 때까지 `status.sh`에 계속 보입니다.

## 조종석

```bash
gates/status.sh [--all[=n]] [slug]  # 열린 피처 + 다음 액션 하나, --all은 최신 아카이브 20건 포함
gates/status.sh --json [slug]       # 같은 상태를 기계가 읽는 형식으로(tools/auto.sh)
gates/stats.sh [--all]              # 단계별 소요 시간 + 재승인 횟수, 기본은 열린 피처 + 최근 종결 20건
gates/selftest.sh        # 게이트, 종결, 인젝션, lazymode, status 렌더, YAML 무결성
gates/e2e.sh [kit]       # 일회용 git 픽스처에서 루프 전체를 검사(로컬 전용, 원격 호출 없음)
gates/autotest.sh [kit]  # 자동화 계층을 자체 픽스처에서 검사(로컬 bare 원격, 네트워크 없음)
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

## 호스트에서 루프 돌리기 (v0.10.0)

스케줄러, 웹훅, 멀티 에이전트 런타임이 산문을 파싱하지 않고 루프를 구동할 수 있습니다.
데몬도, 데이터베이스도, 새 의존성도 없는 작은 스크립트 네 개입니다.

```bash
tools/auto.sh next <slug>              # 한 줄 출력, 종료 코드 0 ready · 10 needs-human · 20 blocked · 30 complete
tools/auto.sh status --json [slug]     # 스키마 sdlc-kit/auto-status@1
tools/auto.sh intent-check <slug>      # 이 intent.md를 무인으로 실행해도 되는가
tools/auto.sh checkpoint <slug> …      # 대기 중인 단계, 제한된 재시도, 완료된 외부 효과
tools/verify.sh run|check <slug>       # 프로젝트의 검증 레시피 실행(python3 필요), 소스에 결합된 영수증 기록
tools/handoff.sh push|check <slug>     # 리뷰용 브랜치가 원격에 실제로 있음을 증명
```

호스트가 에이전트를 깨우면, 에이전트는 `next`를 읽고 단계 지시서에 따라 그 액션 하나를
수행한 뒤 다시 반복합니다. 이 스크립트들은 보고하고 기록할 뿐, 모델을 돌리거나 단계를
수행하지 않습니다. `ready`는 "다음 액션이 이 프로젝트의 lazymode가 에이전트에게 허용한
것"이라는 뜻이지, 셸 스크립트가 코드를 리뷰했다는 뜻이 아닙니다.

움직이지 않는 경계가 셋 있습니다.

- **중대한 질문은 루프를 멈춥니다.** 틀린 답이 만들 물건을 바꾸거나 사람이 허가한 범위를
  벗어나게 하는 질문을, 무인 실행이 진도를 위해 추측으로 넘기지 않습니다.
- **런타임 증명은 주장하는 것이 아니라 실행하는 것입니다.** `.sdlc/verify.md`가 요구사항마다
  프로젝트 자신의 명령을 지정하고, `tools/verify.sh`가 설정된 모든 검사를 실행합니다 —
  시간 제한이 걸린 채, stdin은 닫힌 채, 각각 자기 프로세스 그룹에서. 영수증은 결과를
  실행 전후의 소스·레시피·각 명령의 출력 해시에 묶습니다. 코드가 바뀌면 `stale`,
  인용한 로그가 사라지거나 수정되면 `invalid`가 됩니다. `profile: strict`에서는 그 실행이
  직접 띄운 런타임에 대한 runtime/e2e 검사가 통과하지 않으면 리뷰 준비 완료가 아니며,
  유닛 테스트 통과가 그 자리를 대신하지 않습니다. 영수증은 **변경 탐지**이지 인증이
  아닙니다: 실행되지 않았거나 나중에 고쳐진 증거를 드러낼 뿐, 누가 만들었는지는 말하지
  않습니다.
- **루프는 푸시된 피처 브랜치에서 끝납니다.** `tools/handoff.sh push`는 푸시 직전에
  ship 게이트 전체(`gates/check-gate.sh ship`)와 검증을 다시 실행하고, `intent.md`에
  기록된 승인 범위가 브랜치 공개를 실제로 명시할 때만 진행합니다 — 에이전트가 스스로에게
  외부 효과를 허가할 수는 없습니다. 그 브랜치를 머지하거나 배포하는 것은 lazymode와
  무관하게 별도의 사람 승인이며 `delivery.md`에 기록되고, 킷이 여기서 검증할 수 있는
  사실이 아닙니다.

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

**브라운필드**: 히스토리, 코드 그래프, 실현 가능성, 필요하면 브라우저/API/DB 프로브로 AS-IS를 먼저 세웁니다. 계획은 수정 전에 baseline을 캡처합니다. 증거는 TO-BE와 함께, 옆 동작이 안 바뀌었음도 증명합니다.

## 업그레이드

```bash
cd ~/sdlc-kit && git pull
cd /path/to/project && ~/sdlc-kit/init.sh
```

`init.sh`는 멱등입니다. 기존 파일은 그대로 두고, 새 버전의 시드 파일만 추가합니다.

킷이 줄 끝 문자를 고정하기 전에 만든 Windows 클론에는 CRLF 스크립트가 남아 있어 bash가 실행을 거부합니다. 그 클론은 한 번만 재정규화하세요.

```bash
cd ~/sdlc-kit && git rm --cached -r -q . && git reset --hard
```

킷 클론 안의 로컬 수정은 이 명령으로 사라집니다.

## 저장소 지도

```text
SKILL.md         발견용 라우터: start · continue · status · close
AGENTS.md        이식 가능한 프로세스 계약 전문
init.sh          멱등 프로젝트 시드
.gitattributes   LF 고정, Windows 클론에서도 스크립트 생존
skills/1-6/      단계별 지시서
roles/           verifier · adversary · researcher 계약
gates/           approve · check · close · status · stats · selftest · e2e · autotest (공용 헬퍼 _common.sh, _auto.sh 포함)
tools/           auto(기계 상태) · verify(영수증, python3 필요) · handoff(리뷰 브랜치) · _run.py(제한된 실행) · tripwire · refcheck
templates/       intent · spec · plan · evidence · delivery · verify · lesson
docs/index.html  EN/KO 랜딩 페이지
docs/automation.md  기계 계약: status JSON, 영수증, 핸드오프, 체크포인트
```

## 킷 검증

```bash
./gates/selftest.sh   # 게이트 동작
./gates/e2e.sh        # 자체 일회용 픽스처에서 루프 전체
./gates/autotest.sh   # 자체 일회용 픽스처에서 자동화 계층
```

셀프테스트는 게이트 상태와 경로·내용 결합(다른 경로 재사용, 경로 이탈, 심볼릭 링크, 결합 이전 기록은 모두 닫힌 상태로 실패), 단계명 인젝션, 경로 이탈 거부, delegated와 lazy 승인 및 그 리뷰·위험 허가 기록, 컴팩트 루트와 승격 시 재승인, 전달 기록을 요구하는 `shipped` 종결, `refcheck.sh`의 드리프트 감지, 종결 시 교훈 요구, 이중 종결 거부, 종결 시 아카이브(승인 기록 이동과 status 범위 포함), YAML 프런트매터 파싱, 전체 스크립트의 LF 줄 끝을 검사합니다. 여기에 엔드투엔드 워크플로 픽스처 두 가지 — 컴팩트 버그 수정의 intent부터 전달 종결까지, 그리고 그 주변 실패 경로 — 가 함께 돌고, 리뷰 전에 이미 커밋된 작업의 소스 결합과 `pr` 전달의 커밋 포함 여부 검사도 포함됩니다.

`gates/autotest.sh`는 같은 원칙으로 자동화 계층을 검사합니다. 풀오토 intent 계약(중대한 질문은
막고, 해결되면 풀린다), 검증 영수증(검사 실패, 영수증 없음, runtime 증거 없는 strict 프로파일,
코드·명령·레시피가 바뀐 경우 모두 차단), 로컬 bare 원격을 상대로 한 리뷰 핸드오프(허가 없는 푸시,
보호 브랜치, force, 리뷰된 소스를 담지 않은 커밋은 거부, 두 번째 푸시는 아무 효과도 반복하지 않음,
원격 SHA가 다르면 리뷰 준비 완료가 차단, 머지·배포는 `Authorized-by:` 필요), 제한된 재시도와 재개,
그리고 lazymode 0 동작과 소스 결합이 그대로임을 확인합니다.

`gates/e2e.sh`는 그 위의 통합 스위트입니다. 자체 임시 디렉토리에 일회용 git 프로젝트를 만들어 실제 스크립트로 컴팩트 루트, 풀 루트, 그리고 모든 부정 시나리오를 돌립니다. 리뷰 후 수정, 파일 추가, chmod와 심볼릭 링크 교체, 전달 소스로 지목된 엉뚱한 옛 커밋, 예전 킷의 ship 결합, ship 리뷰 이후 수정되거나 삭제된 풀 루트의 spec·plan, 그리고 `status.sh`·`check-gate.sh`·`close.sh`가 같은 판정을 내는지까지 검사합니다. 픽스처 밖에는 아무것도 쓰지 않고 네트워크·원격·`gh` 호출도 하지 않습니다. `pr`과 `deploy` 전달은 로컬에서만 재현하며, 그것이 `close.sh`가 실제로 확인하는 전부입니다. 셀프테스트를 내부에서 다시 실행하지는 않습니다 — 두 스위트는 독립입니다. CI는 Ubuntu, macOS, Windows(Git Bash)에서 세 스위트를 모두 실행합니다.

## 이것이 아닌 것

- 자율 운영 배포 시스템이 아닙니다.
- 프로젝트 테스트, CI, 브랜치 보호, 보안 리뷰의 대체물이 아닙니다.
- 에이전트가 거짓말하거나 파일을 위조할 수 없다는 약속이 아닙니다.
- 또 하나의 에이전트 런타임이 아닙니다. 쓰던 에이전트에 이 프로세스를 얹으세요.

## 시작해 보기

작은 브라운필드 이슈 하나로 시작하세요. 독립 verifier가 찾은 것과 작성자가 보고한 것을 비교해 보면 이 프로세스가 왜 필요한지 바로 보입니다.

팀에 맞는다면 저장소에 스타를 남기거나, 다음으로 지원했으면 하는 에이전트 도구와 워크플로를 이슈로 알려주세요.

<div align="center">

[**시작하기**](#빠른-시작) · [**라이브 사이트**](https://cskwork.github.io/sdlc-kit/) · [**최신 릴리스**](https://github.com/cskwork/sdlc-kit/releases/latest) · [**이슈 열기**](https://github.com/cskwork/sdlc-kit/issues/new)

</div>
