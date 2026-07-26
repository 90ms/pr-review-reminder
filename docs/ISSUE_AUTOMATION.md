# Synology Issue Automation

이 문서는 특정 GitHub 이슈를 Synology NAS의 Codex CLI로 구현하고 Draft PR까지
생성하는 선택적 자동화의 운영 계약을 정의한다. 자동화 코드는 공개 저장소에
포함하지만 인증 정보와 장비별 설정은 NAS에만 둔다.

## 목표와 비목표

자동화는 다음 흐름을 제공한다.

1. NAS 스케줄러 또는 수동 명령이 `codex-ready` 이슈를 찾는다.
2. Slack 채널에 이슈 요약과 **구현 시작** 버튼을 보낸다.
3. 허용된 Slack 사용자가 버튼을 누르면 이슈를 다시 검증하고 작업을 예약한다.
4. Controller가 시작 알림을 Slack에 보내고 최신 `main`을 별도 작업 디렉터리에
   준비해 승인된 작업을 파일 queue에 넣는다.
5. 격리 Runner의 Codex가 구현, 테스트, 관련 문서 갱신과 커밋을 수행한다.
6. Controller가 결과와 저장소 경계를 검증하고 브랜치를 푸시해 Draft PR을 만든다.
   완료·실패·차단 결과는 원본 승인 메시지의 브로드캐스트 답글로 알린다.
7. GitHub Actions 결과도 같은 Slack 스레드와 원본 상태 메시지에 반영한다.

자동 병합, 자동 릴리스, GitHub review·approval 게시, 승인되지 않은 이슈 실행은
범위에 포함하지 않는다. Synology Linux에서는 macOS SwiftUI 앱을 완전히 빌드할 수
없으므로 최종 `swift build`와 `swift test` 검증은 GitHub의 macOS CI가 담당한다.

## 구성 요소

```text
Synology Task Scheduler ── scan ──> Controller <── Socket Mode ──> Slack
                                       │  ▲
                  GitHub Issues/PR <── gh  │ result
                                       │  │
                              file queue  │
                                       v  │
                                  Codex Runner ──> allowlist proxy
                                       │
                              isolated workspace
```

- **Controller**: 이슈 검색, Slack 상호작용, workspace 준비, 작업 큐, 결과 검증,
  GitHub push와 상태 기록을 담당하는 장기 실행 프로세스다.
- **Scanner**: 서비스 내부 주기 실행 또는 NAS Task Scheduler에서 호출하는 수동
  스캔 명령이다.
- **Codex Runner**: Controller가 준비한 승인 작업만 소비하고, 기존 Codex CLI
  로그인으로 저장소 수정·테스트·문서 갱신과 로컬 커밋을 수행한다. GitHub나 Slack
  인증을 소유하지 않는다.
- **SQLite state**: Slack 메시지 ID, 승인자, 실행 횟수와 오류를 NAS 볼륨에
  보존한다. GitHub 라벨은 사람이 확인할 수 있는 외부 상태로 사용한다.
- **GitHub macOS CI**: Linux NAS에서 수행할 수 없는 앱 빌드와 테스트를 검증한다.

Slack은 Socket Mode로 연결한다. 따라서 NAS에 공개 HTTP endpoint나 포트
포워딩을 만들 필요가 없다.

Controller와 Runner는 서로 다른 Docker network에 둔다. Controller는 GitHub와
Slack에 접근하지만 Runner network에는 참여하지 않는다. Runner는 외부 route가 없는
internal network에서 인증 정보가 없는 egress proxy에만 연결하며, proxy는 TLS
`CONNECT` 대상을 `*.openai.com`과 `*.chatgpt.com`으로 제한한다.

## Controller–Runner 작업 프로토콜

Synology에서 Controller와 Codex Runner는 네트워크 API나 Docker socket 대신
`DATA_DIR` 아래의 파일 큐로 통신한다. Controller는 승인 시 최신 `main`을 clone하고
다음 값이 포함된 버전 지정 JSON 요청을 atomic rename으로 게시한다.

