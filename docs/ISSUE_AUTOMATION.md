# Synology Issue Automation

이 문서는 특정 GitHub 이슈를 Synology NAS의 Codex CLI로 구현하고 Draft PR까지
생성하는 선택적 자동화의 운영 계약을 정의한다. 자동화 코드는 공개 저장소에
포함하지만 인증 정보와 장비별 설정은 NAS에만 둔다.

## 목표와 비목표

자동화는 다음 흐름을 제공한다.

1. NAS 스케줄러 또는 수동 명령이 `codex-ready` 이슈를 찾는다.
2. Slack 채널에 이슈 요약과 **구현 시작** 버튼을 보낸다.
3. 허용된 Slack 사용자가 버튼을 누르면 이슈를 다시 검증하고 작업을 예약한다.
4. 워커가 최신 `main`을 별도 작업 디렉터리에 준비하고 Codex CLI를 실행한다.
5. Codex가 구현, 테스트, 관련 문서 갱신과 커밋을 수행한다.
6. 워커가 브랜치를 푸시하고 Draft PR을 만든 뒤 CI 결과를 Slack에 알린다.

자동 병합, 자동 릴리스, GitHub review·approval 게시, 승인되지 않은 이슈 실행은
범위에 포함하지 않는다. Synology Linux에서는 macOS SwiftUI 앱을 완전히 빌드할 수
없으므로 최종 `swift build`와 `swift test` 검증은 GitHub의 macOS CI가 담당한다.

## 구성 요소

```text
Synology Task Scheduler ── scan ──┐
                                 v
GitHub Issues <──── labels ── Automation Service ── Socket Mode ── Slack
                                 │
                                 v
                         isolated workspace
                         gh + codex CLIs
                                 │
                                 v
                    branch + Draft PR + macOS CI
```

- **Automation service**: 이슈 검색, Slack 상호작용, 작업 큐와 상태 기록을 담당하는
  장기 실행 프로세스다.
- **Scanner**: 서비스 내부 주기 실행 또는 NAS Task Scheduler에서 호출하는 수동
  스캔 명령이다.
- **Worker**: 승인된 이슈마다 격리된 clone을 만들고 Codex CLI를 실행한다.
- **SQLite state**: Slack 메시지 ID, 승인자, 실행 횟수와 오류를 NAS 볼륨에
  보존한다. GitHub 라벨은 사람이 확인할 수 있는 외부 상태로 사용한다.
- **GitHub macOS CI**: Linux NAS에서 수행할 수 없는 앱 빌드와 테스트를 검증한다.

Slack은 Socket Mode로 연결한다. 따라서 NAS에 공개 HTTP endpoint나 포트
포워딩을 만들 필요가 없다.

## 상태 모델

| GitHub 라벨 | 의미 |
|---|---|
| `codex-ready` | 관리자가 자동화 대상으로 승인한 이슈 |
| `codex-notified` | Slack 승인 메시지를 보낸 이슈 |
| `codex-running` | Slack 승인 후 워커가 점유한 이슈 |
| `codex-pr-open` | Draft PR 생성에 성공한 이슈 |
| `codex-failed` | 실행 또는 PR 생성에 실패한 이슈 |
| `codex-blocked` | 사람의 판단이나 추가 정보가 필요한 이슈 |

정상 상태 전이는 다음과 같다.

```text
codex-ready
  └─ scan ─> codex-ready + codex-notified
                └─ Slack 승인 ─> codex-running
                                    ├─ 성공 ─> codex-pr-open
                                    ├─ 실패 ─> codex-failed
                                    └─ 판단 필요 ─> codex-blocked
```

`codex-ready`는 관리자가 제거할 때까지 원래의 승인 표식으로 유지한다. 실행 상태
라벨은 서로 배타적으로 관리한다. `codex-failed` 이슈는 Slack의 **재시도** 버튼으로
다시 승인해야 하며 자동으로 재실행하지 않는다.

## 승인과 권한 경계

- 공개 이슈의 내용만으로 작업을 시작하지 않는다. 관리자만 붙일 수 있는
  `codex-ready` 라벨과 Slack 버튼 클릭이 모두 필요하다.
- `SLACK_ALLOWED_USER_IDS`에 등록된 사용자만 구현 또는 재시도를 승인할 수 있다.
- 버튼을 누른 시점에 이슈 상태, 기존 PR, 실행 이력과 허용 사용자를 다시 확인한다.
- 버튼 클릭은 브랜치 push와 Draft PR 생성까지에 대한 명시적 사용자 동작이다.
- PR은 항상 Draft로 생성하며 CI 성공 후에도 자동 병합하거나 review를 게시하지
  않는다.
