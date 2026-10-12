#!/bin/zsh
# 앱 자동 업데이트(#59): 릴리스 ZIP을 EdDSA로 서명하고 Sparkle 정보 파일(appcast.xml)을 만든다.
# 비밀 키는 환경 변수 SPARKLE_ED_PRIVATE_KEY에서 sign_update의 표준 입력으로만 넘긴다. 인자·파일·로그에 남기지 않는다.
# 서명은 두 번 확인한다: sign_update --verify(비밀 키의 짝)와 scripts/sparkle-verify.swift(앱 Info.plist의 SUPublicEDKey).
# 사용: scripts/sparkle-appcast.sh <ZIP> <ZIP에서 푼 DJCrate.app> <태그 vX.Y.Z> <저장소 owner/name> <만들 appcast.xml>
set -euo pipefail
cd "${0:A:h}/.."

fail() { print -u2 -- "$1"; exit 1; }
(( $# == 5 )) || fail "사용: scripts/sparkle-appcast.sh <ZIP> <DJCrate.app> <태그> <저장소> <appcast.xml>"
ARCHIVE="$1" APP="$2" TAG="$3" REPO="$4" OUT="$5"
[[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]] || fail "SPARKLE_ED_PRIVATE_KEY가 비었습니다. 저장소 시크릿에 업데이트 서명 비밀 키를 넣으세요(docs/releasing.md \"자동 업데이트\")."
[[ -f "$ARCHIVE" ]] || fail "ZIP이 없습니다: $ARCHIVE"
INFO="$APP/Contents/Info.plist"
[[ -f "$INFO" ]] || fail "앱 Info.plist가 없습니다: $INFO"
# Sparkle은 이 패키지의 바이너리 타깃이라 도구 폴더 이름이 체크아웃 폴더 이름(패키지 ID)이다. 글롭으로 찾는다.
SIGN_UPDATE=(.build/artifacts/*/Sparkle/bin/sign_update(N))
SIGN_UPDATE=${SIGN_UPDATE[1]:-}
[[ -n "$SIGN_UPDATE" && -x "$SIGN_UPDATE" ]] || fail "sign_update가 없습니다. swift build로 Sparkle 바이너리를 먼저 받으세요."

plist() { plutil -extract "$1" raw "$INFO"; }
BUILD=$(plist CFBundleVersion)
VERSION=$(plist CFBundleShortVersionString)
MIN_SYSTEM=$(plist LSMinimumSystemVersion)
PUBLIC_KEY=$(plist SUPublicEDKey)
[[ "$TAG" == "v$VERSION" ]] || fail "태그($TAG)와 앱 버전($VERSION)이 다릅니다."

SIGNATURE=$(printenv SPARKLE_ED_PRIVATE_KEY | "$SIGN_UPDATE" --ed-key-file - -p "$ARCHIVE")
[[ -n "$SIGNATURE" ]] || fail "ZIP을 서명하지 못했습니다."
printenv SPARKLE_ED_PRIVATE_KEY | "$SIGN_UPDATE" --verify --ed-key-file - "$ARCHIVE" "$SIGNATURE"
swift scripts/sparkle-verify.swift "$ARCHIVE" "$SIGNATURE" "$PUBLIC_KEY"

NAME=${ARCHIVE:t}
LENGTH=$(wc -c < "$ARCHIVE" | tr -d " ")
PUB_DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
# 0.x도 Latest Release로 올리므로 releases/latest/download/appcast.xml이 늘 이 파일을 가리킨다. 항목은 이 릴리스 하나다.
cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>DJCrate</title>
    <link>https://github.com/${REPO}/releases</link>
    <item>
      <title>DJCrate ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_SYSTEM}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/${REPO}/releases/tag/${TAG}</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/${REPO}/releases/download/${TAG}/${NAME}" length="${LENGTH}" type="application/octet-stream" sparkle:edSignature="${SIGNATURE}"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$OUT"
print "만듦: $OUT ($VERSION, 빌드 $BUILD, ${LENGTH}바이트)"