- 임의 UUID 작업 ID와 프로토콜 버전
- 저장소, 이슈 snapshot, 승인자
- 시작 base SHA와 허용된 작업 branch
- 공유 workspace의 정규화된 상대 경로
- 작업 timeout

Runner는 상대 경로가 workspace root 밖으로 나가지 않는지 다시 검증하고, 구조화된
완료·실패·차단 결과만 별도 결과 디렉터리에 atomic rename으로 기록한다. 이슈 본문은
공개 GitHub에서 읽은 신뢰할 수 없는 요구 사항이며 프로토콜이나 저장소 지침을
덮어쓸 수 없다. 큐에는 인증 정보나 환경 변수를 기록하지 않는다.

Runner는 시작 시 heartbeat를 게시한다. Controller는 heartbeat가 없거나 오래된 경우
작업을 큐에 넣지 않고 즉시 실패시켜 승인 요청이 무기한 대기하지 않도록 한다. 실행
중 Runner가 중단되면 남은 `running` 요청은 다음 시작 시 다시 대기열로 복구한다.

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
라벨은 서로 배타적으로 관리한다. `codex-failed`와 `codex-blocked` 이슈는 원인을
확인하고 조치한 뒤 Slack의 **재시도** 버튼으로 다시 승인해야 하며 자동으로
재실행하지 않는다.

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

## Synology Runner 격리 경계

일부 Synology 커널은 Codex의 bubblewrap user namespace와 legacy Landlock/seccomp
방식을 모두 지원하지 않는다. 이 배포에서는 `CODEX_RUNNER_MODE=outer-container`를
운영자가 명시했을 때만 Codex 내부 샌드박스를 우회하고 Runner 컨테이너 자체를 실행
경계로 사용한다. Codex CLI가 이 플래그를 외부 샌드박스용이라고 정의하더라도,
지원되는 Linux 호스트에서 `workspace-write`를 사용하는 것보다 방어 계층이 적다는
잔여 위험은 유지된다.

Runner에는 다음 제한을 모두 적용한다.

- GitHub·Slack 환경 변수, `gh` CLI, Docker socket과 NAS 공유 폴더를 제공하지 않는다.
- 승인된 workspace, 파일 큐와 Codex 로그인 디렉터리만 mount한다.
- read-only root filesystem, 모든 capability 제거와 `no-new-privileges`를 적용한다.
- 동시 작업을 하나로 제한하고 각 명령에 timeout을 적용한다. 일부 Synology 커널은
  cgroup PID·CPU·메모리 제한을 지원하지 않으므로 기본 Compose에서 해당 필드를
  강제하지 않는다.
- 외부 통신은 OpenAI/ChatGPT allowlist proxy만 통과한다.
- Controller는 Codex와 GitHub 인증 값을 생성 결과에서 다시 찾아 유출이 의심되면
  push하지 않는다.
- Runner가 변경한 Git config를 폐기하고 고정 origin과 비활성 hook 설정을 복원한 뒤,
  승인된 base SHA의 후손인지 확인한다.
- Synology bind mount의 실행 비트 표현 차이가 전체 파일 변경으로 오인되지 않도록
  격리 checkout의 `core.fileMode`를 끄고 내용 변경만 검증한다.

`privileged`, `SYS_ADMIN`, Docker socket 또는 `seccomp=unconfined`으로 bwrap을
강제하는 구성은 지원하지 않는다. 더 강한 격리가 필요한 운영자는 user namespace를
지원하는 별도 Linux VM에서 Runner를 실행해야 한다.

## 작업 격리와 중복 방지

- 기본 동시 실행 수는 1이다.
- SQLite의 이슈별 lease와 `codex-running` 라벨을 함께 확인한다.
- 작업 시작 전 `Closes #<number>` 또는 이슈 번호를 참조하는 열린 PR과
  `codex/issue-<number>-*` 원격 브랜치를 확인한다.
- 각 실행은 NAS 데이터 볼륨 아래의 새 임시 디렉터리에서 최신 `origin/main`을
  clone한다. 앱 저장소 자체나 이전 실행 디렉터리를 재사용하지 않는다.
