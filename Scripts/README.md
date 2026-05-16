# 개발 스크립트

## `lint.sh` — SwiftLint 검사

```sh
scripts/lint.sh           # 전체 검사
scripts/lint.sh --fix     # 자동 수정 가능한 항목
scripts/lint.sh --baseline # violation 카운트만 출력
```

SwiftLint 가 미설치이면 안내만 출력하고 통과한다 (선택적 도구).

### Xcode 빌드 페이즈 자동화 (선택)

Xcode → 타겟 선택 → Build Phases → `+` → New Run Script Phase →
다음을 한 줄 입력:

```sh
if which swiftlint >/dev/null; then swiftlint --quiet; fi
```

새 페이즈는 "Compile Sources" 다음으로 끌어 놓는다.
