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
| 문서 | README, SPEC, CHANGELOG, 소개·릴리스 문서 | 구현과 상호 검토 |

## 다음 마일스톤

### P0 — 실제 macOS 제품 검증

- 실제 패키징 앱으로 최초 실행, CLI 탐지, 알림 권한, 스케줄, 취소를 점검한다.
- VoiceOver 읽기 순서와 전체 키보드 탐색을 감사한다.
- 테스트 fixture 계정으로 메뉴, PR 상세, 히스토리 상세 스크린샷/GIF를 만든다.
- 여러 창에서 언어 변경과 제목 갱신을 확인한다.

완료 조건: 민감정보가 없는 실제 화면 자료와 수동 검증 체크리스트가 저장소에 포함된다.

### P1 — 운영 관찰성

- GitHub rate limit과 재시도 횟수를 사용자에게 이해 가능한 오류로 표시한다.
- 히스토리 읽기/쓰기/디코딩 실패를 진단 화면에 노출한다.
- 1,000개 Search API 상한에 도달하면 범위 분할 또는 UI 경고를 제공한다.
- 스케줄 실행 이력과 마지막 실패 원인을 보존한다.

완료 조건: “데이터 없음”과 “조회/저장 실패”를 사용자가 구분할 수 있다.

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
