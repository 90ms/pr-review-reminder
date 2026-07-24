# PR Review Reminder — 스펙 (계약)

> macOS 메뉴바 앱. 내가 리뷰어인데 아직 안 본 PR을, 정해진 시간에 `gh`로 모아
> `claude`/`codex` CLI로 요약·리뷰하고, 사용자가 확인 후 인라인 코멘트/Approve를 남긴다.

- **버전**: 0.7
- **작성일**: 2026-07-24 (최신화)
- **상태**: 구현됨 — 43개 테스트 통과, 실제 PR 스모크 검증 완료. 아래 5.x/5.y 확장 반영.
- **미구현(보류)**: #2 세션 잔여 토큰 기반 리뷰 제한 (claude/codex CLI가 잔여 한도를 스크립트로 미노출).

### 구현·검증 현황 요약
- AC1–AC10: 코어(설정·수집·리뷰판정·AI파싱·커맨드구성·진단·스케줄·빌드) — 구현·테스트.
- AC11–AC15: 다국어(F1/F3)·스킬 주입(F4)·피드백 이슈(F5) — 구현·테스트.
- AC16–AC19: 리뷰 히스토리·캐시 복원·누적 집계(H1–H3) — 구현·테스트.
- 실측 스모크: claude/codex 실제 실행, 토큰·비용(예: 49,718 tokens · $0.4949), 인라인 라인 매핑 유효 확인.

---

## 1. Problem — 무엇이 불편한가
- 리뷰 요청이 여러 repo에 흩어져 있어 놓치기 쉽다.
- 리뷰 전 "이 PR이 뭘 하는지" 파악 비용이 크다.
- 그 결과 리뷰가 밀리고 PR 병목이 생긴다.

## 2. Outcome — 완료 후 관찰 가능한 동작
사용자가 앱을 실행하고 대상 org를 설정하면:
- 메뉴바에 리뷰 대기 PR 개수 배지가 뜬다.
- 설정된 시각/주기에 자동으로 리뷰 대기 PR을 수집한다.
- 각 PR에 대해 AI 요약 + 리뷰 포인트를 팝오버 카드에서 본다.
- 카드의 버튼으로 인라인 코멘트/일반 코멘트/Approve를 사용자 확인 후 게시한다.

## 3. In scope
- 대상 org/repo 설정 (기본 `fastlane-dev`, 변경 가능; 특정 repo만도 가능).
- `review-requested:@me` & 내가 아직 리뷰하지 않은 열린 PR 수집.
- PR 메타(제목/작성자/변경규모) + diff + 설명 수집.
- `claude` 또는 `codex` CLI로 요약·리뷰 포인트·인라인 코멘트 초안(JSON) 생성.
- 설정된 시각(매일 HH:mm) 또는 N시간 간격 스케줄 + 시스템 알림.
- 사용자 트리거로 인라인 코멘트 / 요약 코멘트 / Approve 게시.
- 설정 화면(org 경로, 스케줄, AI 툴 선택, 프롬프트 템플릿, 알림 on/off).
- CLI 의존성 진단(gh/claude/codex 설치·로그인 여부).

## 4. Out of scope
- AI의 자동(무검토) 게시.
- 팀 대시보드/공유.
- 자체 API 키 관리·과금 (CLI 구독 재사용으로 대체).
- GitHub 외 플랫폼.
- 코드 서명/공증/배포 파이프라인 (로컬 실행 가능한 `.app` 조립까지만).

## 5. Constraints
- **인증 위임**: 앱은 토큰을 저장/관리하지 않는다. GitHub는 `gh`, AI는 `claude`/`codex` CLI에 위임.
- **게시는 항상 사용자 액션**: 어떤 코멘트/Approve도 자동 게시 금지.
- **읽기/쓰기 분리**: 수집·요약은 자동, 게시는 수동 트리거.
- **없는 명령을 지어내지 않는다** (하네스 원칙). CLI 부재 시 진단 후 안내.
- 플랫폼: macOS 14+ (SwiftUI `MenuBarExtra`).
- 구현: SwiftPM 실행 타깃 + `.app` 번들 조립 스크립트. `swift build`로 검증 가능해야 함.

