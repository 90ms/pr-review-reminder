# 실행 계획 — PR Review Reminder

> 상태 기준일: 2026-07-24. 완료된 구현과 남은 운영 작업을 구분한다.

기준 계약은 [`docs/SPEC.md`](../docs/SPEC.md)다. 모든 GitHub 쓰기는 사용자의
명시적 액션으로만 시작하며 테스트와 CI에서는 실제 게시하지 않는다.

## 완료

| 영역 | 완료 내용 | 검증 |
|---|---|---|
| 공개 저장소 | MIT, CI, 커뮤니티 문서, 이슈/PR 템플릿 | GitHub Actions |
| 리뷰 정확성 | 재요청 보존, 게시 전 head SHA 검증 | 서비스/AppState 테스트 |
| 실행 제어 | 10분 timeout, 프로세스 종료, 사용자 취소 UI | runner/AppState 테스트 |
| GitHub 견고성 | 읽기 재시도, 원자적 review 게시, diff 실패 노출 | 명령/오류 테스트 |
| 규모 | 검색 최대 1,000개, head SHA 최대 6개 병렬 조회 | 서비스 테스트 |
| 히스토리 | 상세/diff, 현재 head 재리뷰, 보존·삭제·저장 해제 | 저장소/모델 테스트 |
| 비용 | Codex 단가 추정, 기간별 로컬 토큰 예산 | 모델/서비스 테스트 |
| UI | 긴 줄 가로 스크롤, 동적 제목, 앱 아이콘, 다음 실행, 기본 접근성 label | build + 수동 확인 대상 |
| 동시성 | Swift 6 language mode | macOS 15 CI build/test/bundle |
| 배포 기반 | ad-hoc ZIP/checksum과 선택적 Developer ID 서명·공증 workflow | main CI |
| Homebrew 배포 | 공개 tap, 0.2.2 source Formula, launcher, install/test/strict audit CI | tap CI + main CI |
| 최신 릴리스 | 0.2.2 ad-hoc ZIP/checksum과 Homebrew source 설치 | Release workflow + tap CI |
| 상세 화면 | 리뷰·변경 내용·나란히 레이아웃, diff 오류·빈 결과·재시도 상태 | AppState 테스트 + main CI |
| 업데이트 UX | 단계별 상태·실패 원인, 프로세스 취소, 링크 갱신, 즉시 재시작 | 서비스 테스트 + main CI |
| 저장 진단 | 설정·히스토리 위치·크기·저장 시각·오류 표시, 손상 JSON 백업 | 저장소 테스트 + main CI |
| GitHub 관찰성 | 새로고침 성공·실패, 재시도, rate limit, 검색 상한 표시 | 서비스/AppState 테스트 + main CI |
| Diff 탐색 | 파일 검색, 변경 줄 이동, 인라인 코멘트의 파일·side·line 이동 | parser/AppState 테스트 + main CI |
| 예약 실행 이력 | 최근 20건 성공·실패 보존, 설정 표시, 실패 알림 | 저장소/AppState 테스트 + main CI |
| macOS 운영 | 로그인 시 실행, 진행 중 작업 종료 확인 | main CI + macOS 수동 체크리스트 |
| 릴리스 연계 | 태그 릴리스 후 검토 가능한 tap Formula PR 생성 | Release/tap CI |
| 문서 | README, SPEC, CHANGELOG, 소개·릴리스 문서 | 구현과 상호 검토 |

## 다음 마일스톤

### P0 — 실제 macOS 제품 검증

- 실제 패키징 앱으로 최초 실행, CLI 탐지, 알림 권한, 스케줄, 취소를 점검한다.
- VoiceOver 읽기 순서와 전체 키보드 탐색을 감사한다.
- 테스트 fixture 계정으로 메뉴, PR 상세, 히스토리 상세 스크린샷/GIF를 만든다.
- 여러 창에서 언어 변경과 제목 갱신을 확인한다.

완료 조건: 민감정보가 없는 실제 화면 자료와 수동 검증 체크리스트가 저장소에 포함된다.

체크 항목과 증적 위치는
[`docs/MACOS_VALIDATION.md`](../docs/MACOS_VALIDATION.md)에 유지한다.

## 커밋·검증 원칙

1. 기능, 테스트, 문서는 검토 가능한 독립 커밋으로 유지한다.
2. 쓰기 명령은 자동 재시도하지 않는다.
3. 각 커밋은 `git diff --check`와 관련 테스트를 통과해야 한다.
4. `main`은 다음 CI를 항상 통과해야 한다.

```bash
swift build
swift test
./Scripts/build-app.sh
```

5. 실제 GitHub 게시와 릴리스 태그 생성은 별도 명시적 승인 없이 수행하지 않는다.
