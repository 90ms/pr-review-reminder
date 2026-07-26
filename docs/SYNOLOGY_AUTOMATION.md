# Synology Issue Automation Setup

이 기능은 `codex-ready`가 붙은 GitHub 이슈를 Slack에서 한 번 더 승인한 뒤, Synology
NAS의 Codex CLI로 구현하고 Draft PR을 만드는 선택적 운영 도구다. PR 병합, review,
approval과 릴리스는 자동화하지 않는다. 설계와 상태 전이는
[ISSUE_AUTOMATION.md](ISSUE_AUTOMATION.md)를 참고한다.

## 요구 사항

- Container Manager를 실행할 수 있는 Synology NAS
- GitHub와 Slack, Codex 서비스로 나갈 수 있는 HTTPS/WebSocket 연결
- 자동화 전용 Synology 사용자와 해당 사용자의 home directory
- 저장소 push와 이슈 라벨 권한이 있는 `gh` 로그인
- NAS에서 완료한 Codex CLI 로그인
- Slack App을 설치할 수 있는 workspace 권한

컨테이너는 `linux/amd64` 또는 `linux/arm64`에서 Python, Node, GitHub CLI와 Codex
CLI 패키지가 제공되는 환경을 전제로 한다. Synology 모델의 CPU와 Container Manager
지원 여부를 먼저 확인한다.

## 보안 전제

OpenAI의 비대화형 Codex 안내는 API key를 자동화의 기본으로 권장하며, ChatGPT 관리
인증을 공개·오픈소스 저장소의 CI/CD에 주입하지 말라고 경고한다. 이 구성은 GitHub
runner에 인증을 전달하지 않고 개인 NAS의 격리 컨테이너에서 저장된 Codex CLI 로그인을
사용하지만, 공개 이슈 본문은 여전히 신뢰할 수 없는 입력이다.

따라서 다음 조건을 모두 유지해야 한다.

- `codex-ready` 라벨을 붙일 수 있는 사람을 저장소 관리자로 제한한다.
- Slack 승인 사용자를 `SLACK_ALLOWED_USER_IDS`로 최소화한다.
- 승인 전에 이슈 제목과 본문을 사람이 읽는다.
- 컨테이너에 Docker socket, SSH key, 다른 저장소나 NAS 공유 폴더를 mount하지 않는다.
- 첫 실행과 정책 변경 후에는 `DRY_RUN=true`로 확인한다.
- 자동 생성 PR은 Draft로 유지하고 macOS CI와 diff를 사람이 검토한다.

Codex 인증 저장소는 세션 갱신 때문에 쓰기 가능한 mount다. 비밀번호처럼 취급하고
자동화 전용 NAS 사용자만 읽을 수 있게 한다. `gh` 설정은 읽기 전용으로 mount한다.

## 1. Slack App 만들기

Slack App 관리 화면에서 **Create New App → From an app manifest**를 선택하고
[`slack-app-manifest.yml`](../automation/synology/slack-app-manifest.yml)을
가져온다.

1. App을 workspace에 설치하고 `xoxb-`로 시작하는 Bot token을 복사한다.
2. **Basic Information → App-Level Tokens**에서 `connections:write` scope를 가진
   token을 만들고 `xapp-` 값을 복사한다.
3. 알림 채널에 App을 초대한다.
4. 채널 ID와 구현을 승인할 Slack user ID를 확인한다.

Bot은 메시지 게시를 위한 `chat:write`만 요청한다. Socket Mode에서는 공개 Request
URL이나 NAS 포트 포워딩이 필요 없다.

## 2. NAS 전용 계정에서 CLI 로그인

자동화 전용 Synology 사용자로 로그인한 셸에서 인증한다. Container Manager만
사용하는 환경이라면 임시 도구 컨테이너 또는 별도 Linux 셸에서 동일한 host
directory를 대상으로 로그인해야 한다.

```bash
gh auth login --hostname github.com --git-protocol https
gh auth status

codex login
codex --version
```

기본 경로는 다음과 같다.

```text
/volume1/homes/automation/.config/gh
/volume1/homes/automation/.codex
```

실제 경로가 다르면 `.env`의 `GH_CONFIG_DIR`, `CODEX_HOME_DIR`를 변경한다. 토큰이나
인증 JSON을 저장소, Slack, GitHub 이슈에 붙여 넣지 않는다.

## 3. 설정 파일 준비

NAS에 저장소를 clone한 뒤 예제를 복사한다.

```bash
cd /volume1/docker
git clone https://github.com/90ms/pr-review-reminder.git
cd pr-review-reminder/automation/synology
cp .env.example .env
chmod 600 .env
mkdir -p /volume1/docker/pr-review-issue-worker/data
```

`.env`에서 다음은 반드시 실제 값으로 변경한다.