## 5.x v0.3 추가 기능 (요청 반영)
- **F1 앱 UI 언어**: `appLanguage`(system/korean/english), 기본 system(로케일 추종). 앱 전체 문자열 현지화.
- **F2 PR 상세 창**: 목록에서 PR 클릭 시 리사이즈 가능한 큰 창에서 요약·리뷰포인트·인라인·diff 전문 확인.
- **F3 리뷰 출력 언어**: `reviewLanguage`(system/korean/english), 기본 system. AI 프롬프트에 언어 지시 주입.
- **F4 리뷰 스킬/가이드라인**: `reviewSkill` 텍스트(파일에서 불러오기 가능) → 프롬프트 `{{SKILL}}`로 주입.
- **F5 피드백→이슈**: "의견 남기기" 입력 → (AI로 정돈) → `gh issue create` 커맨드 **구성·미리보기**.
  피드백 레포(`feedbackRepository`) 미설정 시 **실제 등록 보류**(커맨드만 표시). 등록도 사용자 액션.

### AC (추가)
- **AC11**: `AppLanguage.resolved(locale:)`가 system→로케일(ko/en), 명시 선택→해당 언어를 반환.
- **AC12**: `L10n`이 선택 언어로 키를 번역하고, 누락 키는 키를 폴백 반환.
- **AC13**: `buildPrompt`가 reviewLanguage 지시와 `{{SKILL}}`를 정확히 주입한다.
- **AC14**: `FeedbackService.createIssueCommand`가 올바른 `gh issue create` 인자를 구성한다.
- **AC15**: 피드백 정돈(AI)이 제목/본문 JSON을 파싱한다.

## 5.y v0.7 리뷰 히스토리 (요청 반영)
- **H1 저장**: 리뷰 완료 시 `ReviewRecord`(repo·번호·제목·작성자·url·headSha·tool·시각·analysis·usage·details) 영구 저장(Application Support JSON).
- **H2 캐시 복원**: 새로고침 시 각 PR의 headSha를 gh로 확인(토큰 0) → 히스토리에 같은 `repo#번호@headSha` 기록이 있으면 **AI 재호출 없이** analysis/usage/details 복원(state=.done).
- **H3 히스토리 화면**: 과거 리뷰 목록 + 각 요약/리뷰포인트 + **누적 토큰·비용 집계**.
- **비고**: #2(세션 잔여 토큰 기반 리뷰 제한)는 claude/codex CLI가 잔여 한도를 스크립트로 노출하지 않아 **보류**.

### AC (추가)
- **AC16**: `HistoryStore.upsert`가 같은 id(`repo#num@sha`)는 교체, 다른 SHA는 신규 추가한다.
- **AC17**: `HistoryStore.record(repo,num,sha)`가 일치 기록을 반환/미일치 시 nil.
- **AC18**: `HistoryStore.totals()`가 전체 기록의 토큰·비용 합을 정확히 집계한다.
- **AC19**: 저장/로드 라운드트립이 `ReviewRecord`를 보존한다.

## 6. Behavior — 입력/출력/상태/에러

### 6.1 수집
- 입력: org(필수), 선택적 repo 목록, 현재 gh 로그인 사용자.
- 처리: `gh search prs --review-requested=@me --state=open --owner <org>` →
  각 PR의 리뷰 목록을 조회해 **내가 남긴 리뷰가 없는 것만** 남김.
- 출력: `PullRequest` 목록 (repo, number, title, author, additions, deletions, url).
- 에러: gh 미설치/미로그인 → 수집 중단 + 진단 메시지. 네트워크 실패 → 이전 결과 유지 + 에러 표기.

