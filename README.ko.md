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

`lazymode`는 그 사람/자동 경계를 옮깁니다. `init.sh`가 `.sdlc/config.md`에 `lazymode: 1`을 심고, 에이전트가 원하는 레벨을 물어봅니다. 레벨별로 사람이 쥐는 게이트는 이렇습니다. **0** intent, spec, plan 트립와이어, ship(설계 그대로 전부) · **1**(기본) intent, spec, ship · **2** intent, ship · **3** intent · **4** 없음, 루프가 자율로 돕니다. 면제된 게이트는 `gates/approve.sh <stage> <artifact> --lazy`로 자동 승인되고 `mode: lazy`로 기록됩니다. plan과 ship은 lazymode와 무관하게 adversary 리뷰를 항상 먼저 통과해야 합니다. plan은 비가역 작업을 승인하는 지점이고, ship은 푸시 전 마지막 리뷰이기 때문입니다. intent와 spec은 `tripwire.sh` 스캔이 깨끗하면 리뷰를 건너뛸 수 있습니다. 승인은 여전히 기록되고, `approve.sh --lazy`는 설정 레벨이 사람에게 남긴 게이트를 거부합니다.

배포된 변경이 실패하면 Maintain 단계가 진단하고 다음 `intent.md`를 씁니다.

모든 티켓이 6단계를 다 도는 것은 아닙니다. 사소한 티켓 — 트립와이어 클린, 수정할 파일 확정, 기존 명령으로 성공 검증 가능 — 은 **마이크로 트랙**을 탑니다. intent(게이트) → build → ship로 바로 가고, ship의 adversary 리뷰가 diff의 유일한 리뷰가 됩니다(intent.md에 `Track: micro`, 기준은 `skills/1-intent`). 반대로 한 번에 파악이 안 되는 티켓은 **map**(`map.md`: 목적지 · 정한 것 · 모르는 것 · 안 할 것)부터 만들고, 세션마다 미결 하나씩 풀어 intent.md를 쓸 수 있을 때까지 진행합니다.

루프 도중의 교훈·도메인 후보는 피처 자신의 `harvest.md`에만 쌓입니다. 공유 메모리(`INDEX.md`, `DOMAIN.md`, `lessons/`)를 쓰는 주체는 close 단계 하나뿐이라 병렬 루프가 충돌하지 않습니다. 채팅에서 선언한 하드 룰은 — 사람의 말이 있을 때만, 날짜와 함께 — `.sdlc/memory/POLICY.md`에 전사되고, adversary는 위반을 차단 사유로 처리합니다.

## 무엇이 다른가

| 흔한 에이전트 워크플로 | sdlc-kit |
|---|---|
| 첫 요청부터 코딩 시작 | 히스토리, 코드, 실현 가능성, 브라우저, API, DB를 먼저 뒤진 뒤에 사용자를 심문 |
| 사용자의 진단을 사실로 취급 | 주장마다 `[verified: 증거]` 또는 `[assumed: 이유]` 라벨 |
| 계획이 채팅 안에만 존재 | `intent.md`와 `plan.md`는 코드와 함께 커밋, `spec.md`와 `evidence.md`는 디스크에 보존 |
| 작성자가 자기 검사를 직접 실행 | 작성자 컨텍스트가 없는 verifier와 adversary가 리뷰 |
| 승인이 사라지는 채팅 메시지 | 승인 기록이 단계, 산출물, 시각, 모드를 담고 `.sdlc/approvals/`에 파일로 남음 |
| 실패한 시도는 잊힌 컨텍스트가 됨 | 교훈은 상한 있는 인덱스로, 확인된 사실은 `DOMAIN.md`로 |
| 만능 워커 하나가 전부 수행 | 로컬 QA, 리뷰어, 브라우저, API, DB 전문 에이전트가 있으면 역할 계약을 그쪽에 위임 |
| "끝났다"가 모호함 | 모든 실행이 `shipped`, `abandoned`, `dead-end`, `handed-off` 중 하나로 종결 |

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

       2단계는 승인된 산출물만 들고 서브에이전트로 돕니다.
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
│   ├── spec.md                       # Human summary · AS-IS → TO-BE · 계약 — gitignore 대상
│   ├── plan.md                       # 파일 · 순서 · 리스크 · 증명
│   ├── deviations.md                 # 빌드 중 편차 기록, plan은 잠긴 채 유지 — gitignore 대상
│   ├── progress.md                   # 하트비트: 살아있는 한 줄, gitignore 대상 (규칙 9)
│   ├── baseline.txt                  # 브라운필드의 변경 전 동작 — gitignore 대상
│   ├── harvest.md                    # 루프 중 교훈·도메인 후보, close에서 병합 — gitignore 대상
│   └── evidence.md                   # 명령 · 출력 · 관찰된 동작 — gitignore 대상
└── archive/<slug>/                   # 닫힌 피처, close.sh가 여기로 옮김
    ├── CLOSED                        # shipped · abandoned · dead-end · handed-off
    └── approvals/                    # 피처의 승인 기록도 함께 이동, 여전히 gitignore 대상
