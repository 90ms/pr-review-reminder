# PR Review Reminder

[![CI](https://github.com/90ms/pr-review-reminder/actions/workflows/ci.yml/badge.svg)](https://github.com/90ms/pr-review-reminder/actions/workflows/ci.yml)

![PR Review Reminder icon](Assets/AppIcon.svg)

macOS 메뉴바 앱. 내가 리뷰어로 지정됐지만 아직 리뷰하지 않은 PR을 정해진 시간에 모아,
`claude`/`codex` CLI로 요약·코드리뷰하고, 미리보기로 확인한 뒤 인라인 코멘트/Approve를 남긴다.

- 인증은 `gh` CLI에, AI는 `claude`/`codex` CLI에 위임한다. **앱은 토큰/API 키를 저장하지 않는다.**
- 모든 게시(코멘트/Approve/이슈)는 **미리보기 후 사용자가 버튼을 눌러야만** 실행된다.
- 리뷰 결과는 히스토리에 저장되어, 같은 커밋은 **토큰 재소비 없이 복원**된다.

## 요구 사항

- macOS 14+
- Swift 6 / Xcode 26 (빌드용)
- [`gh`](https://cli.github.com) — `gh auth login`으로 로그인되어 있어야 함
- `claude` 또는 `codex` CLI 중 하나 이상 (개인 구독 재사용)

## 빌드 & 실행

```bash
swift build            # 개발 빌드
swift test             # 단위 테스트
./Scripts/build-app.sh # dist/PR Review Reminder.app 조립
open "dist/PR Review Reminder.app"

# CLI 탐지 진단 (Finder 실행 환경 재현)
env -i HOME="$HOME" .build/debug/PRReviewReminder --doctor
```

메뉴바 오른쪽에 체크리스트 아이콘(대기 PR 개수 배지)이 뜬다. 클릭하면 팝오버가 열린다.

## 사용 흐름

1. 팝오버의 **↻ 새로고침** → 리뷰 대기 PR 수집 (수집만, 자동 리뷰 아님).
2. PR 카드의 **코드 리뷰** → AI가 요약·리뷰포인트·인라인 코멘트 초안 생성 (완료 시 알림 + 토큰/비용 표시).
3. **자세히 보기** → 큰 창에서 요약·리뷰포인트 + **Split/Unified diff**(좌 원본 / 우 변경) 확인, 인라인 코멘트 편집.
4. 제출 시 **미리보기 시트** → **제출**(코멘트만) 또는 **코멘트 남기고 승인**(머지 무방 문구와 함께 Approve).
5. **히스토리** → 과거 리뷰 목록 + 누적 토큰·비용 집계.
   저장된 상세/diff를 다시 열거나 현재 head를 가져와 재리뷰할 수 있다.
6. **의견 남기기** → 입력 → (에이전트로 정돈) → GitHub 이슈 등록 커맨드 구성.

## 주요 기능

- **수집**: `review-requested:@me` & 아직 내가 리뷰하지 않은 열린 PR (대상 org/repo 설정 가능).
- **온디맨드 코드리뷰**: PR별 수동 실행이 기본. 설정에서 "PR 발견 시 자동 코드리뷰"로 전환 가능.
- **토큰/비용 표기**: claude는 보고된 실제 비용, codex는 설정 단가로 추정.
- **로컬 리뷰 예산**: 최근 N일 히스토리 토큰을 기준으로 새 AI 리뷰 시작을 제한.
- **히스토리 & 캐시 복원**: 완료 리뷰를 저장하고, head SHA가 같으면 토큰 없이 복원. 누적 사용량 집계.
- **안전한 게시**: 게시 직전 head SHA 확인, 인라인 코멘트는 단일 GitHub review로 제출.
- **미리보기 후 게시**: 인라인 코멘트 / 요약 코멘트 / Approve / 코멘트+Approve — 모두 확인 시트를 거친다.
- **다국어**: 앱 UI 언어 + 리뷰 출력 언어를 각각 선택 (기본 = 시스템 로케일).
- **스케줄 & 알림**: 매일 지정 시각 또는 N시간 간격 수집 + 시스템 알림.
- **피드백 → 이슈**: 의견을 AI로 정돈 후 GitHub 이슈로 등록 (피드백 레포 미설정 시 커맨드 미리보기만).

## 설정

- **언어**: 앱 언어 / 리뷰 언어 (system·한국어·English).
- **GitHub**: Owner/org (기본 `fastlane-dev`), Repos (비우면 org 전체).
- **AI tool**: `claude` / `codex`.
- **Schedule**: 매일 지정 시각 또는 N시간 간격.
- **Notifications / Auto-review**: 알림 on/off, PR 발견 시 자동 코드리뷰 on/off.
- **History**: 로컬 저장 on/off, 보존 기간, 전체 삭제.
- **Codex pricing / Review budget**: 백만 토큰당 단가와 최근 N일 토큰 한도.
- **Prompt template**: AI에게 보내는 리뷰 지시문. `{{TITLE}}`, `{{BODY}}`, `{{DIFF}}`, `{{SKILL}}` 치환.
- **Review skill / guidelines**: 프롬프트 `{{SKILL}}`에 주입되는 추가 규칙 (파일에서 불러오기 가능).
- **Feedback repository**: 의견을 이슈로 등록할 `owner/repo` (비우면 등록 보류·미리보기만).

## 구조

```
Sources/
  PRRCore/            # 로직 (모델·서비스·뷰모델·뷰) — 테스트 대상
    Models/           # PullRequest, Analysis(+AIUsage), AppSettings, ReviewRecord
    Services/         # GitHubService, AIService, FeedbackService, HistoryStore,
                      #   DependencyDoctor, Scheduler, SettingsStore
    ViewModels/       # AppState (오케스트레이션)
    Views/            # MenuContentView, PRCardView, PRDetailView, DiffView,
                      #   SettingsView, HistoryView, FeedbackView, Components
    Support/          # ProcessRunner, ToolLocator, Localization, DiffParser, Notifier
  PRReviewReminder/   # @main App 진입 (창 씬 + --doctor 진단 모드)
Tests/PRRCoreTests/   # 단위/오케스트레이션 테스트 + gh 출력 픽스처
Scripts/build-app.sh  # .app 번들 조립 (LSUIElement 메뉴바 앱)
docs/SPEC.md          # 계약(수용 기준·검증)
tasks/plan.md         # 실행 계획
```

## 설계 원칙

1. **AI는 절대 자동 게시하지 않는다** — 모든 게시는 미리보기 후 사용자 액션.
2. **읽기/쓰기 분리** — 수집·요약은 자동, 게시는 수동 트리거.
3. **앱은 토큰을 만지지 않는다** — 인증은 전적으로 `gh`/`claude`/`codex` CLI에 위임.
4. **없는 명령을 지어내지 않는다** — CLI 부재 시 진단 후 안내.
5. **불필요한 토큰 소비 금지** — 같은 커밋의 리뷰는 히스토리에서 복원.

## 로컬 데이터와 안전

히스토리를 켜면 PR 본문, diff, AI 결과와 사용량이
`Application Support/PRReviewReminder/history.json`에 사용자 전용 권한으로 저장된다.
설정에서 저장을 끄거나 보존 기간을 정할 수 있고 히스토리 창에서 전체 삭제할 수 있다.
저장을 끄면 캐시 복원과 히스토리 기반 예산 계산도 중단된다.

모든 GitHub 쓰기는 명시적인 사용자 버튼으로만 실행된다. 앱이 게시 직전 head SHA를
다시 확인하더라도 AI 결과와 라인 위치는 미리보기에서 검증해야 한다.

## 알려진 제약

- **리뷰 토큰 제한**은 CLI의 실제 세션 잔여량이 아니라 로컬 히스토리 기반 근사다.
- AI 명령은 10분 후 종료되지만 진행 중 작업을 누르는 별도 취소 버튼은 아직 없다.
- 검색은 한 번에 최대 100개 PR을 조회한다.
- CLI 실행은 GUI 앱의 최소 PATH 문제를 우회하기 위해 로그인 셸 + 알려진 설치 경로 폴백으로 탐지한다.
- 스케줄은 앱이 실행 중일 때만 동작한다(백그라운드 데몬/launchd는 범위 밖).

제품 흐름과 아키텍처는 [한 페이지 소개](docs/PROJECT_OVERVIEW.md)와
[현재 제품 명세](docs/SPEC.md)에서 볼 수 있다.

## 개발 규율

이 저장소는 [Beez Agent Harness](https://github.com/90ms/beez-agent-harness)의
Spec → Plan → Implement → Verify → Review 규율을 따른다. `.harness/`와 `AGENTS.md` 참고.
```bash
node /path/to/beez-agent-harness/bin/beez-harness.js doctor   # 어댑터 상태 점검
```
