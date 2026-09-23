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
- 구현은 작성자가 아닌 별도의 verifier가 세 갈래로 병렬 검증합니다. 실제 동작(E2E), 부작용과 데이터 정합성, 그리고 요청의 출처인 티켓·기획서와의 일치 여부입니다.
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
| 계획이 채팅 안에만 존재 | 기록(`intent.md`, `spec.md`, `plan.md`, `evidence.md`, `delivery.md`)을 애플리케이션 히스토리 밖의 저장소에 남기고 나중에 `tools/kb.sh`로 찾음 |
| 작성자가 자기 검사를 직접 실행 | 작성자 컨텍스트가 없는 verifier와 adversary가 리뷰 |
| 승인이 사라지는 채팅 메시지 | 승인 기록이 단계, 산출물, 시각, 모드를 담고 `.sdlc/approvals/`에 파일로 남음 |
| 실패한 시도는 잊힌 컨텍스트가 됨 | 교훈은 상한 있는 인덱스로, 업무 정책은 제품 영역 페이지로, 확인된 사실은 `DOMAIN.md`로 |
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
.sdlc/                                # 전체가 gitignore 대상 — 기록은 소스가 아니라 지식입니다
├── README.md                         # 생성되는 목차 페이지 (tools/kb.sh index)
├── config.md                         # 실제 build/test/lint/run 명령
├── approvals/                        # 로컬 게이트 기록
│   └── <slug>.<stage>.approval       # 단계 · 시각 · 모드
├── memory/
│   ├── POLICY.md                     # 사람이 선언한 하드 룰, 에이전트는 전사만
│   ├── INDEX.md                      # 교훈 포인터, 50줄 이하
│   ├── DOMAIN.md                     # 여러 제품 영역에 걸친 용어 · 사실 · 제약
│   ├── areas/<메뉴 경로>.md               # 제품 영역(웹앱은 메뉴)마다 한 장, 예: "학습 - 평가 - 제출.md": 업무 정책 P1… · 통계 산정 N1…(선택) · 동작 · 변경 이력 · 근거(접힘)
│   └── lessons/<date>-<lesson>.md
├── work/<slug>/                      # 열린 피처만
│   ├── origin.md                     # 요청 당시의 티켓 · 기획서 스냅샷 — intent 게이트가 결합
│   ├── intent.md                     # 문제 · 증명 · 성공 기준 · 범위
│   ├── spec.md                       # Human summary · AS-IS → TO-BE · 계약
│   ├── plan.md                       # 파일 · 순서 · 리스크 · 증명
│   ├── evidence.md                   # 명령 · 출력 · 관찰된 동작
│   ├── delivery.md                   # 전달 목표 · 전달한 소스 · 검증 방법
│   ├── deviations.md                 # 빌드 중 편차 기록
│   ├── progress.md                   # 하트비트: 살아있는 한 줄 (규칙 9)
│   ├── baseline.txt                  # 브라운필드의 변경 전 동작
│   ├── summary.md                    # 읽는 사람용 페이지: 제품 영역 · 무엇이 문제였나 · Before → After · 확인 방법 · 기억할 점, 승인에 묶이지 않아 계속 갱신
│   ├── harvest.md                    # 루프 중 교훈·도메인 후보, close에서 병합(그 전에도 kb.sh show / harvest로 읽힘)
│   └── scratch/                      # 대용량 로그 · 캡처 · 트레이스
└── archive/<slug>/                   # 닫힌 피처, close.sh가 여기로 옮김
    ├── CLOSED                        # shipped · abandoned · dead-end · handed-off
    └── approvals/                    # 피처의 승인 기록도 함께 이동