```

`init.sh`는 프로젝트 `.gitignore`에 열여섯 줄을 추가합니다. `work/`와 `archive/` 양쪽의 `approvals/`, `spec.md`, `baseline.txt`, `deviations.md`, `evidence.md`, `harvest.md`, `scratch/`, `progress.md`입니다. git에 남는 것은 결정 기록입니다. `config.md`, `memory/`, 그리고 피처마다 `intent.md`, `plan.md`, `map.md`, 아카이브의 `CLOSED`. 나머지는 증거와 작업 잔여물이라 커밋을 부풀리는 대신 스크립트가 읽는 디스크에만 남습니다. 피처가 열려 있는 동안 `status.sh`가 하트비트를 나이와 함께 `now →` 줄로 보여주며, `watch -n5 cat .sdlc/work/<slug>/progress.md`로 실시간 추적할 수 있습니다.

공개 sdlc-kit 저장소는 프레임워크만 담습니다. 커밋되는 산출물(intent, plan, map, memory)은 그것이 설명하는 프로젝트 안에서 함께 버전 관리됩니다. 무시되는 나머지는 그것을 만든 작업 사본 안에만 남습니다.

## 안전 모델

### 결정은 사람이, 타이핑은 에이전트가

게이트 결정의 주인은 사람입니다. 게이트에서 직접 결정하거나, `.sdlc/config.md`의 `lazymode`로 미리 정해 둡니다. 채팅에서 명시적으로 승인하면 에이전트가 대신 실행할 수 있습니다.

```bash
gates/approve.sh <stage> .sdlc/work/<slug>/<artifact> --delegated
```

승인 기록은 명시적으로 남습니다. 침묵과 막연한 "계속해"는 승인이 아닙니다. lazymode 면제는 사람이 미리 설정해 둔 승인이고, 기록에 그렇게 적힙니다.

### 잠금장치가 아니라 기록

`approve.sh`는 단계, 산출물, 시각, 모드를 평문으로 씁니다. `check-gate.sh`는 기록과 산출물이 존재하는지만 봅니다. 승인된 파일을 수정해도 게이트는 닫히지 않습니다. 이 기록은 gitignore 대상이라, 추적은 git 히스토리가 아니라 디스크의 `.sdlc/approvals/` 디렉토리(닫힌 피처는 `.sdlc/archive/<slug>/approvals/`로 이어짐)입니다. `status.sh`와 `stats.sh`는 그 파일을 직접 읽으므로 게이트 상태와 재승인 횟수는 그대로 나옵니다. 달라지는 것은 지속성입니다. 새로 클론하면 승인 기록이 따라오지 않아, 피처를 진행하던 중에 다시 클론하면 승인을 다시 받아야 합니다. 추적의 정직함은 에이전트 규칙과 디스크에 남은 그 기록에서 나옵니다.

### 새 컨텍스트 리뷰

산출물을 쓴 컨텍스트가 그 산출물을 검증하지 않습니다. 독립적인 워커는 병렬로 돌아도 됩니다. 체크아웃 하나당 쓰기 담당은 하나입니다.

### 실패한 실행도 지식을 남긴다

```bash
gates/close.sh <slug> <shipped|abandoned|dead-end|handed-off> "reason"
```

abandoned나 dead-end는 교훈이 없으면 닫히지 않습니다(lazymode 3 이상에서는 필수 입력인 종료 사유가 기록을 대신합니다). 무엇을 시도했고, 왜 실패했고, 무엇이 있으면 뚫리는지를 적습니다. handed-off는 외부 티켓이나 PR을 반드시 지목해야 합니다. 감사 추적이 킷 밖에서도 끊기지 않게 하기 위해서입니다. 종결은 곧 아카이브입니다. 피처 디렉토리와 승인 기록이 `.sdlc/archive/<slug>/`로 이동해 `status.sh`는 열린 작업만 보여줍니다.

### 장애 진단은 싼 프로브부터

6단계는 에이전트를 대량으로 풀지 않습니다. 배포된 ref를 먼저 확인하고, 어떤 통제가 뚫렸는지 묻고, 요청한 재현 증거를 추적하고, `skills/6-maintain/probes.md`의 짧은 프로브를 돌립니다.

프로브는 수정 계획에 도달하기 전에 흔한 진단 실수 네 가지를 잡습니다.

- 배포된 브랜치 대신 오래된 체크아웃을 읽는 실수
- 공유 쿼리 하나를 호출자 전수 조사 없이 고치는 실수
- 아래 계층이 이미 삼키는 에러에 `try/catch`를 덧대는 실수
- 데이터 없는 정상 상태를 확인하지 않고 "리스크 제로"라고 말하는 실수

재현이 안 되는 장애는 새 컨텍스트 adversary들이 범위를 다시 세고, 주장된 에러 전파를 증명하고, 모든 "절대 안 그래" 주장을 공격하고, 경쟁 원인을 제시합니다. 받지 못한 콘솔, 네트워크, 스크린샷 증거는 사람이 받거나 면제할 때까지 `status.sh`에 계속 보입니다.

## 조종석

```bash
gates/status.sh [--all[=n]] [slug]  # 열린 피처 + 다음 액션 하나, --all은 최신 아카이브 20건 포함
gates/stats.sh [--all]              # 단계별 소요 시간 + 재승인 횟수, 기본은 열린 피처 + 최근 종결 20건
gates/selftest.sh        # 게이트, 종결, 인젝션, lazymode, status 렌더, YAML 무결성
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
gates/           approve · check · close · status · stats · selftest
templates/       intent · spec · plan · evidence · lesson
docs/index.html  EN/KO 랜딩 페이지
```

## 킷 검증

```bash
./gates/selftest.sh
```

셀프테스트는 게이트 상태, 단계명 인젝션, 경로 이탈 거부, delegated와 lazy 승인, 종결 시 교훈 요구, 이중 종결 거부, 종결 시 아카이브(승인 기록 이동과 status 범위 포함), YAML 프런트매터 파싱, 전체 스크립트의 LF 줄 끝을 검사합니다.

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
