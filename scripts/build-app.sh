#!/bin/zsh
# DJCrate.app을 만든다: 릴리스 빌드 → 번들(실행 파일·SQLCipher 프레임워크·Info.plist·아이콘) → 로컬 서명.
# 사용: scripts/build-app.sh [--version X.Y.Z | --tag vX.Y.Z] [--package | --install]
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