```dotenv
PUID=1026
PGID=100
GH_CONFIG_DIR=/volume1/homes/automation/.config/gh
CODEX_HOME_DIR=/volume1/homes/automation/.codex
SLACK_APP_TOKEN=xapp-...
SLACK_BOT_TOKEN=xoxb-...
SLACK_CHANNEL_ID=C...
SLACK_ALLOWED_USER_IDS=U...
```

Synology 사용자 UID/GID는 `id automation`으로 확인한다. 초기
`DRY_RUN=true`는 유지한다.

## 4. GitHub 라벨 만들기

다음 스크립트는 라벨을 생성하거나 설명과 색상을 맞춘다. GitHub에 쓰는 동작이므로
내용을 확인한 뒤 한 번만 직접 실행한다.

```bash
GITHUB_REPOSITORY=90ms/pr-review-reminder \
  ./scripts/setup-github-labels.sh
```

## 5. 빌드와 진단

```bash
docker compose build
docker compose run --rm issue-worker doctor
```

진단은 Git, `gh`, Codex CLI와 데이터 경로를 확인한다. 인증 오류가 나면 mount 경로,
PUID/GID와 host의 `gh auth status`를 먼저 확인한다.

## 6. Dry run

서비스를 시작하고 테스트 이슈에 `codex-ready`를 붙인다.

```bash
docker compose up -d
docker compose logs -f issue-worker
```

Slack의 **구현 시작**을 누르면 Codex가 격리 clone에서 작업하지만 `DRY_RUN=true`인
동안 GitHub branch push와 Draft PR 생성은 수행하지 않는다. 실패 작업 디렉터리는
`DATA_DIR/workspaces`에 남아 diff와 결과를 확인할 수 있다.

결과와 보호 경로 차단을 확인한 뒤 `.env`를 다음처럼 바꾸고 서비스를 다시 만든다.

```dotenv
DRY_RUN=false
```

```bash
docker compose up -d --force-recreate
```

## 7. 수동 또는 예약 스캔

기본 설정은 실행 중인 Socket Mode 서비스가 5분마다 스캔한다.

```dotenv
ENABLE_INTERNAL_SCANNER=true
SCAN_INTERVAL_SECONDS=300
```

즉시 한 번 스캔하려면:

```bash
docker compose exec -T issue-worker pr-issue-worker notify
```

Synology **제어판 → 작업 스케줄러**로 스캔 시각을 통제하려면 내부 스캐너를 끈다.

```dotenv
ENABLE_INTERNAL_SCANNER=false
```

서비스를 재생성한 뒤 사용자 정의 스크립트를 원하는 주기로 등록한다.

```bash
cd /volume1/docker/pr-review-reminder/automation/synology
docker compose exec -T issue-worker pr-issue-worker notify
```

버튼 상호작용을 받으려면 `issue-worker` 서비스 자체는 항상 실행 중이어야 한다.
SQLite와 `codex-notified` 라벨이 수동·예약 스캔의 중복 메시지를 막는다.

## 업데이트와 백업

```bash
git pull --ff-only
docker compose build --pull
docker compose up -d --force-recreate
```

백업 대상은 `.env`, Codex/gh 인증 directory와 `DATA_DIR/state.sqlite3`다. 실행 중인
SQLite를 복사하기보다 서비스를 잠시 중지하거나 Synology snapshot을 사용한다.
`DATA_DIR/workspaces`는 실패 분석이 필요하지 않으면 백업하지 않아도 된다.

## 문제 해결

### Slack 메시지는 오지만 버튼이 반응하지 않음

- Socket Mode가 켜져 있는지 확인한다.
- App token이 `xapp-`이고 `connections:write` scope가 있는지 확인한다.
- `docker compose logs issue-worker`에서 WebSocket 재연결 오류를 확인한다.
- 클릭한 사용자가 `SLACK_ALLOWED_USER_IDS`에 있는지 확인한다.

### clone은 되지만 push가 실패함

- `gh` mount 경로와 `gh auth status`를 확인한다.
- GitHub 계정에 저장소 push 권한이 있는지 확인한다.
- 컨테이너는 clone마다 로컬 Git credential helper를 `gh auth git-credential`로
  설정한다. SSH key는 사용하지 않는다.

### 작업이 계속 `codex-running`임

- `JOB_TIMEOUT_SECONDS`와 로그를 확인한다.
- `LEASE_SECONDS`는 `JOB_TIMEOUT_SECONDS`보다 길어야 하며 시작 시 검증된다.
- 프로세스를 강제 종료한 경우 lease가 만료되면 다음 스캔이 이슈를
  `codex-failed`로 전환하고 기존 메시지에 **재시도** 버튼을 복구한다.
- 재시도 전에 상태 DB와 남은 workspace의 로그와 diff를 확인한다.

### macOS 테스트를 NAS에서 실행할 수 없음

정상적인 제한이다. NAS는 가능한 정적 검사와 변경 작업만 수행하고, Draft PR이
생성되면 기존 GitHub Actions의 macOS job이 `swift build`와 `swift test`를 실행한다.