- 성공한 작업 디렉터리는 기본적으로 정리하고, 실패한 디렉터리는 운영자가 확인하고
  정리할 때까지 진단용으로 보존한다.
- 프로세스 timeout 후 Codex와 자식 프로세스를 종료하고 실패 상태로 전환한다.
- 서비스가 중단되어 lease가 만료되면 다음 스캔에서 `codex-failed`로 복구하고 기존
  Slack 메시지에 **재시도** 버튼을 표시한다.

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
컨테이너에서는 `gh` 설정을 읽기 전용으로 mount한다. Codex 인증 저장소는 세션 갱신을
위해 쓰기 가능해야 하므로 별도 경로로 제한하고 다른 NAS 데이터는 mount하지 않는다.

## 장애 처리

Slack에는 이슈 번호, 현재 단계, 짧은 오류, 로그 식별자와 가능한 다음 동작만
표시한다. 토큰, 전체 환경 변수, 인증 파일 내용이나 민감한 CLI 출력을 보내지 않는다.

- 스캔 실패: 상태를 변경하지 않고 다음 주기에 재시도한다.
- Slack 전송 실패: `codex-notified`를 붙이지 않는다.
- Codex 실패/timeout: `codex-failed`로 전환하고 Slack 재시도를 기다린다.
- 보호 경로 또는 불명확한 요구: `codex-blocked`로 전환하고 원인과 재시도 버튼을
  표시한다.
- push/PR 실패: 로컬 결과를 보존하고 `codex-failed`로 전환한다.
- CI 실패: PR은 유지하며 Slack에 실패한 check 링크를 알린다.
- 구현 시작, 완료와 실패·차단은 승인자에게 멘션되는 Slack 브로드캐스트 답글로
  알리고 CI 결과도 같은 방식으로 채널에 알린다. 원본 승인 메시지는 최신 상태와
  재시도 동작을 유지한다.

## 구현 상태

- `$implement-github-issue` 저장소 스킬과 구조화 완료 보고
- 설정, GitHub CLI gateway, SQLite lease와 단일 작업 큐
- Slack Socket Mode 알림, 허용 사용자 승인, 실행 생명주기 알림과 실패·차단 재시도
- 격리 clone, Codex timeout, 보호 경로 검사, branch push와 Draft PR
- GitHub check 감시와 Slack 결과 갱신
- 만료 lease 복구와 중복 알림·중복 실행 방지
- Docker/Compose, Slack manifest, 라벨 설정 스크립트와 Synology 운영 가이드
- Python 단위 테스트와 GitHub Actions 자동 검증

## 다음 개선: 실행 관찰성

현재 Slack은 작업 시작과 최종 결과를 알리지만 Codex 실행 중에는 운영자가 NAS에서
프로세스와 queue를 직접 확인해야 한다. 다음 변경은 로그 원문을 Slack으로 보내지
않고 구조화된 상태만 제공하는 것을 목표로 한다.

1. Runner가 job별 상태 파일에 `queued`, `claimed`, `codex_running`,
   `result_ready` 단계와 시작·갱신 시각을 atomic write한다.
2. Codex subprocess와 별개의 heartbeat loop를 두어 장시간 실행 중에도 Runner와
   작업 생존 상태를 구분한다.
3. Controller가 저장소 준비, queue 대기, Codex 실행, 결과 검증, push, Draft PR,
   CI 단계와 경과 시간을 하나의 모델로 합친다.
4. Slack 원본 승인 메시지를 60초보다 자주 갱신하지 않으며 단계가 바뀌면 즉시
   갱신한다. 새 채널 메시지를 반복 전송하지 않는다.
5. 허용된 사용자를 위한 **상태 새로고침** 버튼을 제공하고, stale heartbeat나
   timeout 임박은 같은 스레드에 한 번만 경고한다.
6. Codex stdout/stderr, prompt, 토큰과 인증 값은 상태 메시지에 포함하지 않는다.
   향후 세부 이벤트를 사용하더라도 허용 목록 기반의 단계 정보만 노출한다.

작업 취소는 process group 종료, queue 취소 신호와 최종 상태 경합을 별도로 설계해야
하므로 첫 관찰성 변경에는 포함하지 않는다.
