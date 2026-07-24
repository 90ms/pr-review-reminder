# Homebrew tap seed

이 디렉터리는 별도 `90ms/homebrew-tap` 저장소에 넣을 파일의 원본이다.

릴리스 태그를 만든 뒤 GitHub가 제공하는 source tarball의 SHA-256을 구하고 Formula를
렌더링한다.

```bash
version=0.2.0
curl -L \
  "https://github.com/90ms/pr-review-reminder/archive/refs/tags/v${version}.tar.gz" \
  -o "/tmp/pr-review-reminder-${version}.tar.gz"
sha="$(shasum -a 256 "/tmp/pr-review-reminder-${version}.tar.gz" | awk '{print $1}')"

./Scripts/render-homebrew-formula.sh \
  "$version" \
  "$sha" \
  "/path/to/homebrew-tap/Formula/pr-review-reminder.rb"
```

`Formula/`와 `.github/`를 tap 저장소에 복사한 뒤 CI가 실제 source build, Formula
test와 audit을 통과해야 배포한다.
