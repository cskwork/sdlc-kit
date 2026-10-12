<div align="center">

# sdlc-kit

### 코딩 에이전트가 제 숙제를 스스로 채점하지 않게 합니다.

**어떤 코드베이스, 어떤 도메인에서든 쓰는 AI 코딩 에이전트용 4단계 SDLC.**

Intent → Plan → Build → Evidence. 코드를 쓰기 전에는 여러 탐색 에이전트를 나란히 돌려 조사하고, 코드를 쓴 뒤에는 따로 띄운 리뷰어가 공격적으로 검토하며, 마지막에는 점수를 매겨 다음 단계를 정합니다.

[![Release](https://img.shields.io/github/v/release/cskwork/sdlc-kit?style=flat-square&color=C79A55)](https://github.com/cskwork/sdlc-kit/releases/latest)
[![GitHub Pages](https://img.shields.io/badge/live_site-open-C79A55?style=flat-square)](https://cskwork.github.io/sdlc-kit/)

[**사이트 보기**](https://cskwork.github.io/sdlc-kit/) · [**빠른 시작**](#빠른-시작) · [**계약 문서**](SKILL.md) · [**English**](README.md)

</div>

---

코드는 이제 빨리 나옵니다. **틀렸을 때 드는 비용은 여전히 큽니다.** 코드부터
쓰는 에이전트는 부작용을 가장 늦게 발견하고, 자기 작업을 자기가 검사하는
에이전트는 문제를 잘 찾지 못합니다. sdlc-kit은 이해를 맨 앞에, 독립된 증명을
맨 뒤에 두고, 그 사이는 작게 유지합니다.

[Anthropic의 AI-Native SDLC playbook](https://claude.com/blog/the-ai-native-sdlc-playbook)을
바탕으로 했고, 특정 하네스가 필요 없습니다. Markdown 파일과 셸 스크립트 하나로
되어 있습니다.

> sdlc-kit은 독립 프로젝트이며 Anthropic과 관계가 없습니다.

## 루프

```mermaid
flowchart LR
  I["1 Intent"] -->|사람 승인| P["2 Plan"]
  P -. 빈틈 발견 .-> P
  P -->|계획 승인| B["3 Build"]
  B -. 리뷰 FAIL: 고치고 다시 리뷰 .-> B
  B -->|리뷰 PASS| E["4 Evidence"]
  E -. 계획이 틀렸거나 같은 실패 반복 .-> P
  E -. 코드 실패 .-> B
  E -->|must 전부 통과, 전체 95% 이상| D(["납품"])
  E -->|돌릴 환경 없음| H(["사람이 결정"])
```

| 단계 | 하는 일 | 되돌아가는 때 |
|---|---|---|
| **1 Intent** | 요청한 것, 에이전트가 이해한 것, 그 이해에 숨은 위험을 적습니다. 사람이 확인합니다. | — |
| **2 Plan** | 여러 scout가 나란히 정본·데이터·로직·사용자 흐름을 조사해 `refs/`에 남깁니다. `PLAN.md` 한 장에 AS-IS → TO-BE, 부작용, QA가 돌릴 시나리오를 담습니다. | 누락 점검에서 빈틈이 나올 때 |
| **3 Build** | 가장 작은 완전한 변경을 만들어 커밋하고, 별도 리뷰어가 공격적으로 검토합니다. | 리뷰 FAIL: 고치고 다시 리뷰 |
| **4 Evidence** | 실제 검사 뒤, 모든 시나리오를 각 페르소나로 실제 인터페이스에서 돌립니다. 점수와 다음 경로는 에이전트가 아니라 `sdlc.sh score`가 정합니다. | 계획이 틀렸거나 같은 실패 반복 → Plan, 코드 실패 → Build |

되돌아가는 횟수는 리뷰 FAIL, Plan 복귀, Build 복귀마다 세 번까지입니다. 넘으면
루프가 멈추고 사람이 정하며, `sdlc.sh approve plan --human`으로만 다시 시작합니다.
못 돌린 시나리오는 실패로 칩니다. 시나리오를 지우는 것은 사람만 할 수 있고,
PASS에는 반드시 로그가 붙어야 합니다.

## 빠른 시작

```bash
# 1. 한 번 설치하고, 에이전트가 스킬을 찾는 폴더에 연결
git clone https://github.com/cskwork/sdlc-kit ~/sdlc-kit
ln -s ~/sdlc-kit ~/.claude/skills/sdlc-kit      # Claude Code 기준, 하네스마다 스킬 폴더가 다름

# 2. 프로젝트(또는 모노레포의 배포 단위)에 씨앗 심기
cd /path/to/your-project
~/sdlc-kit/sdlc.sh init
$EDITOR .sdlc/config.md                          # build, test, lint, run, e2e, qa
```

스킬 폴더가 없는 하네스라면 지침 파일(`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`)에
`For SDLC work, read ~/sdlc-kit/SKILL.md and follow it.`을 넣으세요. 그다음
"CSV 내보내기 추가", "로그인 리다이렉트 고쳐 줘"처럼 평소 말로 요청하면 에이전트가
루프를 돕니다. 다음에 할 일은 언제든 `sdlc.sh next <slug>`가 알려 줍니다.

## 기능 하나가 남기는 것

```
.sdlc/work/<slug>/
  intent.md     요청, 이해, 위험
  refs/         scout 결과: source.md data.md logic.md flow.md learnings.md
  PLAN.md       한 장: 이해, AS-IS → TO-BE, 부작용, 변경, 시나리오
  review.md     리뷰 라운드, 각 라운드는 VERDICT로 끝남
  evidence.md   검사, 시나리오별 결과 한 행, 납품 기록
  logs/         모든 PASS·FAIL 뒤의 원본 출력
```

끝난 기능은 `.sdlc/archive/`로 옮겨집니다. 검증된 사실은 `knowledge` 폴더로
옮기고, 다음 기능의 scout가 그 폴더부터 읽습니다.

## 설정

프로젝트마다 다른 값은 `.sdlc/config.md` 한 곳에만 둡니다. `build`, `test`,
`lint`, `run`, `e2e` 명령, 화면이나 API를 다룰 `qa` 도구, `human_gates`(기본값
`intent`, 모든 plan을 직접 승인하려면 `plan` 추가, 위험 플래그가 있는 plan은
설정과 상관없이 사람이 승인), `knowledge` 폴더, `repos`(리뷰가 묶을 저장소.
프로젝트 루트 아래 저장소가 많으면 나열하고, 비우면 루트 아래 전부)입니다. `.sdlc/`는
`.git/info/exclude`로 git에서 빠집니다. 팀이 배운 것을 공유하려면 `knowledge:`를
git이 추적하는 폴더로 지정하세요.

## 늘 지키는 규칙

- **권한은 게이트와 별개입니다.** 데이터 유실, 마이그레이션, 공개 API 변경,
  보안에 민감한 코드, 인프라 변경, push·merge·배포는 어떤 설정에서든 사람이
  미리 허락해야 합니다.
- **독립된 눈.** scout, 리뷰어, QA는 작업을 만든 컨텍스트가 아닌 새 컨텍스트에서
  돕니다.
- **주장 대신 증거.** 실행 환경이 없으면 PASS가 아니라 BLOCKED입니다. 버그 수정에는
  수정 전에 실패한 테스트가 있어야 합니다.
- **검증한 것만 납품.** 납품한 트리가 검증한 커밋과 다르면 `close`가 거부합니다.

Build는 [ponytail](https://github.com/DietrichGebert/ponytail) 방식(가장 작은
완전한 변경)을 따릅니다. 규칙은 단계 문서에 들어 있어서 다른 스킬이 필요 없습니다.

## 호스트에서 돌리기

`sdlc.sh status --json`은 모든 기능의 단계, 상태, 점수, 경로를 보여 줍니다.
`sdlc.sh next <slug>`는 `0` 진행 가능, `10` 사람 필요, `20` 막힘, `30` 완료로
끝납니다. 스크립트는 기록하고 보고할 뿐 모델을 돌리지 않습니다. 무인 실행은
기록된 사람의 허락만큼만 납품합니다. 따로 허락하지 않았다면 로컬 커밋까지입니다.
Windows에서는 Git Bash나 WSL로 `sdlc.sh`를 실행하세요.

## v0.x에서 올리기

v2는 새 계약입니다. 기록은 있던 자리에 그대로 남습니다.

- v0에서 시작한 기능은 `sdlc.sh status`에 `legacy`로 보입니다. 옛 kit
  (`git -C ~/sdlc-kit checkout v0.27.0`)로 마치거나
  `sdlc.sh close <slug> dropped "<이유>"`로 닫으세요.
- `lazymode`는 계속 읽힙니다. 0–1 → `human_gates: intent plan`, 2–3 → `intent`,
  4 → 없음. 직접 정하려면 `human_gates:`를 쓰세요. `intent`, `plan`이 아닌
  값은 둘 다로 처리합니다.
- `knowledge:`를 정하기 전까지 `.sdlc/memory/`를 knowledge 폴더로 읽습니다.
- `init.sh` → `sdlc.sh init`, `gates/status.sh --json`과 `tools/auto.sh next` →
  `sdlc.sh status --json`과 `sdlc.sh next`(종료 코드 동일). spec.md, summary.md,
  delivery.md, qa-guide.md, map.md, harvest, 검증 영수증, handoff, tripwire,
  refcheck, QA 모드 전환은 없어졌고, 그 역할은 PLAN.md, evidence.md,
  `sdlc.sh close`, config의 `qa:`가 맡습니다.

바꾼 이유: [v2.0.0 changelog](log/changelog-v2.0.0.md).

## kit 검증

```bash
bash tests/selftest.sh
```

모든 프롬프트의 단어 예산, 게이트·라우팅 규칙, 작은 CLI fixture에서 실제 기능
하나를 4단계 끝까지 돌리는 검사가 들어 있습니다. CI는 Linux, macOS, Windows에서
돌립니다.

## 라이선스

MIT