### 6.2 분석
- 입력: PR diff + body + 파일 목록, 선택된 AI 툴, 프롬프트 템플릿.
- 처리: CLI에 프롬프트 전달, 응답을 §7 JSON 스키마로 파싱.
- 출력: `summary`, `reviewPoints[]`, `inlineComments[]`.
- 에러: CLI 실패/타임아웃 → 해당 PR은 "분석 실패" 상태로 표기, 다른 PR 진행. JSON 파싱 실패 → 원문을 요약 필드에 넣고 인라인 코멘트는 비움.

### 6.3 스케줄/알림
- 매일 지정 시각 또는 N시간 간격으로 수집→분석 실행.
- 신규 대기 PR 발견 시 시스템 알림 + 배지 갱신.
- 앱 실행 중일 때 동작(백그라운드 데몬/launchd는 범위 밖).

### 6.4 게시
- 인라인 코멘트: 사용자가 카드에서 편집/확정 후 `gh api .../pulls/{n}/comments` 게시.
- 요약 코멘트: `gh pr comment`.
- Approve: `gh pr review --approve`.
- 모든 게시 전 대상/내용을 사용자에게 보여주고, 명시적 클릭으로만 실행.

## 7. AI 출력 스키마
```json
{
  "summary": "이 PR이 무엇을 하는지 2~3줄",
  "reviewPoints": [
    { "severity": "high|medium|low", "text": "리뷰 포인트" }
  ],
  "inlineComments": [
    { "path": "src/foo.ts", "line": 42, "side": "RIGHT", "body": "코멘트" }
  ]
}
```

## 8. Acceptance criteria (독립 검증 가능)
- **AC1**: `AppSettings`가 org/repo/스케줄/AI툴/프롬프트/알림 값을 저장·복원한다.
- **AC2**: gh PR 검색 JSON 출력을 `PullRequest` 배열로 파싱한다 (필드 매핑 정확).
- **AC3**: 리뷰 목록에서 "내가 리뷰했는지"를 로그인 사용자 기준으로 정확히 판정한다.
- **AC4**: AI JSON 응답을 `Analysis(summary, reviewPoints, inlineComments)`로 파싱한다.
- **AC5**: AI 응답이 비-JSON/코드펜스 포함일 때도 관대하게 파싱하거나 원문 폴백한다.
- **AC6**: 선택한 AI 툴에 따라 올바른 CLI 커맨드/인자를 구성한다 (claude `-p`, codex `exec`).
- **AC7**: 게시 커맨드(인라인/요약/approve)를 올바른 인자로 구성한다 (실제 게시는 사용자 액션).
- **AC8**: CLI 의존성 진단이 설치/로그인 상태를 정확히 보고한다.
- **AC9**: 스케줄러가 매일 HH:mm / N시간 간격 다음 실행 시각을 정확히 계산한다.
- **AC10**: 전체 패키지가 `swift build`로 경고 없이 빌드되고, `.app` 번들이 조립되어 실행된다.

## 9. Verification
- AC1~AC9: `swift test` 단위 테스트 (순수 로직 + 커맨드 구성 + 파싱 + 스케줄 계산).
- AC6/AC7: 주입 가능한 `ProcessRunner` 목(mock)으로 커맨드 구성 검증 (실제 게시 X).
- AC10: `swift build` 성공 + 번들 조립 스크립트 실행 + `.app` 기동 확인.
- 통합(수동): 실제 gh 로그인 상태에서 fastlane-dev 대상 수집 1회.

## 10. Risks and rollback
- **인라인 라인 매핑**: diff 라인 ↔ GitHub API `line/side` 정합성이 최대 난관. → v1은 `line`(파일 절대 라인) + `RIGHT` 기준, 실패 시 일반 코멘트로 폴백.
- **AI 비결정 출력**: JSON 강제 실패 가능 → 관대한 파서 + 원문 폴백(AC5).
- **큰 diff**: CLI 인자/토큰 한계 → 파일별 분할 또는 상한 truncate + 사용자 표기.
- **롤백**: 앱은 로컬 전용이라 상태 롤백 부담 없음. 게시는 사용자 확인 기반이라 자동 부작용 없음.
