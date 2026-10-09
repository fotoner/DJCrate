# 앱 배포

이 문서는 DJCrate 앱의 설치, 로컬 패키지, 태그에서 GitHub Release까지의 절차를 다룬다.

## 서명과 공증

DJCrate는 지금 **Developer ID 서명과 Apple 공증 없이** 배포한다. 그래서 Apple 계정·인증서·공증용 비밀값은 필요하지 않다. 배포 ZIP에는 ad-hoc 서명한 앱을 넣는다. ad-hoc은 실행 파일과 번들의 무결성을 확인하는 로컬 서명일 뿐 배포자 신원을 보증하지 않는다.

## 설치

지금 자동 배포 대상은 **macOS 27 이상, Apple Silicon(arm64)**이다. Intel용 자동 빌드나 universal 배포는 제공하지 않는다.

1. GitHub Release에서 `DJCrate-X.Y.Z-macOS-arm64.zip`과 같은 이름의 `.zip.sha256`을 같은 폴더에 받는다.
2. 터미널에서 그 폴더로 이동한다.
3. `X.Y.Z`를 받은 버전으로 바꿔 `shasum -a 256 -c DJCrate-X.Y.Z-macOS-arm64.zip.sha256`을 실행한다.
4. 결과가 `OK`가 아니면 압축을 풀지 않은 채 두 파일을 다시 받는다.
5. ZIP을 푼다.
6. 기존 DJCrate가 실행 중이면 먼저 직접 종료한다.
7. `DJCrate.app`을 응용 프로그램 폴더로 옮긴다.
8. 출처와 파일을 확인해 앱을 실행할지 정한다.
9. 다운로드한 앱은 macOS가 개발자를 확인할 수 없어 막을 수 있다. 실행하기로 정했으면 앱 실행을 시도한다.
10. 실행이 막혔으면 시스템 설정 → 개인정보 보호 및 보안에서 그 앱의 열기 승인을 확인한다.

