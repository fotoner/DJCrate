# 앱 배포

이 문서는 DJCrate 앱의 설치, 로컬 패키지, 태그에서 GitHub Release까지의 절차를 다룬다. 앱 자동 업데이트의 신뢰 모델과 서명 키도 다룬다.

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
- 사용자에게 Gatekeeper 끄기나 격리 속성 지우기를 안내하지 않는다.
- 첫 설치 뒤의 새 버전은 앱이 스스로 받는다([자동 업데이트](#자동-업데이트)). v0.1.0에는 자동 업데이트가 없다. v0.1.0 사용자는 다음 버전을 한 번 위 절차로 직접 받아 설치한다.
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

앱에는 실행 파일, SQLCipher·Sparkle 프레임워크, 아이콘이 들어간다. 한국어/영어/일본어 리소스와 `LICENSE`·`THIRD_PARTY_NOTICES.md`도 들어간다. 개발용 데이터나 라이브러리 사본은 넣지 않는다.

AI 에이전트용 재료도 들어간다(#262).

- `djc`: `Contents/Helpers/djc`. 앱의 SQLCipher 프레임워크를 함께 쓴다. 서명은 앱보다 먼저 한다.
- `djc` 리소스 번들: `Contents/Resources/DJCrate_djc.bundle`.
- 스킬: `Contents/Resources/skills/djcrate`.
- 릴리스 워크플로는 패키지를 푼 뒤 스킬이 저장소와 같은지 본다. 다른 폴더의 링크로 `djc --help`도 실행해 본다.

CLI `djc`를 앱 밖으로 옮길 때나 따로 나눠 줄 때는 `LICENSE`·`THIRD_PARTY_NOTICES.md`도 함께 둔다. 두 파일은 `DJCrate_djc.bundle`과 같이 실행 파일 옆에 둔다.

## 태그에서 Release까지

출시할 버전과 커밋은 관리자가 따로 정한다. `.github/workflows/release.yml`은 `v*.*.*` 태그 푸시에 반응한다. 워크플로를 더하는 것만으로 태그나 Release를 만들지는 않는다.

워크플로는 아래 순서로 돈다.

1. 태그의 커밋을 전체 Git 이력과 함께 받는다. checkout 인증 정보는 남기지 않는다.
2. 태그가 정확한 `vX.Y.Z` 형식인지 다시 검사한다.
3. macOS·SDK 27 이상과 arm64 환경인지 확인한다.
4. 시크릿 `SPARKLE_ED_PRIVATE_KEY`가 있는지 확인한다. 없으면 검사 전에 실패한다.
5. 전체 검사 `scripts/check.sh`를 실행한다.
6. 태그를 `build-app.sh --tag "$RELEASE_TAG" --package`에 넘겨 이 커밋으로 패키지를 만든다.
7. 패키지를 검사한다: ZIP의 SHA-256, 압축 해제한 번들의 서명·버전·아키텍처, 실행 파일 일치와 라이선스 파일.
8. `scripts/sparkle-appcast.sh`가 ZIP을 EdDSA로 서명한다. 그 뒤 `appcast.xml`을 만든다([자동 업데이트](#릴리스의-서명과-정보-파일)).
9. `gh release create --verify-tag`로 기존 태그를 확인한다.
10. ZIP, SHA-256, `appcast.xml`을 Release에 올린다. 릴리스 노트는 서명·공증 부재와 설치 안내 뒤에 GitHub 자동 생성 변경 내역을 덧붙인다.

### 베타

`v0.Y.Z` 태그는 베타다. 워크플로는 이 Release를 아래처럼 만든다.

- 제목 끝에 "(베타)"를 붙인다.
- 릴리스 노트 첫머리에 베타 안내를 한국어와 영어로 넣는다. 안내는 세 가지를 알린다.
  - rekordbox에 쓰기 전에 자동으로 백업한다. 문제가 생기면 [쓰기 전으로 복원…]으로 되돌린다. 화면 이름은 README처럼 대괄호로 쓴다.
  - 그래도 문제가 남으면 이슈로 연락한다.
  - 앱은 GPL-2.0-or-later 라이선스에 따라 있는 그대로 제공한다. 데이터 손실과 손해는 개발자가 책임지지 않는다.
- Pre-release로 표시하지 않는다. GitHub는 저장소 첫 화면 옆 칸에 "Latest" Release만 보여 준다. Pre-release만 있으면 그 칸에 Release가 보이지 않는다.
- 앱의 업데이트 정보 파일 주소도 Latest Release를 가리킨다. Pre-release로 올리면 앱이 그 버전을 찾지 못한다.

`v1.0.0`부터는 제목과 노트에 베타 표시를 넣지 않는다.

### 권한과 재실행

- 발행 단계는 GitHub가 제공하는 `GITHUB_TOKEN`의 `contents: write` 권한을 쓴다.
- 비밀값은 업데이트 서명 비밀 키 `SPARKLE_ED_PRIVATE_KEY` 하나다. 이 값은 두 단계에서만 환경 변수로 받는다: 키 확인, 업데이트 서명.
- 같은 태그의 실행은 직렬화한다.
- 워크플로는 기존 Release를 덮어쓰지도, 태그를 새로 만들지도 않는다.
- 재실행 때 이미 Release가 있으면 실행이 실패한다. 이때 관리자가 기존 결과와 실패 단계를 확인한다.
- 근거: [GitHub 토큰 권한](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token), [gh release create](https://cli.github.com/manual/gh_release_create).

### 로컬에서 확인할 것

로컬에서는 아래 두 명령을 돌린다.

- `zsh -n scripts/build-app.sh`
- `actionlint .github/workflows/release.yml`

시험용 패키지는 해시, 압축 해제, 서명과 Info.plist를 검사한다.

업데이트 서명 단계는 시험용 키로 로컬에서 돌린다. 시험용 키는 아래 [시험 빌드와 E2E](#시험-빌드와-e2e)처럼 임시 폴더에 만든다. 공개 키가 저장소 파일과 다르면 마지막 확인에서 실패한다. 그래서 시험용 키로 돌릴 때는 `DJC_UPDATE_PUBLIC_KEY`로 만든 앱을 쓴다.

```sh
SPARKLE_ED_PRIVATE_KEY="$(cat <임시 폴더>/priv.txt)" scripts/sparkle-appcast.sh \
  dist/DJCrate-0.0.0-macOS-arm64.zip <압축 푼 폴더>/DJCrate.app v0.0.0 fotoner/DJCrate <임시 폴더>/appcast.xml
```

실제 태그 실행과 Release 업로드는 별도의 배포 검증이다. 다운로드한 앱을 다른 Mac에 설치해 처음 실행하는 것도 별도의 배포 검증이다.

## 자동 업데이트

앱은 [Sparkle](https://sparkle-project.org) 2로 새 버전을 찾아 설치한다(#59). 버전은 `Package.swift`에 정확히 고정한다(지금 2.10.0). 사용자 화면은 설정 › 업데이트와 앱 메뉴 "업데이트 확인…"이다([기능](features.md#앱-업데이트)).

### 앱의 동작

- 앱은 Info.plist의 `SUFeedURL`에서 정보 파일 `appcast.xml`을 받는다. 주소는 `https://github.com/fotoner/DJCrate/releases/latest/download/appcast.xml`이다.
- 기본값은 하루 한 번 자동 확인이다(`SUEnableAutomaticChecks`, `SUScheduledCheckInterval` 86400). 첫 실행에 묻는 창을 띄우지 않는다.
- 자동으로 받아 설치는 기본으로 끈다(`SUAutomaticallyUpdate`). 사용자가 설정에서 켠다. 켜면 받아 둔 업데이트를 앱을 끌 때 설치한다.
- 확인·받기·설치 창은 Sparkle 표준 창(`SPUStandardUpdaterController`)이다. Sparkle의 한국어·일본어 지역화가 그대로 나온다.
- 자동 확인·자동 설치·마지막 확인 시각은 Sparkle이 앱 번들 ID의 환경설정(`SU…` 키)에 저장한다.
- 앱은 `SUFeedURL`과 `SUPublicEDKey`가 모두 있는 번들에서만 업데이트 도구를 만든다. 개발 빌드(`.build/debug/DJCrate`)와 시험 프로세스는 Sparkle 환경설정에 쓰지 않는다.
- rekordbox·USB에 쓰는 동안에는 설치와 다시 켜기를 미룬다. 복원도 쓰기에 든다. 쓰기가 끝나면 이어서 설치한다. 판정은 `UpdateInstallPolicy`·`UpdateDeferral`에 있다.
- 자동으로 받은 업데이트는 앱을 끌 때 설치한다. 받아 둔 업데이트를 다시 켜기로 설치할 때 Sparkle은 미룸 판정을 부르지 않는다. 두 경로 모두 앱 끄기를 지난다. 그래서 앱은 rekordbox·USB에 쓰는 동안 끄기를 막는다(`AppWriteActivity.quitBlockedReason`).

### 신뢰 모델

- 첫 설치는 [설치](#설치)의 절차를 따른다. 사용자가 해시를 확인한다. 그 뒤 macOS의 열기 승인을 한다.
- 그 뒤의 업데이트는 EdDSA(ed25519) 서명으로 확인한다. 앱에 넣은 공개 키(`SUPublicEDKey`)로 받은 ZIP의 서명을 본다. 서명이 맞지 않으면 설치하지 않는다.
- 릴리스 앱은 ad-hoc 서명이다. Sparkle은 새 앱의 코드 서명이 옛 앱의 서명 요구와 맞는지도 본다. ad-hoc 서명의 요구는 cdhash라서 늘 다르다. Sparkle은 EdDSA나 코드 서명 중 하나가 맞으면 받아들인다(`SUUpdateValidator.m`). 그래서 ad-hoc → ad-hoc 업데이트는 EdDSA 서명으로만 받는다. 공개 키가 없는 앱은 업데이트할 수 없다.
- 새 앱의 코드 서명 자체는 유효해야 한다. `build-app.sh`가 끝에서 `codesign --verify --deep --strict`로 확인한다.
- Sparkle은 EdDSA를 확인한 뒤 새 번들의 격리 속성(`com.apple.quarantine`)을 지운다. 그 뒤 같은 자리에 바꿔 넣는다(`SUPlainInstaller.m`). macOS 14.4부터는 바꾸기 전에 `gktool`로 미리 검사한다. 이것은 Sparkle이 자기가 확인한 업데이트에만 하는 일이다. 빌드 스크립트와 안내는 격리 속성을 지우지 않는다.
- 2026-10-12에 ad-hoc 0.1.90 → 0.1.91을 실제로 업데이트해 확인했다. Sparkle 로그는 "OK: EdDSA signature is correct for update" 뒤에 cdhash가 다르다고 적었다. 설치와 다시 켜기는 끝났다. 다른 키로 서명한 업데이트는 "업데이트 오류"로 거부했다.

### 서명 키

- 공개 키는 `Assets/sparkle-public-ed-key.txt`에 있다. 내용은 ed25519 공개 키 32바이트의 base64 한 줄이다. `build-app.sh`가 읽어 `SUPublicEDKey`로 넣는다. 형식이 틀리면 빌드 전에 실패한다.
- 비밀 키는 저장소 시크릿 `SPARKLE_ED_PRIVATE_KEY`에 있다. 내용은 `generate_keys --account djcrate -x`로 내보낸 base64 한 줄이다. 비밀 키를 저장소와 로그에 두지 않는다.
- 비밀 키를 잃으면 이미 설치한 앱은 새 업데이트를 받지 못한다. 사용자는 새 키의 앱을 한 번 직접 받아 설치해야 한다. 그래서 비밀 키를 안전한 곳에 따로 보관한다.

진짜 키는 관리자가 아래 순서로 만든다. 도구는 `swift build`가 받은 `.build/artifacts/<체크아웃 폴더 이름>/Sparkle/bin/`에 있다(예: `.build/artifacts/DJCrate/Sparkle/bin/`).

1. `generate_keys --account djcrate`를 실행한다. 이 도구는 비밀 키를 로그인 키체인의 `djcrate` 계정에 만든다. 그 뒤 공개 키를 출력한다.
2. 출력한 공개 키를 `Assets/sparkle-public-ed-key.txt`에 한 줄로 쓴다. 커밋한다.
3. `generate_keys --account djcrate -x <임시 파일>`로 비밀 키를 내보낸다.
4. `gh secret set SPARKLE_ED_PRIVATE_KEY -R fotoner/DJCrate < <임시 파일>`로 시크릿에 넣는다.
5. 임시 파일을 지운다. 키체인의 키나 별도 보관본은 남긴다.
6. 시험용 패키지를 만든다. 비밀 키를 표준 입력으로 넘겨 위 [로컬에서 확인할 것](#로컬에서-확인할-것)의 `sparkle-appcast.sh`를 돌린다. "EdDSA 서명 확인" 줄이 나오면 공개 키 파일과 비밀 키가 짝이다.

### 릴리스의 서명과 정보 파일

`scripts/sparkle-appcast.sh`가 한다.

1. 시크릿이 비었으면 실패한다.
2. `sign_update --ed-key-file -`로 ZIP을 서명한다. 비밀 키는 표준 입력으로만 넘긴다.
3. `sign_update --verify`로 비밀 키의 짝인지 확인한다.
4. `scripts/sparkle-verify.swift`로 ZIP 속 앱의 `SUPublicEDKey`로 다시 확인한다. 저장소의 공개 키 파일과 시크릿이 짝이 아니면 여기서 실패한다.
5. `appcast.xml`을 만든다. 항목은 이 릴리스 하나다.

| 항목 | 값 |
|---|---|
| `sparkle:version` | `CFBundleVersion`(커밋 수) |
| `sparkle:shortVersionString` | `CFBundleShortVersionString` |
| `sparkle:minimumSystemVersion` | `LSMinimumSystemVersion`(27.0) |
| `enclosure` | Release 자산 주소, 길이, `sparkle:edSignature` |
| `sparkle:releaseNotesLink` | Release 페이지 |

Sparkle은 `sparkle:version`을 지금 앱의 `CFBundleVersion`과 비교한다. 그래서 릴리스 커밋의 커밋 수가 앞 릴리스보다 커야 한다.

### 시험 빌드와 E2E

- 아래 환경 변수는 시험 빌드에만 쓴다. `--package`·`--install`에서 주면 빌드 전에 실패한다.
- 하나라도 주면 `DJC_BUNDLE_ID`도 꼭 준다. 값은 설치 앱의 번들 ID와 달라야 한다. 아니면 빌드 전에 실패한다.

| 변수 | 바꾸는 것 |
|---|---|
| `DJC_BUNDLE_ID` | 번들 ID. 시험 앱이 설치 앱의 환경설정(`com.fotone.djcrate`)에 쓰지 않게 한다(예: `com.fotone.djcrate.updatetest`) |
| `DJC_BUILD_NUMBER` | `CFBundleVersion` |
| `DJC_UPDATE_FEED_URL` | `SUFeedURL`(예: `http://127.0.0.1:8759/appcast.xml`) |
| `DJC_UPDATE_PUBLIC_KEY` | `SUPublicEDKey`(시험용 공개 키) |

- 시험용 키는 Homebrew OpenSSL 3으로 임시 폴더에 만든다. 키체인을 쓰지 않는다. macOS의 `/usr/bin/openssl`은 ed25519를 만들지 못한다.

```sh
K=$(mktemp -d); O=/opt/homebrew/opt/openssl@3/bin/openssl
$O genpkey -algorithm ed25519 -out $K/k.pem
$O pkey -in $K/k.pem -outform DER | tail -c 32 | base64 > $K/priv.txt
$O pkey -in $K/k.pem -pubout -outform DER | tail -c 32 | base64 > $K/pub.txt
```

E2E는 `lockf /tmp/djc-gui.lock` 안에서 아래 순서로 한다.

1. 합성 rekordbox 사본을 만든다(스킬 `app-selftest`의 픽스처). 임시 `DJC_HOME`에 `djc draft`로 초안을 만든다.
2. 같은 소스로 A(예: 0.1.90, 빌드 9000)와 B(0.1.91, 빌드 9001)를 시험 빌드로 만든다.
3. 두 번들의 Info.plist에 `LSEnvironment`로 `DJC_HOME`·`DJC_REKORDBOX_DIR`·`DJC_DB`를 넣는다. 번들을 다시 서명한다. Sparkle이 다시 켠 앱은 LaunchServices로 뜬다. 그래서 셸의 환경 변수를 물려받지 않는다.
4. B를 ZIP으로 묶는다. ZIP을 시험용 키로 서명한다. 정보 파일을 만들어 `python3 -m http.server --bind 127.0.0.1`로 띄운다.
5. A를 임시 폴더에서 켠다. 업데이트 창에서 "업데이트 설치"와 "설치 & 재실행"을 누른다.
6. 다시 켜진 앱이 B 버전인지, 초안 파일과 설정 값이 그대로인지 본다.
7. 끝나면 시험 번들 ID의 환경설정(`defaults delete`)과 `~/Library/Caches`·`HTTPStorages`·`WebKit`의 같은 ID 폴더, 임시 폴더를 지운다.

### Sparkle 버전을 올릴 때

- 새 버전의 `SUUpdateValidator.m`에서 ad-hoc 앱을 EdDSA만으로 받아들이는지 다시 본다.
- 새 버전의 `SUPlainInstaller.m`에서 격리 속성 처리를 다시 본다.
- 위 E2E를 다시 돈다.
- `THIRD_PARTY_NOTICES.md`의 Sparkle 절을 새 `LICENSE`와 맞춘다.

## 더 보기

- [`.claude/skills/release/SKILL.md`](../.claude/skills/release/SKILL.md): 앱 설치와 배포 준비 순서
- [`docs/ci.md`](ci.md): CI 도구와 러너 조건
- [`.github/workflows/release.yml`](../.github/workflows/release.yml): 태그에서 Release까지 도는 워크플로
- [`scripts/build-app.sh`](../scripts/build-app.sh): 앱 빌드·설치·패키지 스크립트
- [`scripts/sparkle-appcast.sh`](../scripts/sparkle-appcast.sh): 업데이트 서명과 정보 파일
- [Sparkle 문서](https://sparkle-project.org/documentation/): Publishing, EdDSA, Sandboxing. Sandboxing 절에 XPC 서비스 빼기와 서명 순서가 있다.