- GitHub와 Codex 인증은 NAS에 로그인된 `gh`/`codex` CLI 세션에 위임한다.
- Slack 토큰, GitHub 인증 파일, Codex 세션과 실제 `.env`는 커밋하지 않는다.

## 작업 격리와 중복 방지

- 기본 동시 실행 수는 1이다.
- SQLite의 이슈별 lease와 `codex-running` 라벨을 함께 확인한다.
- 작업 시작 전 `Closes #<number>` 또는 이슈 번호를 참조하는 열린 PR과
  `codex/issue-<number>-*` 원격 브랜치를 확인한다.
- 각 실행은 NAS 데이터 볼륨 아래의 새 임시 디렉터리에서 최신 `origin/main`을
  clone한다. 앱 저장소 자체나 이전 실행 디렉터리를 재사용하지 않는다.
- 성공한 작업 디렉터리는 기본적으로 정리하고, 실패한 디렉터리는 제한된 기간 동안
  진단용으로 보존한다.
- 프로세스 timeout 후 Codex와 자식 프로세스를 종료하고 실패 상태로 전환한다.

GitHub 라벨 변경은 분산 트랜잭션이 아니므로 여러 NAS 인스턴스를 동시에 실행하지
않는다. 단일 서비스와 영속 SQLite lease가 지원 범위다.

## Codex 작업 계약

워커는 저장소의 `$implement-github-issue` 스킬을 명시적으로 호출한다. 스킬은 다음
규칙을 적용한다.

1. 저장소 지침과 이슈 전체를 읽고 모호하거나 위험한 요구는 `codex-blocked`로
   종료한다.
2. 최신 `main`에서 `codex/issue-<number>-<slug>` 브랜치를 만든다.
3. 이슈 범위만 구현하고 회귀 테스트를 추가한다.
4. 관련 README, 명세, 운영 문서와 CHANGELOG를 실제 동작에 맞게 갱신한다.
5. 논리 단위로 커밋하고 작업 트리가 깨끗한지 확인한다.
6. NAS에서 가능한 정적 검증을 실행하되 macOS 전용 검증은 CI에 맡긴다.
7. 보호 경로 변경이 필요하면 임의로 우회하지 않고 작업을 중단한다.

기본 보호 경로는 다음과 같다.

```text
.github/workflows/**
.agents/**
.harness/**
SECURITY.md
```

운영자가 이 경로 변경을 원하면 사람이 별도 브랜치에서 직접 작업하거나 향후
명시적인 일회성 허용 정책을 추가한다.

## 공개 설정과 비밀 설정

저장소에는 다음을 포함할 수 있다.

- Dockerfile과 Compose 예제
- Python 의존성 lock 또는 고정 버전
- `.env.example`
- NAS 설치·업데이트·백업 문서
- 자동화 서비스와 테스트
- `$implement-github-issue` 스킬

NAS에만 보관할 값은 다음과 같다.

```dotenv
SLACK_APP_TOKEN=xapp-...
SLACK_BOT_TOKEN=xoxb-...
SLACK_CHANNEL_ID=C...
SLACK_ALLOWED_USER_IDS=U123...,U456...
GITHUB_REPOSITORY=90ms/pr-review-reminder
```

`gh`와 `codex`의 인증 디렉터리는 자동화 전용 NAS 사용자만 읽을 수 있어야 한다.
컨테이너를 사용할 경우 읽기 전용 mount를 우선하고, 작업 볼륨과 상태 DB만 쓰기
가능하게 둔다.

## 장애 처리

Slack에는 이슈 번호, 현재 단계, 짧은 오류, 로그 식별자와 가능한 다음 동작만
표시한다. 토큰, 전체 환경 변수, 인증 파일 내용이나 민감한 CLI 출력을 보내지 않는다.

- 스캔 실패: 상태를 변경하지 않고 다음 주기에 재시도한다.
- Slack 전송 실패: `codex-notified`를 붙이지 않는다.
- Codex 실패/timeout: `codex-failed`로 전환하고 수동 재시도를 기다린다.
- 보호 경로 또는 불명확한 요구: `codex-blocked`로 전환한다.
- push/PR 실패: 로컬 결과를 보존하고 `codex-failed`로 전환한다.
- CI 실패: PR은 유지하며 Slack에 실패한 check 링크를 알린다.

## 구현 단계

1. 운영 계약과 상태 모델 문서화
2. `$implement-github-issue` 저장소 스킬 추가
3. 설정, GitHub gateway, SQLite 상태와 작업 큐 구현
4. Slack Socket Mode 알림과 승인 버튼 구현
5. Codex worker, Draft PR 생성과 CI 감시 구현
6. Docker/Compose와 Synology Task Scheduler 설치 흐름 추가
7. 단위 테스트, dry-run 검증과 사용자 문서 최신화

