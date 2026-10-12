#!/bin/zsh
# DJCrate.app을 만든다: 릴리스 빌드 → 번들(실행 파일·SQLCipher·Sparkle 프레임워크·Info.plist·아이콘, AI 에이전트용 djc·스킬) → 로컬 서명.
# 사용: scripts/build-app.sh [--version X.Y.Z | --tag vX.Y.Z] [--package | --install]
# 업데이트 E2E 시험 빌드만: DJC_BUNDLE_ID·DJC_BUILD_NUMBER·DJC_UPDATE_FEED_URL·DJC_UPDATE_PUBLIC_KEY(docs/releasing.md "자동 업데이트")
set -euo pipefail
cd "${0:A:h}/.."

VERSION=""
INSTALL=false
PACKAGE=false
fail() { print -u2 -- "$1"; exit 1; }
while (( $# )); do
    case "$1" in
        --version|--tag)
            [[ -z "$VERSION" && $# -ge 2 ]] || fail "버전은 --version X.Y.Z 또는 --tag vX.Y.Z로 한 번만 지정하세요."
            option="$1"
            VERSION="$2"
            if [[ "$option" == --tag ]]; then
                [[ "$VERSION" == v* ]] || fail "태그는 vX.Y.Z 형식으로 지정하세요."
                VERSION="${VERSION#v}"
            fi
            [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "버전은 앞자리 0이나 접미사 없이 X.Y.Z 형식으로 지정하세요."
            shift 2 ;;
        --install) INSTALL=true; shift ;;
        --package) PACKAGE=true; shift ;;
        --help|-h)
            print '사용: scripts/build-app.sh [--version X.Y.Z | --tag vX.Y.Z] [--package | --install]'
            exit 0 ;;
        *) fail "알 수 없는 인자입니다. --help로 사용법을 확인하세요." ;;
    esac