```

`init.sh`는 프로젝트 `.gitignore`에 한 줄, `/.sdlc`만 추가합니다. 기록은 애플리케이션의 소스가 아니라 프로젝트의 지식이므로 애플리케이션 히스토리에 남지 않고, 애플리케이션을 클론해도 따라오지 않습니다. 이 규칙은 루트에 고정되어 있어 하위 배포 단위가 가진 별도의 `.sdlc`에는 영향을 주지 않으며, 실제 디렉터리든 외부 영역이 설치한 심볼릭 링크든 똑같이 걸러냅니다. 예전 킷으로 심은 프로젝트에서 다시 실행하면 이 규칙이 포함하게 된 좁은 무시 줄들을 제거하고, git 인덱스는 건드리지 않습니다. 이미 커밋된 파일은 사용자가 직접 추적을 해제하기 전까지 그대로 남으며, `init.sh`가 그 명령을 출력합니다. 대용량 출력은 `scratch/`에 남고 evidence.md는 결정적인 줄만 인용합니다. 피처가 열려 있는 동안 `status.sh`가 하트비트를 나이와 함께 `now →` 줄로 보여주며, `watch -n5 cat .sdlc/work/<slug>/progress.md`로 실시간 추적할 수 있습니다.

**기록을 어디에 둘지는 사용자가 정합니다.** 기본값은 프로젝트 작업 사본 안이고, `init.sh . --area ~/knowledge`를 쓰면 사용자가 고른 폴더 아래 `<area>/<단위이름>-<체크아웃 식별자>/`에 저장하고 `.sdlc`를 그곳으로 연결합니다. 체크아웃마다 저장소가 하나씩이므로 워크트리 두 개가 승인 상태를 공유하는 일이 없습니다. 영역이 프로젝트 안에 있거나 프로젝트가 영역 안에 있을 때, 다른 체크아웃이 이미 그 저장소를 소유할 때, 실제 `.sdlc` 디렉터리가 이미 있을 때(자동으로 옮기지 않습니다), 링크를 만들 수 없을 때는 아무것도 쓰지 않고 분명히 실패합니다. 이 소유권은 init 시점뿐 아니라 실행 시점에도 다시 확인합니다. `<store>/PROJECT`에 적힌 체크아웃이 지금 실행 중인 체크아웃과 다르면 `check-gate.sh`, `approve.sh`, `close.sh`, `status.sh`, `tools/auto.sh`, `tools/verify.sh`, `tools/handoff.sh`가 판정을 내리거나 상태를 쓰기 전에 거부하므로, 심볼릭 링크를 그대로 복사한 작업 사본(`cp -R`, rsync, 대부분의 백업 복원)이 다른 체크아웃의 게이트를 열거나 그 피처를 닫을 수 없습니다. 읽기는 이 제약을 받지 않아 `tools/kb.sh show|search|list`는 그대로 쓸 수 있고, 소유권을 자동으로 옮기거나 다시 묶는 일은 없습니다. 어느 쪽을 고르든 **저장소 백업은 사용자의 몫입니다.** git이 더 이상 대신해 주지 않습니다.

**지식은 제품 영역별로 정리됩니다.** 웹앱이면 제품 영역은 메뉴 하나이고 메뉴 경로(`학습 > 평가 > 제출`)로 부릅니다. 다른 소프트웨어는 모듈, API, 배치 작업, CLI 명령입니다. 제품 영역마다 페이지가 한 장 있고, 파일 이름은 메뉴 경로입니다 — `memory/areas/학습 - 평가 - 제출.md`(` > `는 ` - `로, `/ \ : * ? " < > |`는 `-`로 바꿉니다). 페이지는 읽는 사람 우선입니다. 위에는 개발자가 아니어도 읽을 수 있는 문장으로 쓴 업무 정책(P1, P2…), 동작 방식, 그 영역을 바꾼 피처별 이력 한 행이 오고(정책·수치·이력·근거는 한 줄에 하나씩 쓰는 마크다운 표), 출처·검증·코드 위치는 모두 맨 아래 접힌 근거 블록에 둡니다. 건수·비율·점수·차트를 보여주는 영역은 통계 산정(N1, N2…) 섹션도 가지며, 화면의 수치 하나마다 무엇을 세는지와 출처를 한 행으로 남깁니다 — 업무 정책과 같은 영속성·처리 방식을 따릅니다. 피처의 `summary.md`는 `Area:` 줄로 제품 영역을 적고, spec은 어떤 정책이나 수치를 유지하거나 바꾸는지 밝히고, Side effects 검증자는 건드리지 않아야 할 것이 그대로인지 다시 확인하며, close 병합이 새로 생기거나 바뀐 정책·수치를 페이지에 올립니다. `tools/kb.sh show "학습 > 평가 > 제출"`(또는 페이지 파일 이름)은 그 페이지와 그 제품 영역을 바꾼 피처를 함께 보여줍니다.