- 3단계의 해시는 배포자 인증서가 아니라 전송 무결성만 확인한다.
- 열기 승인의 자세한 조건은 [Apple의 공식 안내](https://support.apple.com/102445)를 따른다. 조직이 관리하는 Mac에서는 관리자가 이 승인을 제한할 수 있다.
- 빌드·설치 스크립트는 Gatekeeper를 끄지도, 다운로드 격리 속성을 지우지도 않는다.
- 패키지가 서명 검증을 통과해도 다른 Mac의 Gatekeeper가 실행을 자동으로 허용한다는 뜻은 아니다.

## 로컬 빌드와 패키지

macOS 27 SDK를 포함한 Xcode와 Swift 6.2 이상이 필요하다. 지금 CI 도구와 러너 조건은 [CI 문서](ci.md)를 따른다.

```sh
scripts/build-app.sh                         # 기존 로컬 앱 빌드
scripts/build-app.sh --install               # 기존 로컬 설치
scripts/build-app.sh --version 0.0.0 --package # 발행하지 않는 시험용 ZIP
scripts/build-app.sh --tag v0.0.0 --package   # 태그 문자열을 직접 전달
```

### 버전

- 예시의 `0.0.0`은 시험 버전일 뿐 출시 버전을 정하지 않는다.
- `--version`은 `X.Y.Z`만, `--tag`는 `vX.Y.Z`만 받는다.
- 숫자에 앞자리 0이나 접미사가 붙은 버전은 빌드 전에 거절한다. 버전 옵션 중복과 알 수 없는 옵션도 빌드 전에 거절한다.
- `--package`에는 명시한 버전이나 현재 커밋의 태그가 있어야 한다.
- `CFBundleVersion`은 전체 Git 이력의 커밋 수다.

버전 인자가 없을 때는 아래 순서로 버전을 정한다.

| 조건 | 버전 |
|---|---|
| 현재 커밋에 정확한 `vX.Y.Z` 태그가 있음 | 그 태그 |
| 태그도 없음 | 기존 로컬 빌드 버전 `0.1`을 유지 |

### 서명

- `--package`는 늘 `codesign --sign - --timestamp=none`으로 프레임워크와 앱을 서명한다.
- 이때는 키체인을 검색하지 않는다. `DJC_SIGN_IDENTITY`도 쓰지 않는다.
- 일반 빌드와 `--install`은 기존 순서를 유지한다: `DJC_SIGN_IDENTITY` → Apple Development 인증서 자동 탐색 → ad-hoc.
- `--package`와 `--install`은 함께 지정할 수 없다.
- Apple Silicon에서는 실행 코드에 서명이 있어야 한다. ad-hoc 서명도 이 조건을 채운다.
- 기존 스크립트는 `install_name_tool`로 실행 파일을 바꾸므로 마지막에 다시 서명한 뒤 `codesign --verify --deep --strict`로 검증한다.
- 이 서명은 Developer ID 서명·공증과 별개다. 근거: [Apple Silicon 실행 코드 서명 요구](https://developer.apple.com/documentation/macos-release-notes/macos-big-sur-11_0_1-universal-apps-release-notes/), [ad-hoc 서명의 의미](https://developer.apple.com/documentation/security/seccodesignatureflags/adhoc?language=objc).

### 결과물

결과물은 `dist/DJCrate.app`, `dist/DJCrate-X.Y.Z-macOS-<아키텍처>.zip`, 같은 이름의 `.zip.sha256`이다. 아키텍처는 실제 실행 파일에서 읽는다. ZIP은 `DJCrate.app`을 최상위에 담는다.

앱에는 실행 파일, SQLCipher 프레임워크, 아이콘이 들어간다. 한국어/영어/일본어 리소스와 `LICENSE`·`THIRD_PARTY_NOTICES.md`도 들어간다. 개발용 데이터나 라이브러리 사본은 넣지 않는다.

CLI `djc`를 앱 밖으로 옮길 때나 따로 나눠 줄 때는 `LICENSE`·`THIRD_PARTY_NOTICES.md`도 함께 둔다. 두 파일은 `DJCrate_djc.bundle`과 같이 실행 파일 옆에 둔다.

## 태그에서 Release까지

출시할 버전과 커밋은 관리자가 따로 정한다. `.github/workflows/release.yml`은 `v*.*.*` 태그 푸시에 반응한다. 워크플로를 더하는 것만으로 태그나 Release를 만들지는 않는다.

워크플로는 아래 순서로 돈다.

1. 태그의 커밋을 전체 Git 이력과 함께 받는다. checkout 인증 정보는 남기지 않는다.
2. 태그가 정확한 `vX.Y.Z` 형식인지 다시 검사한다.
3. macOS·SDK 27 이상과 arm64 환경인지 확인한다.
4. 전체 검사 `scripts/check.sh`를 실행한다.
5. 태그를 `build-app.sh --tag "$RELEASE_TAG" --package`에 넘겨 이 커밋으로 패키지를 만든다.
6. 패키지를 검사한다: ZIP의 SHA-256, 압축 해제한 번들의 서명·버전·아키텍처, 실행 파일 일치와 라이선스 파일.
7. `gh release create --verify-tag`로 기존 태그를 확인한다.
8. ZIP과 SHA-256을 Release에 올린다. 릴리스 노트는 서명·공증 부재와 설치 안내 뒤에 GitHub 자동 생성 변경 내역을 덧붙인다.

### 권한과 재실행

- 발행 단계는 GitHub가 제공하는 `GITHUB_TOKEN`의 `contents: write` 권한만 쓰므로 별도 비밀값을 등록하지 않는다.
- 같은 태그의 실행은 직렬화한다.
- 워크플로는 기존 Release를 덮어쓰지도, 태그를 새로 만들지도 않는다.
- 재실행 때 이미 Release가 있으면 실행이 실패한다. 이때 관리자가 기존 결과와 실패 단계를 확인한다.
- 근거: [GitHub 토큰 권한](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token), [gh release create](https://cli.github.com/manual/gh_release_create).

### 로컬에서 확인할 것

로컬에서는 아래 두 명령을 돌린다.

- `zsh -n scripts/build-app.sh`
- `actionlint .github/workflows/release.yml`

시험용 패키지는 해시, 압축 해제, 서명과 Info.plist를 검사한다.

실제 태그 실행과 Release 업로드는 별도의 배포 검증이다. 다운로드한 앱을 다른 Mac에 설치해 처음 실행하는 것도 별도의 배포 검증이다.

## 더 보기

- [`.claude/skills/release/SKILL.md`](../.claude/skills/release/SKILL.md): 앱 설치와 배포 준비 순서
- [`docs/ci.md`](ci.md): CI 도구와 러너 조건
- [`.github/workflows/release.yml`](../.github/workflows/release.yml): 태그에서 Release까지 도는 워크플로
- [`scripts/build-app.sh`](../scripts/build-app.sh): 앱 빌드·설치·패키지 스크립트
