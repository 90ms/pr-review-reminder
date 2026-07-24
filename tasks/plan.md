# 실행 계획 — PR Review Reminder

> **상태(2026-07-24): 아래 초기 12개 슬라이스 완료 + 후속 반복(v0.3~v0.7) 완료.**
> 후속 반복으로 추가된 것: 다국어(UI/리뷰 언어), PR 상세 창 + Split/Unified diff, 리뷰 스킬 주입,
> 피드백→이슈, 온디맨드 코드리뷰(자동 토글), 토큰/비용 표기, 리뷰 완료 알림, 미리보기-후-게시
> (코멘트/요약/Approve/코멘트+Approve), 리뷰 히스토리 + head SHA 캐시 복원 + 누적 사용량.
> 버그 수정: CLI 탐지 폴백(~/.local/bin), 프로세스 러너 백그라운드화·파이프 동시 배수(메인스레드
> 프리즈·데드락 해소), 리뷰 중 인덱스 무효화(id 재조회), 팝오버 가변 크기.
> 보류: #2 세션 잔여 토큰 기반 리뷰 제한(CLI 미지원). 현재 테스트 43개 통과.

계약: `docs/SPEC.md`. 얇은 수직 슬라이스로 분해하고, 계약(모델/러너)을 소비자(서비스)보다,
서비스를 UI보다 먼저 안정화한다. 각 슬라이스는 즉시 검증한다.

| # | 슬라이스 | 산출물 | 검증 (증거) | AC |
|---|----------|--------|-------------|-----|
| 0 | 스캐폴드 | `Package.swift` (exe + test 타깃), 디렉터리 | `swift build` 성공 | AC10 |
| 1 | ProcessRunner | 프로토콜 + 실제 구현(async) | `swift test` (echo 실행) | AC6/7 기반 |
| 2 | 모델 | PR, Analysis, ReviewPoint, InlineComment, enum, AppSettings | build + Codable 테스트 | AC1,AC2,AC4 |
| 3 | GitHubService | 커맨드 구성 + gh JSON 파싱 + 리뷰판정 + 게시커맨드 | mock runner + fixture 테스트 | AC2,AC3,AC7 |
| 4 | AIService | claude/codex 커맨드, 프롬프트, 관대한 JSON 파서 | 파싱/커맨드 테스트 | AC4,AC5,AC6 |
| 5 | DependencyDoctor | gh/claude/codex 진단 | 파싱 테스트 | AC8 |
| 6 | Scheduler | 다음 실행 시각 계산(순수함수) | 시각 계산 테스트 | AC9 |
| 7 | SettingsStore | UserDefaults 영속화(주입형) | 저장/복원 테스트 | AC1 |
| 8 | AppState/ViewModel | 서비스 오케스트레이션(async) | build | — |
| 9 | SwiftUI Views | MenuBarExtra, PR목록, PR카드, 설정 | build | — |
| 10 | App 진입 | @main, .accessory, 알림 배선 | build | — |
| 11 | 번들 조립 | `Scripts/build-app.sh`(Info.plist, LSUIElement) | `.app` 조립·기동 | AC10 |
| 12 | 마감 | project.json commands, README, doctor | `beez doctor` healthy | — |

## 순서 원칙
1. 테스트 가능한 순수 로직(파싱/스케줄/커맨드구성)을 먼저 테스트로 보호.
2. 계약(모델·러너) → 서비스 → 뷰모델 → UI 순.
3. UI는 단위테스트 어려움 → build + 앱 기동으로 검증.
4. 게시(부작용)는 절대 자동 실행하지 않음 — 커맨드 "구성"만 테스트.

## 검증 명령
- `swift build`
- `swift test`
- `Scripts/build-app.sh && open <.app>` (수동 기동 확인)