**기록을 다시 읽는 도구는 `tools/kb.sh`입니다.** `index`는 목차 페이지를 다시 만듭니다(`init.sh`와 `close.sh`가 자동으로 실행합니다). 페이지는 정책 수·마지막 변경·피처를 담은 제품 영역 표, 상태·날짜·제품 영역·태그를 담은 개요 표(최신순), 아직 close가 병합하지 않은 harvest 목록, 피처별 절 순서입니다. `show <slug>`는 피처 하나를 요약본으로 보여줍니다. 목표, `summary.md`(제품 영역·무엇이 문제였나·Before → After·확인 방법을 담는, 계속 갱신하도록 만든 유일한 기록), 배포 상태, 병합되지 않은 harvest 후보, 교훈 제목이 먼저 나오고 파일 경로는 마지막입니다. `search "<문자열>"`은 열린 피처와 닫힌 피처, 지속 메모리를 대상으로 출력량을 제한한 문자열 검색을 하고, `harvest [--stale <일수>]`는 harvest.md가 아직 memory/에 들어가지 않은 열린 피처를 유휴 기간과 함께 나열합니다(유휴 상태가 오래된 피처는 close 없이 병합할 수 있습니다 — AGENTS.md 규칙 4). `--area <폴더>`를 붙이면 그 폴더 안의 모든 저장소를 대상으로 같은 일을 하며, 원래 체크아웃이 사라진 피처도 읽을 수 있습니다. 저장소 config.md에 `index_style: obsidian`을 적으면 Obsidian 볼트용 frontmatter와 인라인 `#태그`를 덧붙입니다. 생성 시각은 절대 쓰지 않으므로 내용이 같으면 diff도 생기지 않습니다. 종료 코드는 `0` 찾음, `1` 없음, `2` 사용법 오류 또는 거부입니다.

공개 sdlc-kit 저장소는 프레임워크만 담습니다. 기록은 작성된 자리, 즉 프로젝트 작업 사본이나 사용자가 고른 영역에 남아 그대로 읽힙니다.

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

그 전에 검증은 실제 동작을 돌립니다. 바뀐 동작을 사용자나 호출자가 실제로 만나는 인터페이스로 끝까지 실행하되, 변경 범위에 맞춰 프로젝트 자신의 명령(`.sdlc/config.md`의 `e2e:`, `qa:`, `run:`)을 씁니다. 실행할 환경이 없으면 NOT VERIFIED이며 evidence.md에 그렇게 적습니다. 통과한 단위 테스트가 조용한 대체물이 되는 일은 없습니다. 그 옆에서 두 갈래가 병렬로 더 돕니다. **부작용** 렌즈는 베이스라인, 유지되어야 할 동작, 그리고 변경이 건드린 데이터 형태가 다른 생산자와 소비자 사이에서 정합성을 지키는지 봅니다. **의도 일치** 렌즈는 intent 게이트가 결합한 티켓·기획서 스냅샷 `origin.md`를 번호 붙은 성공 기준마다 대조해, 구현이 무엇을 담았고 무엇을 빠뜨렸고 무엇을 넘어섰는지 적습니다. 어느 렌즈의 발견이든 build의 fix loop로 들어가며, 3라운드 안에 해결되지 않으면 사람에게 가고 `tools/auto.sh`는 이를 `fixloop.exhausted`로 보고합니다.

### 실패한 실행도 지식을 남긴다

```bash
gates/close.sh <slug> <shipped|abandoned|dead-end|handed-off> "reason"
```

abandoned나 dead-end는 교훈이 없으면 닫히지 않습니다(lazymode 3 이상에서는 필수 입력인 종료 사유가 기록을 대신합니다). 무엇을 시도했고, 왜 실패했고, 무엇이 있으면 뚫리는지를 적습니다. handed-off는 외부 티켓이나 PR을 반드시 지목해야 합니다. 감사 추적이 킷 밖에서도 끊기지 않게 하기 위해서입니다. 종결은 곧 아카이브입니다. 피처 디렉토리와 승인 기록이 `.sdlc/archive/<slug>/`로 이동해 `status.sh`는 열린 작업만 보여줍니다.

