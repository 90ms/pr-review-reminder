# 릴리스 가이드

정식 릴리스는 `v<semver>` 태그 push로 시작하며, GitHub Actions가 앱을 빌드하고
Developer ID로 서명한 뒤 Apple 공증과 stapling을 완료해야만 GitHub Release를 만든다.
unsigned 공개 릴리스는 허용하지 않는다.

## 저장소 secret

| 이름 | 내용 |
|---|---|
| `CERTIFICATE_P12_BASE64` | Developer ID Application 인증서 `.p12`의 base64 |
| `CERTIFICATE_PASSWORD` | `.p12` 암호 |
| `KEYCHAIN_PASSWORD` | CI 임시 keychain 암호 |
| `DEVELOPER_ID_APPLICATION` | `Developer ID Application: ...` 서명 identity |
| `APPLE_ID` | 공증용 Apple ID |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `APPLE_APP_PASSWORD` | app-specific password |

## 절차

1. `main` CI의 build, test, bundle validation이 성공했는지 확인한다.
2. `CHANGELOG.md`의 Unreleased 내용을 릴리스 버전으로 정리한다.
3. `v0.2.0`과 같은 annotated tag를 만들고 push한다.
4. Release workflow에서 서명 검증, `notarytool`, `stapler` 성공을 확인한다.
5. 생성된 ZIP을 깨끗한 macOS 계정에서 열어 Gatekeeper, 메뉴바 실행, CLI 진단을 점검한다.

```bash
git tag -a v0.2.0 -m "PR Review Reminder 0.2.0"
git push origin v0.2.0
```

릴리스 workflow는 태그에서 `APP_VERSION`을, GitHub run number에서 bundle build
number를 주입한다. 인증 정보가 하나라도 빠지면 공개 artifact 생성 전에 실패한다.

## 스크린샷

README용 화면은 실제 서명된 앱을 macOS에서 실행해 캡처한다. 메뉴 팝오버, PR 상세
Split diff, 히스토리 상세의 세 장을 `docs/assets/`에 저장하고 민감한 저장소명,
작성자, 코드, 토큰 사용량을 제거한 테스트 fixture 계정으로 촬영한다.