done
[[ "$INSTALL" != true || "$PACKAGE" != true ]] || fail "배포 패키지와 설치는 --package 또는 --install로 따로 실행하세요."
if [[ -z "$VERSION" ]]; then
    TAG=$(git describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null || true)
    if [[ -n "$TAG" ]]; then
        VERSION="${TAG#v}"
        [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "현재 태그가 vX.Y.Z 형식이 아닙니다. --version으로 버전을 지정하세요."
    elif [[ "$PACKAGE" == true ]]; then
        fail "배포 패키지는 --version X.Y.Z 또는 --tag vX.Y.Z로 버전을 지정하세요."
    else
        VERSION="0.1"
    fi
fi
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
BUNDLE_ID="com.fotone.djcrate"
APP="dist/DJCrate.app"

# --- 앱 자동 업데이트(#59, Sparkle): 정보 파일 주소와 공개 키 ---
# 릴리스마다 appcast.xml을 Release 자산으로 올리므로 이 주소가 늘 최신 Release를 가리킨다(docs/releasing.md "자동 업데이트").
UPDATE_FEED_URL="https://github.com/fotoner/DJCrate/releases/latest/download/appcast.xml"
UPDATE_PUBLIC_KEY=$(<Assets/sparkle-public-ed-key.txt)
# 업데이트 E2E 시험 빌드만 번들 ID·빌드 번호·정보 파일 주소·공개 키를 바꾼다. 시험 앱이 설치 앱의 환경설정(com.fotone.djcrate)에 쓰지 않게 한다.
if [[ -n "${DJC_BUNDLE_ID:-}${DJC_BUILD_NUMBER:-}${DJC_UPDATE_FEED_URL:-}${DJC_UPDATE_PUBLIC_KEY:-}" ]]; then
    [[ "$PACKAGE" != true && "$INSTALL" != true ]] || fail "DJC_BUNDLE_ID·DJC_BUILD_NUMBER·DJC_UPDATE_*는 시험 빌드에만 씁니다. --package·--install에서는 지우세요."
    [[ -n "${DJC_BUNDLE_ID:-}" && "${DJC_BUNDLE_ID}" != "$BUNDLE_ID" ]] || fail "시험 빌드에는 설치 앱과 다른 DJC_BUNDLE_ID를 주세요(예: com.fotone.djcrate.updatetest)."
    BUNDLE_ID="${DJC_BUNDLE_ID:-$BUNDLE_ID}"
    BUILD="${DJC_BUILD_NUMBER:-$BUILD}"
    UPDATE_FEED_URL="${DJC_UPDATE_FEED_URL:-$UPDATE_FEED_URL}"
    UPDATE_PUBLIC_KEY="${DJC_UPDATE_PUBLIC_KEY:-$UPDATE_PUBLIC_KEY}"
fi
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || fail "빌드 번호는 1 이상의 정수로 지정하세요."
[[ $(print -rn -- "$UPDATE_PUBLIC_KEY" | base64 -d 2>/dev/null | wc -c) -eq 32 ]] || fail "업데이트 공개 키가 ed25519 base64(32바이트)가 아닙니다. Assets/sparkle-public-ed-key.txt를 확인하세요."
# --- 앱 자동 업데이트 끝 ---

# ── AI 에이전트 재료(#262) 빌드 ──
# djc를 먼저 빌드한다. 한 제품만 빌드하면 그 제품이 쓰지 않는 Products의 프레임워크(Sparkle)를 낡은 결과로 지우므로
# 앱을 마지막에 빌드해야 아래에서 .build/release/Sparkle.framework를 복사할 수 있다.
swift build -c release --product djc
swift build -c release --product DJCrate

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp .build/release/DJCrate "$APP/Contents/MacOS/DJCrate"
cp -R .build/release/SQLCipher.framework "$APP/Contents/Frameworks/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
# 문구 카탈로그 번들(Bundle.module은 Contents/Resources에서 찾는다). Info.plist 번역(권한 안내)은 앱 번들의 언어 폴더로.
RESOURCES=.build/release/DJCrate_DJCrate.bundle
cp -R "$RESOURCES" "$APP/Contents/Resources/"
for lproj in "$RESOURCES"/Contents/Resources/*.lproj(N); do
    [[ -f "$lproj/InfoPlist.strings" ]] || continue
    mkdir -p "$APP/Contents/Resources/${lproj:t}"
    mv "$APP/Contents/Resources/DJCrate_DJCrate.bundle/Contents/Resources/${lproj:t}/InfoPlist.strings" "$APP/Contents/Resources/${lproj:t}/"
done
# 실행 파일은 @loader_path에서 프레임워크를 찾는다. 번들 안 Frameworks 폴더도 찾게 한다.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/DJCrate"

# ── AI 에이전트 재료(#262): 설정 › AI 에이전트가 ~/.local/bin/djc 링크와 스킬 복사본을 만든다 ──
# djc는 Contents/Helpers에 둔다. Contents/MacOS에서 직접 부르면 Bundle.main이 앱 번들이 되어 앱의 번들 ID·실행 파일을 본다.
# djc 리소스 번들은 Contents/Resources에 둔다(CLILocalization이 실행 파일 옆 다음 ../Resources를 찾는다).
# SQLCipher는 앱과 같은 Frameworks를 쓴다. 링크로 불러도 dyld는 실제 자리 기준으로 @executable_path를 푼다.
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/skills"
cp .build/release/djc "$APP/Contents/Helpers/djc"
cp -R .build/release/DJCrate_djc.bundle "$APP/Contents/Resources/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/Helpers/djc"
cp -R skills/djcrate "$APP/Contents/Resources/skills/"
find "$APP/Contents/Resources/skills" -name .DS_Store -delete
# --- 앱 자동 업데이트(#59, Sparkle): 프레임워크 넣기 ---
# 샌드박스 앱이 아니므로 XPC 서비스는 뺀다(Sparkle 문서 Sandboxing "Removing XPC Services"). 서명은 아래에서 안쪽부터 다시 한다.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
cp -R .build/release/Sparkle.framework "$APP/Contents/Frameworks/"
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"
# --- 앱 자동 업데이트 끝 ---

ICON_TEMP=$(mktemp -d)
trap 'rm -rf "$ICON_TEMP"' EXIT
# Composer 원본으로 시스템 레이어 자산과 예비 ICNS를 함께 만든다.
xcrun actool Assets/AppIcon.icon --compile "$APP/Contents/Resources" \
    --app-icon AppIcon --platform macosx --minimum-deployment-target 27.0 \
    --output-partial-info-plist "$ICON_TEMP/Info.plist"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DJCrate</string>
    <key>CFBundleDisplayName</key><string>DJCrate</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>DJCrate</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- 아래 설명·권한 안내 문구를 바꾸면 Sources/DJCrate/Resources/InfoPlist.xcstrings(ko·en·ja)도 함께 고친다. -->
    <key>NSHumanReadableCopyright</key><string>© 2026 Hyeonjae Nam</string>
    <key>NSAppleMusicUsageDescription</key><string>iTunes 동기화 목록을 선택하고 곡 순서를 읽으려면 Music 보관함 접근이 필요합니다.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>외장 드라이브에 있는 음원을 재생·분석하려면 접근이 필요합니다. DJCrate는 음원 파일을 고치지 않습니다.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>네트워크 드라이브에 있는 음원을 재생·분석하려면 접근이 필요합니다.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>문서 폴더에 있는 음원을 재생·분석하거나 rekordbox XML을 저장하려면 접근이 필요합니다.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>다운로드 폴더에 있는 음원을 재생·분석하려면 접근이 필요합니다.</string>
    <key>NSDesktopFolderUsageDescription</key><string>데스크탑에 있는 음원을 재생·분석하려면 접근이 필요합니다.</string>
</dict>
</plist>
PLIST
# 아이콘 이름은 컴파일러가 실제로 만든 결과와 맞춘다.
for key in CFBundleIconFile CFBundleIconName; do
    value=$(plutil -extract "$key" raw "$ICON_TEMP/Info.plist")
    plutil -insert "$key" -string "$value" "$APP/Contents/Info.plist"
done
# 언어 목록(ko·en·ja, 없는 언어는 영어)은 개발 빌드 실행 파일에 넣는 Sources/DJCrate/Info.plist와 같게 둔다.
LANGUAGES=Sources/DJCrate/Info.plist
plutil -replace CFBundleDevelopmentRegion -string "$(plutil -extract CFBundleDevelopmentRegion raw "$LANGUAGES")" "$APP/Contents/Info.plist"
plutil -replace CFBundleLocalizations -json "$(plutil -extract CFBundleLocalizations json -o - "$LANGUAGES")" "$APP/Contents/Info.plist"
# 덱 드래그 형식도 실행 파일과 번들에 똑같이 선언해야 AppKit에서 SwiftUI로 건너간다.
plutil -replace UTExportedTypeDeclarations -json "$(plutil -extract UTExportedTypeDeclarations json -o - "$LANGUAGES")" "$APP/Contents/Info.plist"

# --- 앱 자동 업데이트(#59, Sparkle): Info.plist ---
# 앱은 이 두 값이 있는 번들에서만 업데이트 도구를 만든다(UpdateFeedConfig). 하루 한 번 묻는 창 없이 확인하고, 자동 설치는 사용자가 켠다.
plutil -insert SUFeedURL -string "$UPDATE_FEED_URL" "$APP/Contents/Info.plist"
plutil -insert SUPublicEDKey -string "$UPDATE_PUBLIC_KEY" "$APP/Contents/Info.plist"
plutil -insert SUEnableAutomaticChecks -bool YES "$APP/Contents/Info.plist"
plutil -insert SUScheduledCheckInterval -integer 86400 "$APP/Contents/Info.plist"
plutil -insert SUAutomaticallyUpdate -bool NO "$APP/Contents/Info.plist"
# --- 앱 자동 업데이트 끝 ---

# 서명: Apple Development 인증서가 있으면 그것으로(다시 빌드해도 앱 신원이 같아 외장 드라이브 접근 허용이 유지된다),
# 없으면 애드혹. DJC_SIGN_IDENTITY로 지정할 수 있다. 프레임워크 먼저.
# 인증서가 없는 정상 상태에서도 pipefail로 설치 전에 끝나지 않게 한다.
if [[ "$PACKAGE" == true ]]; then
    # 배포는 인증서·키체인 설정과 무관하게 ad-hoc만 쓴다. Developer ID 서명이나 공증이 아니다.
    IDENTITY="-"
else
    IDENTITY="${DJC_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ && !found { print $2; found = 1 }')}"
    IDENTITY="${IDENTITY:--}"
fi
codesign --force --timestamp=none --sign "$IDENTITY" "$APP/Contents/Frameworks/SQLCipher.framework"
# 앱 자동 업데이트(#59): Sparkle은 안쪽 도구 → 프레임워크 순서로, --deep 없이(Sparkle 문서 Sandboxing "Code Signing")
for item in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
    codesign --force --timestamp=none --options runtime --sign "$IDENTITY" "$item"
done
# AI 에이전트용 djc(#262)도 앱보다 먼저 서명한다
codesign --force --timestamp=none --sign "$IDENTITY" "$APP/Contents/Helpers/djc"
codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "만듦: $APP ($VERSION, 빌드 $BUILD, 서명 ${IDENTITY:0:8})"

if [[ "$PACKAGE" == true ]]; then
    ARCH=$(lipo -archs "$APP/Contents/MacOS/DJCrate")
    case "$ARCH" in
        arm64|x86_64) ;;
        'x86_64 arm64'|'arm64 x86_64') ARCH=universal ;;
        *) fail "패키지 이름을 정할 수 없는 아키텍처입니다. 실행 파일을 확인하세요." ;;
    esac
    ARCHIVE="DJCrate-${VERSION}-macOS-${ARCH}.zip"
    rm -f "dist/$ARCHIVE" "dist/$ARCHIVE.sha256"
    ditto -c -k --keepParent "$APP" "dist/$ARCHIVE"
    (cd dist && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
    echo "패키지: dist/$ARCHIVE (Developer ID 서명·공증 없음)"
fi

if [[ "$INSTALL" == true ]]; then
    DEST="/Applications/DJCrate.app"
    [[ -w /Applications ]] || DEST="$HOME/Applications/DJCrate.app"
    mkdir -p "${DEST:h}"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "설치: $DEST"
fi