### 장애 진단은 싼 프로브부터

6단계는 에이전트를 대량으로 풀지 않습니다. 배포된 소스를 먼저 확인합니다. `refcheck.sh`는 작업 트리의 내용을 스테이징·비스테이징·미추적까지 모두 대상 리비전과 비교하고, 릴리스 시스템이 알려주는 실제 배포 SHA가 있으면 `--deployed-sha`로 받고, ref나 fetch가 실패하면 추측 대신 UNKNOWN을 보고합니다. 그다음 무엇을 어떤 입력으로 했는지, 대신 무슨 일이 일어났는지, 어디서, 누구로, 어떤 흔적이 남았는지 묻고(UI·API·배치 작업·CLI 모두 같은 다섯 질문), 요청한 재현 증거를 추적하고, `skills/6-maintain/probes.md`의 짧은 프로브를 돌립니다.

프로브는 수정 계획에 도달하기 전에 흔한 진단 실수 네 가지를 잡습니다.

- 배포된 브랜치 대신 오래된 체크아웃을 읽는 실수
- 공유 쿼리 하나를 호출자 전수 조사 없이 고치는 실수
- 아래 계층이 이미 삼키는 에러에 `try/catch`를 덧대는 실수
- 데이터 없는 정상 상태를 확인하지 않고 "리스크 제로"라고 말하는 실수

버그 수정은 수정 전 코드에서 보고된 이유로 실패하는 회귀 테스트부터 만듭니다. 같은 테스트가 수정 후 통과하고 테스트 스위트에 남습니다. 테스트로 결함에 닿을 수 없을 때만 수동 절차나 로그로 대신하고, 그 이유를 증거에 적습니다.

재현이 안 되는 장애는 새 컨텍스트 adversary들이 범위를 다시 세고, 주장된 에러 전파를 증명하고, 모든 "절대 안 그래" 주장을 공격하고, 경쟁 원인을 제시합니다. 받지 못한 콘솔, 네트워크, 스크린샷 증거는 사람이 받거나 면제할 때까지 `status.sh`에 계속 보입니다.

## 조종석

```bash
gates/status.sh [--all[=n]] [slug]  # 열린 피처 + 다음 액션 하나, --all은 최신 아카이브 20건 포함
gates/status.sh --json [slug]       # 같은 상태를 기계가 읽는 형식으로(tools/auto.sh)
gates/stats.sh [--all]              # 단계별 소요 시간 + 재승인 횟수, 기본은 열린 피처 + 최근 종결 20건
gates/selftest.sh        # 스모크 테스트: 스크립트 문법, 스킬 메타데이터, 게이트 동작 (몇 초)
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
tools/kb.sh index|show|search|list|harvest   # 지난 피처와 교훈 찾기(--area로 영역 전체; harvest = 아직 병합되지 않은 지식)
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
gates/           approve · check · close · status · stats · selftest (공용 헬퍼 _common.sh, _auto.sh 포함)
tools/           auto(기계 상태) · verify(영수증, python3 필요) · handoff(리뷰 브랜치) · _run.py(제한된 실행) · tripwire · refcheck
templates/       intent · spec · plan · evidence · delivery · verify · lesson
docs/index.html  EN/KO 랜딩 페이지
docs/automation.md  기계 계약: status JSON, 영수증, 핸드오프, 체크포인트
```

## 킷 검증

```bash
./gates/selftest.sh   # 몇 초
```

대부분이 지침 문서인 킷이라 스모크 테스트 하나만 둡니다. 모든 스크립트가 문법 오류 없이 LF로
저장돼 있는지, 모든 SKILL.md의 frontmatter가 올바른지, 게이트가 승인된 내용에서만 열리고 그
내용이나 상위 산출물이 바뀌면 닫히는지, lazymode가 설정 단계를 넘지 않는지, `dead-end`에는
교훈이 필요하고 `shipped`에는 ship 승인과 확인된 전달 기록이 필요한지, 그리고 UTF-8 로케일에서도
지식이 제 제품 영역에 정리되는지 확인합니다. CI는 PR과 수동 실행 때만 돌립니다.

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
