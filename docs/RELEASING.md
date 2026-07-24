# 릴리스 가이드

Codex에서는 저장소에 포함된 `$release-pr-review-reminder` 스킬로 이 절차를 실행할 수
있다. 스킬은 준비 커밋과 CI 검증을 자동화하지만 태그 생성 전에는 정확한 버전·SHA를
확인하며, Homebrew tap 병합도 승인 범위 밖에서 임의로 수행하지 않는다.

릴리스는 `v<semver>` 태그 push로 시작한다. Developer ID secret이 모두 설정되어
있으면 서명·공증·stapling을 수행하고, 하나도 없으면 ad-hoc 서명 ZIP과 SHA-256을
공개한다. 일부 secret만 설정된 상태는 구성 오류로 실패한다.

Developer ID가 없는 배포에서는 Homebrew source build를 권장하며, GitHub ZIP은
macOS Privacy & Security에서 사용자의 명시적 승인이 필요할 수 있다.

## 선택적 서명·공증 secret

| 이름 | 내용 |
|---|---|
| `CERTIFICATE_P12_BASE64` | Developer ID Application 인증서 `.p12`의 base64 |
| `CERTIFICATE_PASSWORD` | `.p12` 암호 |
| `KEYCHAIN_PASSWORD` | CI 임시 keychain 암호 |
| `DEVELOPER_ID_APPLICATION` | `Developer ID Application: ...` 서명 identity |
| `APPLE_ID` | 공증용 Apple ID |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `APPLE_APP_PASSWORD` | app-specific password |
| `HOMEBREW_TAP_TOKEN` | `90ms/homebrew-tap`에 branch push와 PR 생성이 가능한 fine-grained token |

## 절차

1. `main` CI의 build, test, bundle validation이 성공했는지 확인한다.
2. `CHANGELOG.md`의 Unreleased 내용을 릴리스 버전으로 정리한다.
3. `HOMEBREW_TAP_TOKEN`이 설정되어 있는지 확인한다. 없으면 tap PR 단계만 건너뛴다.
4. `v0.3.0`과 같은 annotated tag를 만들고 push한다.
5. Release workflow에서 ZIP과 `.sha256` 생성을 확인한다.
6. 서명 모드라면 `notarytool`과 `stapler` 성공을 추가 확인한다.
7. 생성된 ZIP 또는 Homebrew 설치를 깨끗한 macOS 계정에서 검증한다.
8. workflow가 만든 `90ms/homebrew-tap` PR의 install/test/audit CI를 확인한 뒤 수동 병합한다.

```bash
git tag -a v0.3.0 -m "PR Review Reminder 0.3.0"
git push origin v0.3.0
```

릴리스 workflow는 태그에서 `APP_VERSION`을, GitHub run number에서 bundle build
number를 주입한다. 서명 관련 secret은 전부 설정하거나 전부 비워야 한다.
릴리스가 게시되면 태그 source tarball의 SHA-256으로 Formula를 렌더링하고 tap에
`automation/pr-review-reminder-<version>` branch와 PR을 만든다. tap `main`을 직접
수정하거나 자동 병합하지 않는다.

## 스크린샷

README용 화면은 실제 패키징된 앱을 macOS에서 실행해 캡처한다. 메뉴 팝오버, PR 상세
Split diff, 히스토리 상세의 세 장을 `docs/assets/`에 저장하고 민감한 저장소명,
작성자, 코드, 토큰 사용량을 제거한 테스트 fixture 계정으로 촬영한다.
