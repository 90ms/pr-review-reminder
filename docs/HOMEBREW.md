# Homebrew 배포 가이드

Developer ID가 없는 동안 binary Cask 대신 사용자의 Mac에서 소스를 빌드하는 개인
Formula를 사용한다. 공식 Cask 등록이나 Gatekeeper 우회는 목표로 하지 않는다.

## 구성

```text
pr-review-reminder
├── Scripts/build-app.sh
├── Scripts/pr-review-reminder
├── Scripts/render-homebrew-formula.sh
└── packaging/homebrew/       # tap 저장소 seed

homebrew-tap
├── Formula/pr-review-reminder.rb
└── .github/workflows/test.yml
```

Formula는 태그 source tarball을 SHA-256으로 검증하고 Swift release build를 수행한다.
앱은 Formula의 `libexec`에 설치되며 launcher가 실행과 `~/Applications` symlink를
관리한다. 설정과 히스토리는 Application Support에 있으므로 `brew upgrade` 후에도
유지된다.

## 현재 배포 상태

공개 [`90ms/homebrew-tap`](https://github.com/90ms/homebrew-tap)의 Formula는
`v0.5.1`을 제공한다. tap CI에서 source install, `brew test`,
`brew audit --strict`를 통과했다.

## 관리자의 Formula 갱신

새 릴리스 태그와 source tarball SHA를 준비한 뒤 Formula를 렌더링한다.

```bash
version=0.5.1
curl -L \
  "https://github.com/90ms/pr-review-reminder/archive/refs/tags/v${version}.tar.gz" \
  -o "/tmp/pr-review-reminder-${version}.tar.gz"
sha="$(shasum -a 256 "/tmp/pr-review-reminder-${version}.tar.gz" | awk '{print $1}')"

./Scripts/render-homebrew-formula.sh \
  "$version" \
  "$sha" \
  "/path/to/homebrew-tap/Formula/pr-review-reminder.rb"
```

렌더링 결과를 tap 저장소에 반영하고 source install, `brew test`,
`brew audit --strict`가 모두 통과하는지 확인한다.

## 사용자 명령

Homebrew 6 이상에서는 정규화된 이름으로 설치해 이 Formula만 신뢰한다.

```bash
brew install 90ms/tap/pr-review-reminder
pr-review-reminder --install-app
pr-review-reminder
```

이미 tap을 추가한 뒤 신뢰 오류가 발생했다면 다음과 같이 개별 Formula를 신뢰한다.

```bash
brew trust --formula 90ms/tap/pr-review-reminder
brew install pr-review-reminder
```

업데이트:

```bash
brew update
brew upgrade pr-review-reminder
```

앱의 **설정 → 일반 → 업데이트**에서도 같은 Formula의 현재/최신 버전을 확인하고 업데이트할 수
있다. 앱은 자동 업데이트하지 않으며 사용자가 설치 버튼을 누른 경우에만
`brew upgrade 90ms/tap/pr-review-reminder`를 실행한다. 진행 단계와 실패 명령을
표시하고 취소를 지원한다. 완료되면 새 앱을 실행하고 기존 인스턴스를 종료하며,
재실행 실패 시 **지금 다시 시작**으로 다시 시도할 수 있다.

제거:

```bash
pr-review-reminder --uninstall-app
brew uninstall pr-review-reminder
```

마지막 명령은 앱과 launcher를 제거하지만 Application Support의 사용자 히스토리와
설정은 보존한다.

## 릴리스별 Formula 갱신

초기에는 자동 병합하지 않는다.

1. 새 태그를 push한다.
2. source tarball SHA를 계산한다.
3. renderer로 Formula를 갱신한다.
4. tap 저장소에 PR을 만든다.
5. tap CI와 실제 Mac 설치·업데이트를 확인한 뒤 병합한다.

안정화 후 원본 Release workflow가 fine-grained token 또는 GitHub App으로 tap에
자동 PR을 생성하도록 확장할 수 있다.

## 보안 경계

- `xattr` 제거나 Gatekeeper 비활성화를 기본 설치법으로 안내하지 않는다.
- Formula는 HTTPS tag tarball과 고정 SHA-256을 사용한다.
- launcher는 기존 실제 앱을 덮어쓰지 않고 자신이 가리키는 symlink만 제거한다.
- 쓰기 권한이 필요한 `/Applications` 대신 기본적으로 `~/Applications`를 사용한다.
