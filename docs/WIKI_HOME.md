# PR Review Reminder Wiki

PR Review Reminder는 여러 GitHub 저장소의 리뷰 요청을 macOS 메뉴바에 모으고,
로컬 Claude 또는 Codex CLI로 리뷰 초안을 만든 뒤 사용자가 확인한 내용만 게시하는
앱입니다.

## 기본 사용 흐름

1. `gh auth login`과 사용할 AI CLI 로그인을 완료합니다.
2. 설정의 **리뷰** 탭에서 GitHub owner, 저장소, AI 도구와 리뷰 언어를 선택합니다.
3. 필요하면 가이드라인을 직접 작성하거나 파일에서 불러옵니다.
4. **저장소에서 찾아보기**로 프로젝트의 리뷰 스킬, 컨벤션과 아키텍처 문서를
   탐색하고 임포트합니다.
5. 메뉴에서 PR을 새로고침하고 **코드 리뷰**를 실행합니다.
6. 요약, 리뷰 포인트, diff와 인라인 코멘트를 확인·편집한 뒤 제출합니다.

GitHub 코멘트와 승인은 자동으로 게시되지 않으며 항상 사용자의 제출 동작이
필요합니다.

## 설정 구성

- **일반**: 앱 언어, 알림, 로그인 시 실행, 업데이트
- **리뷰**: GitHub 범위, AI 도구, 리뷰 언어, 토큰 예산, 가이드라인
- **자동화**: 실행 스케줄, PR 발견 시 자동 리뷰
- **데이터**: 리뷰 히스토리, 보존 기간, 로컬 저장소 상태
- **고급**: 프롬프트 템플릿, `gh`/Claude/Codex CLI 진단

프롬프트 방식 선택은 없습니다. 직접 입력한 지침, 선택한 가이드라인 파일과
저장소에서 임포트한 문서를 항상 하나의 리뷰 컨텍스트로 조합합니다.

## 저장소 가이드라인 탐색

**저장소에서 찾아보기**는 `gh`로 기본 브랜치의 Markdown 트리를 읽고 다음 후보를
우선합니다.

- `AGENTS.md`, `CLAUDE.md`, `.github/copilot-instructions.md`
- `.agents/skills/**/SKILL.md` 등 리뷰 스킬
- 코드리뷰, 코딩 스타일, 컨벤션, 아키텍처, 기여 가이드
- `docs/`와 `.github/`의 관련 Markdown

현재 선택된 Claude 또는 Codex가 후보를 리뷰 규칙, 컨벤션, 아키텍처로 분류합니다.
임포트된 문서는 저장소와 commit SHA에 연결되며, 하위 디렉터리의 `AGENTS.md`는
해당 디렉터리 아래 변경 파일에만 적용됩니다. 최신 문서로 갱신하려면 같은 저장소를
다시 탐색합니다.

후보 문서 발췌는 분류를 위해 선택한 AI 서비스로 전달되며, 임포트된 원문과 출처는
앱 설정에 저장됩니다.

## 리뷰 게시

- 인라인 코멘트가 있으면 내용을 편집·삭제하고 코멘트만 게시하거나 승인과 함께
  게시할 수 있습니다.
- 인라인 코멘트와 리뷰 포인트가 모두 없으면 **문제 없음 · 승인**이 표시되고
  기본 승인 문구가 채워집니다.
- 리뷰 포인트가 남아 있으면 인라인 코멘트가 없어도 일반 **승인**으로 표시됩니다.
- 게시 직전 PR head SHA가 분석 시점과 같은지 다시 확인합니다.

## 관련 문서

- [README](https://github.com/90ms/pr-review-reminder/blob/main/README.md)
- [제품 명세](https://github.com/90ms/pr-review-reminder/blob/main/docs/SPEC.md)
- [프로젝트 개요](https://github.com/90ms/pr-review-reminder/blob/main/docs/PROJECT_OVERVIEW.md)
- [macOS 수동 검증](https://github.com/90ms/pr-review-reminder/blob/main/docs/MACOS_VALIDATION.md)
