# USB 라이브러리 형식과 쓰기 규칙

이 문서는 rekordbox 7이 USB에 내보내는 라이브러리의 규칙을 적는다. 대상은 OneLibrary와 Device Library다. DJCrate는 이 규칙에 따라 USB를 읽는다. 쓰기도 이 규칙에 따른다. 로컬 rekordbox 라이브러리 쓰기는 `docs/rekordbox-internals.md`를 본다. 구조와 설계 결정은 `docs/architecture.md`의 "USB" 절을 본다.

목차:

- [§0 읽는 법·근거 표기](#0-읽는-법근거-표기)
- [§1 USB 파일 목록](#1-usb-파일-목록)
- [§2 OneLibrary](#2-onelibraryexportlibrarydb)
- [§3 Device Library](#3-device-libraryexportpdbexportextpdb)
- [§4 ANLZ 변환](#4-anlz-변환)
- [§5 경로·음원·아트워크](#5-경로음원아트워크)
- [§6 설정 파일](#6-설정-파일)
- [§7 쓰기 절차](#7-쓰기-절차)
- [§8 USB 안 수정](#8-usb-안-수정)
- [§9 확인 안 된 규칙](#9-확인-안-된-규칙)
- [§10 막아 둔 것](#10-막아-둔-것)
- [§11 새 USB 쓰기 경로를 여는 방법](#11-새-usb-쓰기-경로를-여는-방법)
- [§12 실물 USB 쓰기](#12-실물-usb-쓰기)

## 0. 읽는 법·근거 표기

- 경로는 USB 루트 기준 상대 경로(`UsbLayout`)다. 경로는 NFC로 쓴다.
- 칸 이름은 두 형식을 합친 모델(`UsbLibrary`)의 이름이다. 파일 안 이름이 다르면 함께 적는다.
- **근거**: 규칙은 rekordbox 화면에서 만든 결과 파일을 칸 단위로 읽어 알아낸다.
  - rekordbox 실행 파일은 분석하지 않는다.
  - "근거: rekordbox 7.2.18 골든(2026-09-26 내보내기) 관찰"은 rekordbox 7.2.18이 빈 USB에 내보낸 결과를 읽어 본 것이다.
  - 코드는 골든의 쪽, 표, 파일 덩어리 바이트를 넣지 않는다.
  - 칸 하나의 관찰값만 근거 주석을 단 이름 붙은 상수로 둔다.
  - 외부 자료는 `THIRD_PARTY_NOTICES.md`에 적은 것만 쓴다.
- **[추정]**: 관찰에서 추정한 것이다. rekordbox 실험으로 아직 가르지 못했다.
- **확인 안 된 규칙**(`UsbProvisionalRule`, §9): rekordbox 실험으로 아직 확인하지 않은 동작에 이름을 붙여 계획에 싣는다.
  - 늘 막는 규칙(`carriedDeviceRows`) 말고는 디스크 이미지도 실물도 막지 않는다.
  - 곡 내용 규칙은 미리 보기와 확인 창에 "CDJ에서 확인하지 않은 항목"으로 알린다.
  - 실험으로 확인한 규칙은 `confirmed`에 더한다(§11).
- 시험 재료는 모두 합성이다. 곡 제목, 경로, ID는 지어낸 값이다. 골든·로컬 라이브러리의 수치는 문서와 시험에 적지 않는다.

## 1. USB 파일 목록

경로는 USB 루트 기준(`UsbLayout`)이다.

| 경로 | 무엇 | DJCrate |
|---|---|---|
| `PIONEER/rekordbox/exportLibrary.db` | OneLibrary(§2) | 만든다·고친다 |
| `PIONEER/rekordbox/export.pdb`·`exportExt.pdb` | Device Library(§3) | 만든다·고친다 |
| `PIONEER/rekordbox/playlists3.sync`·`playlists3Plus.sync` | 장치별 동기화 선택 XML | 읽기·고쳐 쓰기·새로 만들기(#233, 2026-10-08 실험으로 확인한 칸 규칙). 한 형식의 파일만 있으면 막음 |
| `PIONEER/USBANLZ/P???/????????/ANLZ000N.DAT`·`.EXT`·`.2EX` | 곡마다 분석 파일 셋(§4) | 만든다. 폴더 이름은 §5 "분석 파일(ANLZ) 자리" |
| `PIONEER/Artwork/%05d/a{id}.jpg`·`a{id}_m.jpg`·`b{id}.jpg`·`b{id}_m.jpg` | 아트워크(a는 Device Library, b는 OneLibrary) | 만든다(§5) |
| `Contents/…` | 음원 | 복사한다(§5) |
| `PIONEER/MYSETTING.DAT`·`MYSETTING2.DAT`·`DJMMYSETTING.DAT` | 기기 설정(§6) | 첫 판 내보내기는 만들지 않는다. 선택으로 켜는 옮기기만 한다 |
| `PIONEER/DEVSETTING.DAT` | 기기 설정 | 만들지 않는다. rekordbox 내보내기도 만들지 않음 |
| `PIONEER/rekordbox/exportLibrary.db-wal`·`-shm`·`-journal` | SQLite 사이드카 | 만들지 않는다. 읽을 때는 사본에서만 정리한다(§2.3) |
| `.djc-part-*` | DJCrate가 쓰는 도중의 임시 파일 | 쓰기가 끝나면 남지 않는다(§7) |
| `.fseventsd`·`.Spotlight-V100`·`.Trashes`·`.TemporaryItems`, `._*` | macOS가 만드는 것 | 비교·지문에서 뺀다(`systemIgnored`, AppleDouble) |
| `PIONEER/extracted/`·`PIONEER/CDP/`·`PIONEER/djprofile.nxs` | 자격 증명·프로필 | **열지 않는다**: 열거·읽기·복사·해시하지 않는다. 트리 순회는 이름만 보고 건너뛴다. "있음"도 알리지 않는다(`UsbLayout.neverRead`) |

기기(CDJ, OPUS-QUAD 등)가 만드는 것은 아래와 같다.

- 재생 기록: OneLibrary history·history_content, Device Library 표 11·12.
- OneLibrary의 cue, recommendedLike, hotCueBankList, hotCueBankList_cue 행.
- 곡의 기기 칸: rating, 재생 횟수, hasModified.
- 기기가 연 뒤의 롤백 모드 머리와 `-wal`·`-journal`.

DJCrate는 이 행을 지우지 않는다. 다시 만들지도 않는다(§2.10, `carriedDeviceRows`).

## 2. OneLibrary(exportLibrary.db)

근거: rekordbox 7.2.18 골든(2026-09-26 내보내기) 관찰.

### 2.1 파일·암호

- 위치는 `PIONEER/rekordbox/exportLibrary.db`다. SQLCipher 4 기본값을 그대로 쓴다. 값은 아래와 같다.
  - cipher_page_size와 page_size는 4096이다.
  - kdf_iter는 256000이다.
  - PBKDF2_HMAC_SHA512와 HMAC_SHA512를 쓴다.
  - 평문 머리 0: 파일 첫 16바이트가 salt다.
  - 쪽마다 예약 80바이트가 있다.
  - 따로 cipher PRAGMA를 주지 않는다.
- 키는 64자 영숫자 **문자열 키**다. `master.db`의 16진수 키와 다르다.
  - `RekordboxKey.oneLibrary()`가 pyrekordbox(MIT)의 상수를 푼다. 푸는 방법은 `master.db` 키와 같다: base85 → XOR → zlib.
  - `CipherDatabase(path:key: .passphrase(…), mode:)`가 `PRAGMA key = '<키>'`로 키를 넣는다.
  - 키 글자는 `[A-Za-z0-9]`만 받는다.
  - 키는 로그, 출력, 시험에 쓰지 않는다.
- rekordbox가 만든 파일의 모양은 아래와 같다.
  - journal_mode는 wal이다. 머리 18·19바이트는 2/2다.
  - user_version 0, application_id 0, auto_vacuum 0. 인코딩은 UTF-8이다.
  - 트리거, 뷰, AUTOINCREMENT가 없다. 제약은 PK뿐이다.
- 기기(OPUS-QUAD)가 연 뒤에는 롤백 모드(1/1)다. SQLite 3.33.0 도장이 찍힌다. 두 모양 모두 읽는다.

### 2.2 스키마

표 22와 인덱스 4를 아래 순서로 만든다. DDL 전체는 `Tests/Support/Fixtures/Resources/onelibrary-7.2.18-schema.sql`에 있다. 이 파일은 rekordbox가 만든 `sqlite_master.sql`과 글자까지 같다. `OneLibrarySchema`가 칸 표에서 DDL을 만든다.

자료형은 소문자 `integer`·`varchar`다. `integer primary key`만 rowid 별칭이다. 철자도 그대로 둔다: album `isComplation`, cue `OutFileOffsetInBlock`.

| 표 | 칸 수 | 표 | 칸 수 |
|---|---|---|---|
| content | 46 | hotCueBankList_cue | 3 |
| genre | 2 | history | 5 |
| artist | 3 | history_content | 3 |
| album | 6 | image | 2 |
| label | 2 | cue | 22 |
| key | 2 | menuItem | 3 |
| color | 2 | category | 4 |
| playlist | 6 | sort | 5 |
| playlist_content | 3 | property | 6 |
| hotCueBankList | 6 | recommendedLike | 4 |
| myTag | 5 | myTag_content | 2 |

인덱스: `playlist_content(playlist_id)`, `myTag_content(myTag_id)`, `myTag_content(content_id)`, `hotCueBankList_cue(hotCueBankList_id)`.

### 2.3 읽기 규칙

- USB 원본은 열지 않는다. 늘 `UsbSnapshot.take`로 뜬 사본에서 읽는다.
- 사본 폴더는 아래 조건을 지킨다.
  - USB 밖이어야 한다. 뿌리와 같은 곳이나 그 아래는 안 된다. 견줄 때는 링크를 풀고 장치·inode를 본다.
  - 있다면 비어 있어야 한다. 없어도 된다. 남은 `-wal`·`-shm`이 있으면 SQLite가 사본과 함께 집어 가기 때문이다.
- 사본은 아래 순서로 뜬다.
  1. `PIONEER/rekordbox/`에서 아래 파일 중 있는 것만 복사한다.
     - `exportLibrary.db`, `-wal`, `-shm`, `-journal`, `export.pdb`, `exportExt.pdb`.
     - 본 DB가 없으면 사이드카는 복사하지 않는다.
     - 파일마다 복사 전후 크기·mtime이 같아야 한다. 다르면 `sourceChangedDuringCopy`다.
     - 원본 크기, mtime, SHA-256을 지문(`UsbFingerprint`)에 남긴다.
     - 링크와 일반 파일이 아닌 것은 복사하지 않는다. 그런 것은 `readFailed`다.
     - 열지 않는 경로(`PIONEER/extracted`·`PIONEER/CDP`·`djprofile.nxs`)는 건드리지 않는다.
  2. `-shm` 사본은 지운다. SQLite가 WAL에서 다시 만든다.
  3. `-wal`이나 `-journal`이 있었으면 사본을 쓰기 가능하게 한 번 연다. 이때 `sqlite_master`를 읽어 hot journal을 롤백한다. 그 뒤 `PRAGMA wal_checkpoint(TRUNCATE)`를 실행한다. 마지막으로 닫는다. 롤백·WAL 복구는 쓰기 가능한 연결에서만 된다.
  4. 읽기 전용으로 다시 연다. `PRAGMA integrity_check`는 "ok"여야 한다. `PRAGMA cipher_integrity_check`는 0줄이어야 한다. 아니면 `readFailed`다.
  5. 머리 18·19바이트는 암호문이라 직접 읽을 수 없다. 그래서 `PRAGMA journal_mode`로 WAL·롤백 모양을 기록한다.
  - 어느 단계에서 멈춰도 뜬 사본을 지운다. 사본을 연 SQLite가 만든 사이드카도 지운다.
- 쓰기 가능한 연결로 여는 정리(3)는 방금 만든 사본에만 한다.
  - 실험 명령 `djc lab onelib-sql`은 파일 하나를 사본으로 떠야 한다.
  - 이 명령은 `UsbSnapshot.copyDatabase`로 db·`-wal`·`-journal`을 새 파일로 복사한다. 그 뒤 그 사본만 정리한다.
- 정수 칸은 64비트로 읽는다. My Tag ID, masterDbId, myTagMasterDBID가 2³¹을 넘을 수 있다.
- 모델에 담지 않는 표에 행이 있으면 표 위치와 행 수만 `unknownRows`에 남긴다. 그런 표는 cue, hotCueBankList, hotCueBankList_cue, recommendedLike다. 쓸 때 조용히 지우지 않게 하려는 것이다.

### 2.4 호환 검사

`OneLibraryCompatibility.check`는 아래 조건을 모두 만족해야 통과시킨다.

- 표 22와 인덱스 4가 정확히 있다.
- 표마다 칸 이름, 선언 자료형, 순서, 기본 키가 같다.
- 인덱스마다 표와 칸이 같다.
- 뷰와 트리거가 없다.
- property가 한 행이다. `dbVersion`은 "1000"이다.

하나라도 어긋나면 `UsbError.formatUnsupported`다. 이때 읽지도 고치지도 않는다. SQLite는 `PRAGMA table_info`에서 표준 자료형 이름 integer를 대문자로 돌려준다. 그래서 자료형은 대소문자 차이를 빼고 비교한다.

제약은 기본 키뿐이어야 한다. `table_info`의 NOT NULL과 기본값은 비어 있어야 한다. `table_info`에 드러나지 않는 제약은 CHECK, AUTOINCREMENT 등이다. 이런 제약은 `sqlite_master.sql`을 스키마 문장과 견줘 본다. 이때 대소문자와 빈칸 차이만 뺀다.

`sqlite_sequence`는 AUTOINCREMENT 표다. `sqlite_autoindex_…`는 UNIQUE 등의 인덱스다. 둘 다 모르는 표·인덱스로 거부한다. ANALYZE 통계 표(`sqlite_stat…`)만 넘긴다.

### 2.5 칸 대응(모델 ← OneLibrary)

| 모델(`UsbTrack`) | content 칸 | 읽는 법 |
|---|---|---|
| id | content_id | |
| title / titleForSearch / subtitle | 같은 이름 | NULL → ""(titleForSearch는 nil 그대로) |
| bpmx100 / lengthSeconds / trackNo / discNo | bpmx100 / length(초) / trackNo / discNo | |
| artistID·remixerID·originalArtistID·composerID | artist_id_artist·_remixer·_originalArtist·_composer | NULL → nil |
| lyricistArtistID | artist_id_lyricist | 작사가 글자(`lyricist`)는 OneLibrary에 없어 "" |
| albumID·genreID·labelID·keyID / imageID | album_id·genre_id·label_id·key_id / image_id | NULL → nil |
| colorID | color_id | NULL → 0 |
| comment / rating / releaseYear / releaseDate / dateCreated / dateAdded | djComment / 같은 이름 | 날짜는 글자 그대로 |
| path / fileName / fileSize / fileType / bitrate / bitDepth / sampleRate / isrc | 같은 이름(sampleRate ← samplingRate) | |
| djPlayCount / hotCueAutoLoad / kuvoDeliver / kuvoDeliveryComment | djPlayCount / isHotCueAutoLoadOn(≠0) / isKuvoDeliverStatusOn(≠0) / kuvoDeliveryComment | |
| masterDbId / masterContentId | 같은 이름 | 64비트 |
| analysisDataPath / analysedBits / contentLink / hasModified | analysisDataFilePath / 같은 이름 | |
| 갱신 횟수 셋 | cueUpdateCount·analysisDataUpdateCount·informationUpdateCount | INTEGER → 10진 글자, TEXT '' → "", NULL → "" |
| deviceFields[.oneLibrary] | rating·djPlayCount·hasModified | 기기가 바꿀 수 있는 칸 |

그 밖의 표 대응은 아래와 같다.

- artist: name, nameForSearch.
- album: name, artist_id, image_id, isComplation, nameForSearch.
- genre, key, label, color: name.
- image: path → `oneLibraryPath`.
- playlist: sequenceNo → 형식별 순서, attribute, playlist_id_parent → parentID, image_id.
- playlist_content: sequenceNo 순 → 형식별 항목.
- myTag: attribute 1 = 분류, myTag_id_parent → parentID.
- myTag_content.
- menuItem: name을 감싼 U+FFFA·U+FFFB를 뗀다.
- category, sort.
- property: 한 행.
- history, history_content: sequenceNo 순.

### 2.6 두 형식 합치기·투영

- 모델(`UsbLibrary`)은 두 형식의 칸을 모두 담는다. 칸마다 아래 두 가지를 `UsbFieldFormats` 한 표에 둔다.
  - 그 값을 실제로 담는 형식.
  - 그 칸이 없는 형식의 리더가 넣는 기본값.
  - 예: `lyricist`, category `infoOrder`, `pdbDate`는 Device Library에만 있다. `titleForSearch`, album `imageID`, `createdDate`는 OneLibrary에만 있다.
- `UsbLibrary.merge`의 규칙은 아래와 같다.
  - 한 형식에만 있는 칸은 그 형식 값을 그대로 지킨다. 다른 형식 리더의 빈 값으로 덮지 않는다. 비교도 하지 않는다.
  - 두 형식 모두에 있는 칸은 OneLibrary 값이 앞선다. 값이 다르면 불일치로 보고한다.
  - 같은 id인데 경로(NFC)가 다른 곡은 편집을 막는 불일치다. 한 형식에만 있는 곡도 편집을 막는 불일치다.
- 재생 목록은 번호가 아니라 자리로 짝짓는다. 이 일은 `UsbPlaylistPairing`이 한다(#233).
  - rekordbox는 새 목록 번호를 형식마다 다르게 정한다(2026-10-08 실험). Device Library는 빈 번호를 다시 쓴다. OneLibrary는 가장 큰 값+1을 쓴다.
  - 그래서 같은 목록이 형식마다 다른 번호를 갖는다. 같은 번호가 형식마다 다른 목록이 되기도 한다. 그래서 아래 규칙을 쓴다.
  - 짝짓기: 맨 위부터 내려간다. 짝지은 부모 아래에서 이름이 글자 그대로 같은 목록을 찾는다. 종류(`attribute`)도 같은 목록이 형식마다 하나씩이면 짝짓는다. 같은 키가 여럿이면 번호까지 같은 것만 짝짓는다. 나머지는 짝짓지 않는다. 짝이 없는 폴더 아래 목록도 짝짓지 않는다.
  - 짝이 없는 목록은 한 형식 목록(`playlistOnlyIn`)으로 그대로 둔다. 이 목록은 편집을 막지 않는다. 이렇게 해야 잘못 짝지어 다른 목록을 덮는 일이 없다. 잃는 일도 없다.
  - 합친 모델의 `id`는 대표 번호다.
    - 짝지은 목록과 OneLibrary에만 있는 목록은 OneLibrary 번호다.
    - Device Library에만 있는 목록은 그 번호다. OneLibrary가 그 번호를 쓰면 −번호다.
    - 형식 번호가 대표 번호와 다르면 `formatIDs`에 둔다(`id(in:)`).
    - `parentID`는 부모의 대표 번호다.
    - 투영은 번호와 부모를 그 형식 번호로 되돌린다. 쓰기·검증은 형식 번호를 그대로 쓴다. 여기서 쓰기·검증은 OneLibrary 작성기, `PdbWriter`, 검증기를 말한다.
    - 편집은 대표 번호로 가리킨다.
  - 새 목록 번호는 두 형식의 번호와 pdb 죽은 번호를 모두 본 다음 번호다. 두 형식에 같은 번호로 쓴다.
  - 맨 위에서 닿지 않는 목록만 대표 번호와 부모를 정할 수 없다. 그런 목록은 없는 부모, 고리, 한 형식 안 번호 중복이다. 이때 `playlistConflict`로 편집을 막는다.
  - 근거: 2026-10-08 rekordbox 7.2.x 동기화 실험 두 벌의 단계별 USB 사본 34개.
    - 단계는 체크, 이름 바꾸기, 옮기기, 해제, 지우기, 폴더 이름 바꾸기다. 형식 번호가 다른 짝이 단계마다 0–14개 있었다.
    - 이 규칙은 모든 목록을 모호함 없이 짝지었다. 합친 목록 수는 형식별 목록 수와 같았다. 두 투영은 형식별 읽기와 같았다.
    - 두 선택 파일의 `Dev_ID` 짝도 모두 같은 대표 번호를 가리켰다.
    - 번호가 다른 짝을 고쳐 쓴 사본 하나를 봤다. 그 사본에서 두 형식이 각자 번호로 바뀌었다. 나머지 목록은 그대로였다. 값은 적지 않는다.
- artist, album, genre, key, label, color, image, My Tag, menuItem, category, sort 행에는 형식별 소속 칸이 없다.
  - 한 형식에만 있는 행은 합집합에 둔다. 이 행은 `sharedRowDiffers`로 보고한다. 편집은 막지 않는다.
  - 읽은 형식을 `oneFormatRows`에 적는다. 투영은 그 행을 그 형식에만 둔다.
  - 다른 형식의 곡, 앨범, 목록이 그 행을 가리키게 되면 그 형식 투영에도 넣어 쓴다. My Tag는 연결이, 메뉴는 분류·정렬이 가리키는 쪽이다.
  - 사례: #234. rekordbox 동기화 USB 사본에서 아무 곡도 가리키지 않는 key 행이 Device Library에만 있었다. image 행은 OneLibrary에만 있었다. 전에는 모든 편집이 OneLibrary 다시 읽기 `key.onlyRight`로 막혔다.
- `projected(to:)`는 그 형식에 있는 곡, 목록, My Tag 연결과 그 형식 몫만 남긴다.
  - 그 형식 몫은 기록, 항목, 기기 칸이다.
  - 그 형식이 담지 않는 칸은 그 형식 리더의 기본값으로 바꾼다.
  - 불일치 없는 USB에서는 `merge(ol, dl).projected(to: .oneLibrary) == ol`이다. 불일치 없는 USB는 위 보고가 하나도 없는 USB다. 목록 번호가 형식마다 달라도 같다.
  - 쓰기·검증은 늘 형식별 투영과 비교한다. 비교는 `UsbLibraryDiff`의 `formats`가 한다.
- `UsbLibraryDiff`와 `djc lab usb-diff`는 칸 이름, ID, 수만 출력한다. 제목, 이름, 경로 값은 찍지 않는다. ID를 무시하고 견줄 때 이름(경로)이 같은 행이 여럿이면 나온 순서대로 짝짓는다.

### 2.7 쓰기: 로컬 → 목표 모델(`UsbLibraryBuilder`)

로컬 스냅샷 사본(`UsbLocalSource`)과 내보내기 계획(§5)으로 목표 모델과 파일 작업 목록을 만든다. 라이브 master.db를 연 연결이면 읽지 않는다. 파일은 옮기지 않는다. 음원·아트워크 복사와 분석 파일 변환은 쓰기 단계 몫이다.

- 파일 작업
  - 새로 쓰는 음원: 계획이 `create`인 것만 쓴다. 같은 음원을 함께 쓰는 곡과 USB에 이미 있는 음원은 뺀다.
  - 아트워크: `artwork_s.jpg` → `a{id}.jpg`·`b{id}.jpg`, `artwork_m.jpg` → `a{id}_m.jpg`·`b{id}_m.jpg`. Device Library를 쓸 때만 `a`를 만든다. OneLibrary를 쓸 때만 `b`를 만든다.
  - 분석 파일: 로컬 `.DAT`·`.EXT`·`.2EX` → 계획의 `.DAT` 경로.
  - 목적지는 USB 루트 기준 상대 경로다.
- ID
  - content, image, 재생 목록은 계획 값이다(§5 ID).
  - artist: 곡을 content ID 순서로 돈다. 곡마다 곡 아티스트 → 앨범 아티스트 → 작곡가 → 리믹서 → 원곡자 순서로 본다. 처음 나올 때 새 번호를 준다.
    - 같은 로컬 아티스트 ID는 같은 USB 번호를 받는다.
    - [추정] 로컬 ID로만 합친다. 이름이 같은 다른 로컬 행은 따로 둔다.
    - 리믹서·원곡자의 순서는 값이 있는 곡을 보지 못했다.
  - album, genre, key, label: 곡 순서대로 처음 나올 때 새 번호를 준다. label은 [추정] genre와 같은 방식이다.
  - color, menuItem, category, sort, My Tag: 로컬 ID 그대로.
  - 로컬 ID가 비면 참조 칸은 NULL이다. 조인할 이름 행이 없어도 NULL이다.
  - 곡이 쓰지 않는 artist, album, genre, key, label 행은 넣지 않는다. color는 로컬 색을 모두 넣는다.
- 표별 행(새 USB)

| 표 | 행 | 값 |
|---|---|---|
| content | 곡마다 | §2.8 |
| genre·key·label | 쓰인 것 | name = djmdGenre.Name·djmdKey.ScaleName·djmdLabel.Name |
| artist | 쓰인 것 | name = djmdArtist.Name, nameForSearch NULL |
| album | 쓰인 것 | name, artist_id = AlbumArtistID의 USB 번호(NULL·빈 글자 → NULL), image_id NULL, isComplation = Compilation, nameForSearch NULL |
| color | 로컬 지우지 않은 색 모두 | color_id = ID, name = Commnt |
| image | 그림 있는 곡마다 | path = `/PIONEER/Artwork/%05d/b{id}.jpg` |
| playlist | 계획 목록·폴더 | sequenceNo = 계획의 형제 순번, image_id NULL, attribute 0 목록·1 폴더, playlist_id_parent(맨 위 0) |
| playlist_content | 목록 항목 | (playlist_id, content_id, sequenceNo 1..N). 목록 id 순, 순번 순으로 넣는다. PK 없는 표라 넣는 순서가 rowid다 |
| myTag | 로컬 지우지 않은 행 모두 | myTag_id = ID(64비트), sequenceNo = Seq − 1, attribute 1 분류·0 태그, myTag_id_parent(root → 0). 곡에 안 쓰인 태그도 넣는다 |
| myTag_content | 0 | 쓰지 않는다(`myTagLinks`) |
| menuItem | 로컬 모두 | kind = Class + 256, name = U+FFFA + Name + U+FFFB |
| category | 로컬 지우지 않은 행 | sequenceNo = Seq, isVisible = Disable ≠ 1. InfoOrder·Disable은 Device Library 몫으로 모델에만 둔다 |
| sort | 로컬 지우지 않은 행 | sequenceNo = Seq, isVisible = Disable ≠ 1, isSelectedAsSubColumn = Disable = 2 |
| property | 1 | deviceName '', dbVersion '1000', numberOfContents = OneLibrary에 있는 곡 수(Device Library에만 있는 곡은 세지 않음), createdDate = 오늘(YYYY-MM-DD), backGroundColorType 0, myTagMasterDBID = 1 … 2³¹−1 난수(`myTagMasterDBID`) |
| cue·history·history_content·recommendedLike·hotCueBankList·hotCueBankList_cue | 0 | 로컬에 자료가 있어도 비운다. 큐는 분석 파일에만 둔다 |

### 2.8 content 칸(로컬 `djmdContent` = c)

| 칸 | 값 |
|---|---|
| content_id | 계획 ID |
| title·subtitle·djComment(c.Commnt)·releaseDate·dateCreated·dateAdded(c.StockDate)·isrc·kuvoDeliveryComment(c.DeliveryComment) | 로컬 글자 그대로, NULL → '' |
| titleForSearch | NULL |
| bpmx100·length·trackNo·discNo·rating·releaseYear·fileSize·fileType·bitrate·bitDepth·samplingRate·djPlayCount·analysedBits | c.BPM(이미 ×100)·Length(초)·TrackNo·DiscNo·Rating·ReleaseYear·FileSize·FileType·BitRate·BitDepth·SampleRate·DJPlayCount·Analysed, NULL → 0 |
| artist_id_artist·_remixer·_originalArtist·_composer | 로컬 아티스트의 USB 번호, 없으면 NULL |
| artist_id_lyricist | 0. 작사가는 로컬에 글자로만 있다. 값이 있으면 `metadataSeenEmptyOnly` |
| album_id·genre_id·label_id·key_id | 로컬 행의 USB 번호, 없으면 NULL |
| color_id | CAST(c.ColorID AS INTEGER), NULL → 0 |
| image_id | 계획 image ID, 그림 없으면 NULL(`artworkMissing`) |
| path·fileName | 계획 경로(NFC)와 그 끝 성분 |
| isHotCueAutoLoadOn·isKuvoDeliverStatusOn | c.HotCueAutoLoad·c.DeliveryControl이 'on'(대소문자 무시)이면 1, 아니면 0 |
| masterDbId·masterContentId | CAST(c.MasterDBID·c.MasterSongID AS INTEGER) |
| analysisDataFilePath | 계획 분석 경로 |
| contentLink | 0x0C0700 \| (c.ContentLink & 0x100000). 0x100000은 로컬 `.2EX`에 PVDI가 있다는 뜻 |
| hasModified | 0 |
| cueUpdateCount·analysisDataUpdateCount·informationUpdateCount | c.CueUpdated·AnalysisUpdated·TrackInfoUpdated를 TEXT로 넣는다(NULL → ''). INTEGER 친화성 때문에 숫자 글자는 INTEGER, ''는 TEXT로 남는다 |

- 글자 칸은 빈 글자를 포함해 늘 TEXT다. 없을 수 있는 정수 칸만 NULL이 된다. 그런 칸은 참조 칸과 image_id다. NFC로 맞추는 것은 path와 fileName뿐이다.
- 모델에는 Device Library용 칸도 채운다.
  - `lyricist` = c.Lyricist.
  - 형식별 기기 칸: rating, 재생 횟수. OneLibrary만 hasModified 0.

### 2.9 새 파일 만들기(`OneLibraryWriter.create`)

Mac 준비 폴더에 새 `exportLibrary.db`를 만든다. 파일이나 사이드카가 이미 있으면 만들지 않는다. 모델의 OneLibrary 투영만 쓴다. 기기 기록이 든 모델은 다시 만들 수 없다. 모델에 담지 않는 표의 행이 든 모델도 다시 만들 수 없다. 이런 모델은 막는다(`carriedDeviceRows`).

1. 문자열 키로 새 파일을 연다. 다른 cipher PRAGMA는 없다.
2. 표를 만들기 **전에** `PRAGMA journal_mode=WAL`을 건다. 그러면 파일 머리가 WAL 모양이 된다.
3. `BEGIN` → 스키마 26문장(§2.2 순서) → 행 → `COMMIT`. `integer primary key` 표는 id 순서로 넣는다. 그러면 rowid = id가 된다.
4. `PRAGMA wal_checkpoint(TRUNCATE)`는 (0, 0, 0)이어야 한다. integrity는 ok여야 한다. cipher_integrity_check는 0줄이어야 한다. 그 뒤 닫는다. `-wal`·`-shm`이 없어야 한다.
5. 다시 열어 확인한다(`verify`). 확인 항목은 아래와 같다.
   - 사이드카가 없다.
   - 호환 검사를 통과한다(§2.4).
   - integrity가 ok다.
   - 다시 읽은 모델이 모델의 OneLibrary 투영과 같다. OneLibrary 칸만 비교한다.
   - 실패하면 만든 파일을 지운다.
   - 사이드카가 있으면 DB를 열지 않는다. 사이드카만 보고한다. 열면 닫을 때 SQLite가 남은 `-wal`을 본 파일에 합친다. 그 뒤 `-wal`을 지운다. 그러면 확인할 파일과 증거가 바뀐다.

- 기기의 SQLite 3.33에 없는 기능은 쓰지 않는다. 그런 기능은 STRICT, 생성 칸 등이다. sqlite_master rowid, schema cookie, change counter, SQLite 버전 도장은 맞추지 않는다.
- 읽기 전용 연결은 WAL 모양 파일 옆에 `-wal`·`-shm`을 남긴다. 확인은 쓰기 가능하게 연다. 그 연결을 `query_only`로 막는다. 그러면 닫을 때 SQLite가 사이드카를 치운다.

### 2.10 USB 사본 고치기(`OneLibraryWriter.apply`)

`UsbSnapshot`으로 병합을 끝낸 USB DB **사본**에 편집 단계마다 차이만 SQL로 적용한다. 받는 모델은 두 형식을 합친 모델이어도 된다.

1. 쓰기 가능하게 열어 호환 검사를 한다. 그 뒤 `BEGIN IMMEDIATE`를 한다. 받아들인 모델은 지금 모델이다.
2. 단계마다 `SAVEPOINT`를 잡는다.
   - 편집을 적용한 모델을 다듬는다(아래).
   - 받아들인 모델과의 OneLibrary 차이를 SQL로 적용한다.
   - 성공하면 `RELEASE`하고 그 모델을 받아들인다.
   - 모델 적용이나 SQL이 실패하면 `ROLLBACK TO`·`RELEASE`를 한다. 그 편집만 건너뛴다. 이유는 기술 정보로 남긴다.
   - 다음 편집은 건너뛴 편집이 빠진 모델 위에 적용한다.
3. 같은 연결로 다시 읽어 **받아들인 모델의 OneLibrary 투영**과 OneLibrary 칸만 비교한다.
   - 원래 목표(모든 편집)와 견주면 건너뛴 편집 때문에 늘 어긋난다.
   - 투영 없이 합친 모델과 견주면 Device Library 전용 칸·곡·목록 때문에 늘 어긋난다.
   - 다르면 전체 `ROLLBACK`을 한다. 그리고 `UsbError.writeRolledBack`를 낸다. 사본은 그대로다.
4. `COMMIT` → `wal_checkpoint(TRUNCATE)` → 닫기 → 확인(§2.9의 5). 돌려주는 적용 모델은 투영하지 않은 합친 모델이다. Device Library를 같은 편집 집합으로 다시 만들 때 이 모델을 쓴다.
   - COMMIT 뒤의 체크포인트·확인이 실패하면 사본에는 편집이 이미 들어가 있다. 그래서 되돌렸다고 알리지 않는다(`OneLibraryCommittedCopyError`).
   - 호출하는 쪽은 그 사본을 버린다. 그리고 USB에서 다시 뜬다. 같은 사본에 다시 적용하면 편집이 두 번 들어간다.

- 차이 SQL
  - 지우기를 먼저 한다.
  - 곡 빼기는 content 행과 그 곡의 myTag_content 행을 지운다.
  - 더하기는 INSERT다. 바뀐 곡은 UPDATE다. 이때 rating, djPlayCount, hasModified는 쓰지 않는다.
  - artist, album, genre, key, label, image는 id로 짝지어 지우기·더하기·고치기를 한다.
  - 목록은 행을 고친다. 항목이 바뀐 목록만 playlist_content를 지운 뒤 1..N으로 다시 넣는다.
  - property는 numberOfContents만 고친다. 단계 모델 값은 믿지 않는다. OneLibrary에 있는 곡 수로 센다.
- 모델 다듬기: 아래는 USB 값을 지킨다.
  - 두 쪽에 다 있는 곡의 기기 칸.
  - 색, 메뉴, 카테고리, 정렬, My Tag, 기록, 모르는 표 행.
  - property의 deviceName, dbVersion, createdDate, backGroundColorType, myTagMasterDBID.
  - My Tag 연결은 더하지 않는다. 뺀 곡의 연결만 없앤다.
  - 이 편집으로 아무도 가리키지 않게 된 album, artist, genre, key, label, image 행은 뺀다. 원래 쓰이지 않던 행은 그대로 둔다.
- 건드리지 않는 것: history, history_content, cue, recommendedLike, hotCueBankList, hotCueBankList_cue(기기 행). 그 표를 바꿔야 하는 편집은 건너뛴다.
  - 기기가 남긴 큐·추천·재생 기록(history_content)이 가리키는 곡을 빼는 편집.
  - 핫큐 뱅크(hotCueBankList.image_id)가 가리키는 그림이 고아가 되는 편집.
- 목록 항목이 없는 곡을 가리키게 되는 편집도 건너뛴다. 이번 편집에서 뺀 곡은 항목을 고치지 않은 목록까지 모두 본다. USB에 원래 있던 어긋남 때문에 모든 편집이 막히지 않게 이번에 뺀 곡만 본다.
- 파일 머리 모양(WAL 2/2·롤백 1/1)은 바꾸지 않는다. `journal_mode`를 건드리지 않는다.
- 만들기·고치기·확인 모두 Mac 준비 폴더나 USB DB 사본만 받는다. 파일이나 그 폴더의 realpath가 `/Volumes` 아래면 열기 전에 막는다(`libraryOnVolume`). USB에는 `UsbWriter`(백업·저널·실물 관문)로만 쓴다.

### 2.11 쓰기 실험 명령

- `djc lab onelib-rebuild <USB 폴더> <출력 폴더>`: USB OneLibrary를 사본으로 떠서 모델로 읽는다. 그 모델로 `<출력>/PIONEER/rekordbox/exportLibrary.db`를 새로 만든다. 그 뒤 표마다 rowid·typeof·값과 sqlite_master.sql을 비교한다. 수만 출력한다.
- `djc lab onelib-export --db <사본> --share <share> (--playlist <ID> | --tracks <ID,…>) --out <출력 폴더> [--snapshot-time <ISO 8601>]`: 로컬 사본의 곡·목록으로 계획 → 모델 → `exportLibrary.db`만 만든다. 음원, 분석 파일, Device Library는 쓰지 않는다. 이어서 `djc lab usb-diff --onelibrary <골든> <출력>`으로 칸 단위로 견준다.
- 두 명령 모두 입력·출력은 임시 폴더 아래만 받는다. 출력 폴더가 있으면 비어 있어야 한다.

### 2.12 확인 안 된 것

- label 행의 번호·이름: 값이 있는 곡을 보지 못했다.
- 리믹서·원곡자 번호 순서.
- 작사가 글자가 있는 곡의 `artist_id_lyricist`(`metadataSeenEmptyOnly`).
- 검색 칸(titleForSearch·nameForSearch)은 NULL로만 봤다.
- My Tag 연결(`myTag_content`)은 쓰지 않는다(`myTagLinks`). myTagMasterDBID는 난수로 짓는다(`myTagMasterDBID`).
- 같은 이름의 다른 로컬 아티스트 행을 rekordbox가 합치는지. 지금은 로컬 ID로만 합친다.
- 기기 행이 가리키는 곡·그림을 USB에서 뺐을 때 기기·rekordbox가 어떻게 다루는지. 기기 행은 큐, 추천, 재생 기록, 핫큐 뱅크다. 그래서 그 편집은 막는다.
## 3. Device Library(export.pdb·exportExt.pdb)

근거: rekordbox 7.2.18 골든(2026-09-26 내보내기)을 관찰했다.

아티스트·앨범의 먼 오프셋 행 모양과 긴 ASCII(0x40)는 두 실험으로 확인했다. 하나는 rekordbox 7.2.x 경계 실험이고, 다른 하나는 7.2.19 실험 X1이다. 둘 다 2026-10-08에 했다. 자세한 내용은 §3.8 "먼 모양·긴 ASCII"에 있다. My Tag 먼 모양은 보지 못했으므로 읽기만 한다.

코드 위치는 다음과 같다.

- 읽기 코드는 `Sources/RekordboxKit/Usb/DeviceLibrary/`에 있다. 파일은 `PdbFile`, `PdbPage`, `PdbString`, `PdbRows`, `PdbReader`다.
- 쓰기 코드는 `Sources/RekordboxKit/Usb/Write/Pdb*.swift`에 있다(§3.8).
- 시험 재료는 `PdbBuilder`다. 칸 값으로 쪽을 조립한다.

### 3.1 파일 머리

파일은 4096바이트 쪽의 배열이다. 쪽 0이 파일 머리다. 쪽 `i`는 바이트 `i × 4096`에서 시작한다. 모든 정수는 little-endian이다.

| 오프셋 | 크기 | 칸 | 값 |
|---|---|---|---|
| 0x00 | u32 | | 0 |
| 0x04 | u32 | len_page | 4096 |
| 0x08 | u32 | num_tables | export 20, exportExt 9 |
| 0x0C | u32 | next_unused_page | 할당된 가장 큰 쪽 번호 + 1(파일 끝 너머 후보 포함) |
| 0x10 | u32 | (flag10) | 5 = rekordbox가 정상으로 닫음. 열린 채 뽑힌 USB에서는 다른 값 |
| 0x14 | u32 | sequence | 다음 쪽 순번(모든 쪽 순번보다 큼) |
| 0x18 | u32 | gap | 0 |
| 0x1C | 16 × num_tables | 표 포인터 | `{u32 type, u32 empty_candidate, u32 first_page, u32 last_page}`, type 0부터 오름차순 |

- first_page는 그 표의 인덱스 쪽이다.
- last_page는 사슬의 마지막 쪽이다. 데이터가 없으면 인덱스 쪽이다. 그 쪽 머리의 next_page가 empty_candidate다.
- empty_candidate는 0으로 채운 쪽이다. 또는 파일 끝 너머다.
- 쪽 크기가 4096이 아니면 `UsbError.readFailed`로 읽지 않는다. 표 수가 20·9가 아니어도 읽지 않는다.
- flag10은 보고서에 값만 남긴다. 막을지는 쓰기 쪽이 정한다.

### 3.2 쪽 머리(0x00–0x27)

| 오프셋 | 크기 | 칸 | 데이터 쪽 | 인덱스 쪽 |
|---|---|---|---|---|
| 0x04 | u32 | page_index | 자기 쪽 번호 | 같음 |
| 0x08 | u32 | type | 표 번호 | 같음 |
| 0x0C | u32 | next_page | 다음 쪽(마지막이면 empty_candidate) | 첫 데이터 쪽(없으면 empty_candidate) |
| 0x10 | u32 | seq | 그 쪽을 마지막으로 고친 순번 | 새로 만든 파일에서 1(rekordbox가 고치면 그때 순번) |
| 0x14 | u32 | u2 | 0 | 0 |
| 0x18–0x1A | 24비트 | 행 수 묶음 | `nro + (nr << 13)`: 아래 13비트 nro = 할당한 행 자리 수, 위 11비트 nr = 산 행 수 | 0 |
| 0x1B | u8 | flags | 0x24(지운 행 없음) / 0x34(nr < nro) | 0x64 |
| 0x1C | u16 | free | `4096 − 0x28 − used − 2·nro − 4·⌈nro/16⌉` | 0 |
| 0x1E | u16 | used | 힙 할당 바이트 합(죽은 행 포함) | 0 |
| 0x20·0x22 | u16 | tx_row_count·tx_row_index | 마지막 트랜잭션이 건드린 자리 수·첫 자리 | 보통 0x1FFF |
| 0x24 | u16 | u6 | 0 | 0x03EC |
| 0x26 | u16 | u7 | 0 | 인덱스 항목 수 |

- 행 수 묶음 예: 7자리·6행은 `07 C0 00`이고, 284자리·284행은 `1C 81 23`이다.
- 0x18을 u8 행 수로 읽으면 안 된다. 255행이 넘는 쪽(12바이트 행)에서 행을 잃는다.

인덱스 쪽 본문:

| 오프셋 | 값 |
|---|---|
| 0x28 | 자기 쪽 번호 |
| 0x2C | 첫 데이터 쪽(없으면 0x03FFFFFF) |
| 0x30 | 0x03FFFFFF |
| 0x34 | 0 |
| 0x38 | u16 항목 수 |
| 0x3A | 0x1FFF |
| 0x3C부터 | u32 항목 1004개 |
| 0xFEC–0xFFF | 0 |

- 빈 항목은 0x1FFFFFF8이다.
- 항목은 `(쪽 번호 << 3) | 아래 3비트`다. 지운 행이 있는 데이터 쪽을 가리킨다.
- 읽기는 인덱스 항목을 쓰지 않는다.

### 3.3 행 인덱스

행 인덱스는 쪽 끝에서 거꾸로 16자리씩 묶는다. 자리 `k`는 묶음 `g = k / 16`, `j = k % 16`, `base = 4096 − g × 0x24`에서 아래 위치에 있다.

- `base − 2`: u16 tx 비트(j번 비트)
- `base − 4`: u16 presence 비트(산 행)
- `base − 6 − 2j`: u16 행 오프셋. 힙 시작 0x28이 기준이다.

마지막(덜 찬) 묶음도 같은 계산이다. 행 바이트는 그 오프셋부터 힙에서 다음 행 오프셋까지다. 마지막 행은 used까지다. 행은 표별 고정 칸과 문자열 오프셋으로 해석한다. 범위는 행 밖 읽기를 막는 데만 쓴다.

### 3.4 문자열(DeviceSQL)

| 첫 바이트 | 모양 | 구조 |
|---|---|---|
| 홀수 `((n+1)<<1)+1` | 짧은 ASCII | 첫 바이트 + ASCII n바이트(끝 표시 없음). 빈 문자열 `03`, n ≤ 126 |
| `0x40` | 긴 ASCII | `40`, u16 길이 = 4 + n(머리 포함), `00`, ASCII n바이트(끝 표시 없음), 127자 이상 |
| `0x90` | UTF-16LE | `90`, u16 길이(머리 4 포함), `00`, UTF-16LE |
| `0x90` + 다섯째 바이트 `03` | ISRC 특수형 | `90`, u16 길이 = 4 + 1 + k + 1, `00`, `03`, ASCII k, `00`(트랙 문자열 0에만) |

- 126자까지의 ASCII는 짧은 ASCII다. 127자 이상의 순수 ASCII는 긴 ASCII(0x40)다. ASCII가 아닌 글자가 든 문자열은 UTF-16LE다. 이 판정은 `PdbStringEncoder.encode`가 한다.
- 긴 ASCII는 rekordbox 7.2.x 경계 실험(2026-10-08)에서 봤다. 본 곳은 아티스트 이름, 앨범 이름, 트랙 행 경로(문자열 20)다. 시험한 이름은 'A' × 127, 236, 244, 250이다.
- 그 밖의 칸에서는 긴 ASCII를 보지 못했다. 그 칸은 장르, 레이블, 키, 재생 목록, 아트워크, My Tag다. 작성기(`PdbStringEncoder.encoded`)는 같은 모양으로 쓰되 `pdbLongAscii`를 붙인다(§3.8).
- ISRC 특수형은 트랙 문자열 0에서만 읽는다(`isrcAllowed`, 기본 거짓). 다른 칸의 `90 … 00 03 …`은 첫 글자 아래 바이트가 3인 UTF-16이다.
- UTF-16과 긴 ASCII 문자열은 행 시작 기준 4바이트 경계에서 시작한다. 앞 빈 바이트는 0이다. 짧은 ASCII는 앞 문자열 바로 뒤에 붙는다.
- 긴 ASCII의 경계는 경계 실험의 아티스트·앨범 행과 트랙 행 경로에서 봤다. 'A' × 127에 가까운 모양의 이름은 아티스트 행에서 0x0C, 앨범 행에서 0x18에 시작했다.
- 모르는 첫 바이트, 행 밖으로 나가는 길이, 잘못된 UTF-16은 그 행만 문제로 남기고 계속 읽는다.

**철자(NFC, #233):** 이 규칙은 rekordbox와 다르다.

- rekordbox는 받은 철자 그대로 쓴다. 로컬 이름이 풀어 쓴 한글 NFD면 U+1100–U+11FF 자모를 그대로 UTF-16에 쓴다.
- CDJ-2000NXS는 NFD로 적힌 재생 목록 이름을 "~"로 보였다. 완성형(NFC)은 바르게 보였다. 이것은 2026-10-09에 관찰했다.
- 그래서 작성기는 사람이 읽는 문자열을 NFC로 바꿔 쓴다. 이것은 사용자 결정(2026-10-09)이다. 코드는 `PdbStringEncoder.encodedText`와 `UsbNameSpelling.deviceLibraryText`다.

NFC로 쓰는 칸:

- 트랙 문자열 1 작사가, 12 부제(mix_name), 16 코멘트, 17 제목
- 아티스트 이름, 앨범 이름, 장르 이름
- 레이블 이름, 키 이름, 색 이름
- 재생 목록 이름, My Tag 이름, columns 이름

그대로 쓰는 칸:

- 트랙 문자열 14 분석 파일 경로, 19 파일 이름, 20 파일 경로
- 아트워크 경로. 이 경로는 USB 파일의 실제 철자를 가리켜야 한다. 새 내보내기 경로는 §5대로 처음부터 NFC다.
- ISRC, 날짜, 갱신 횟수, 참·거짓 문자열, 표 19 문자열(ASCII 칸)
- 재생 기록(표 11·12)은 쓰지 않는다. §3.8을 본다.

NFC 규칙의 나머지는 다음과 같다.

- 철자가 바뀐 문자열이 있으면 `pdbStringNFC`를 붙인다. 곡 문자열이면 그 곡에도 붙인다.
- 행 크기와 아티스트·앨범 먼 모양은 NFC 철자로 정한다.
- OneLibrary(`exportLibrary.db`)는 바꾸지 않는다. 새 기기가 NFD를 어떻게 보이는지 모르기 때문이다. rekordbox와 같게 둔다.
- 비교: 모델 비교(Swift 문자열 `==`)는 NFC와 NFD를 같다고 본다. 그래서 다시 읽기 확인과 왕복 검사의 글자 칸은 그대로 통과한다. 철자만 다른 변화는 유니코드 스칼라로 본다(`UsbNameSpelling`, §8.3).

### 3.5 export.pdb 표

| 번호 | 표 | 행 |
|---|---|---|
| 0 | tracks | 아래 표 |
| 1·4 | genres·labels | u32 id, 문자열 @0x04 |
| 2 | artists | 아래 "artists 행" |
| 3 | albums | 아래 "albums 행" |
| 5 | keys | u32 id, u32 id(같은 값), 문자열 @0x08 |
| 6 | colors | u32 0, u8 id, u16 id, u8 0, 문자열 @0x08 |
| 7 | playlist_tree | u32 parent_id, u32 0, u32 sort_order, u32 id, u32 is_folder, 문자열 @0x14 |
| 8 | playlist_entries | u32 entry_index(1부터), u32 track_id, u32 playlist_id(12바이트). 항목은 entry_index 순 |
| 11·12 | history_playlists·history_entries | 아래 "기록 표 행". 해석하지 못하면 두 표 모두 행 수만 `unknownRows`로 |
| 13 | artwork | u32 id, 짧은 ASCII 경로 @0x04(`/PIONEER/Artwork/%05d/a%d.jpg`) |
| 16 | columns | u16 id, u16 code(= Class + 256), UTF-16 이름 @0x04(U+FFFA … U+FFFB로 감쌈) |
| 17 | category | u16 menuItemID, u16 id, u8 InfoOrder, u8 Disable, u16 Seq(8바이트). 보임 = Disable ≠ 1 |
| 18 | sort | u16 menuItemID, u16 id, u8 Disable, u8 Seq, u16 0(8바이트). 보임 = Disable ≠ 1, 보조 칸 = Disable = 2 |
| 19 | property | 아래 "property 행" |
| 9·10·14·15 | (모름) | 산 행 수만 `unknownRows` |

**artists 행**

- subtype 0x0060: 0x04 u32 id, 0x08 u8 0x03, 0x09 u8 이름 오프셋.
- 이름 오프셋은 짧은 ASCII면 0x0A, UTF-16과 긴 ASCII면 0x0C다.
- 먼 모양 0x0064: 0x09 = 0, 0x0A u16 오프셋 0x000C, 이름 @0x0C.

**albums 행**

- subtype 0x0080: 0x08 u32 앨범 아티스트(0 없음), 0x0C u32 id, 0x14 u8 0x03, 0x15 u8 이름 오프셋.
- 이름 오프셋은 짧은 ASCII면 0x16, UTF-16과 긴 ASCII면 0x18이다.
- 먼 모양 0x0084: 0x15 = 0, 0x16 u16 오프셋 0x0018, 이름 @0x18.

**기록 표 행**

- history_playlists(표 11): u32 id, 문자열 @0x04.
- history_entries(표 12): u32 track_id, u32 playlist_id, u32 entry_index.

**property 행**

subtype 0x0280(40바이트):

- 0x04 u32 곡 수
- 0x0C 짧은 ASCII 날짜(YYYY-MM-DD)
- 0x17 u8 버전 문자열("1000") 오프셋
- 0x18 u8 두 번째 문자열 오프셋

tracks 행은 subtype 0x0024이고 문자열 오프셋이 16비트다.

| 오프셋 | 크기 | 칸 | 모델(`UsbTrack`) |
|---|---|---|---|
| 0x00 | u16 | subtype 0x0024 | `trackRowExtras` |
| 0x02 | u16 | index_shift | 쓰지 않음 |
| 0x04 | u32 | bitmask | `trackRowExtras` |
| 0x08 | u32 | sample_rate | sampleRate |
| 0x0C | u32 | composer_id | composerID |
| 0x10 | u32 | file_size | fileSize |
| 0x14 | u32 | (로컬 MasterSongID) | masterContentId |
| 0x18 | u32 | master_db_id | masterDbId |
| 0x1C | u32 | artwork_id | imageID |
| 0x20·0x24·0x28·0x2C | u32 | key_id·original_artist_id·label_id·remixer_id | keyID·originalArtistID·labelID·remixerID |
| 0x30·0x34·0x38 | u32 | bitrate·track_number·tempo(BPM × 100) | bitrate·trackNo·bpmx100 |
| 0x3C·0x40·0x44·0x48 | u32 | genre_id·album_id·artist_id·id | genreID·albumID·artistID·id |
| 0x4C·0x4E·0x50·0x52·0x54 | u16 | disc_number·play_count·year·sample_depth·duration(초) | discNo·djPlayCount·releaseYear·bitDepth·lengthSeconds |
| 0x56 | u16 | u5 | `trackRowExtras` |
| 0x58·0x59 | u8 | color_id·rating | colorID·rating |
| 0x5A | u16 | file_type | fileType |
| 0x5C | u16 | u7 | `trackRowExtras` |
| 0x5E | u16 × 21 | 문자열 오프셋(행 시작 기준) | |

- id 칸 0은 "없음"(nil)이다.
- play_count와 rating은 기기 칸(`deviceFields[.deviceLibrary]`)에도 넣는다.
- 문자열 21개는 아래와 같다.

| 번호 | 내용 | 모델 칸 |
|---|---|---|
| 0 | ISRC(특수형) | isrc |
| 1 | 작사가 | lyricist |
| 2·3·4 | 정보·분석·큐 갱신 횟수 | informationUpdateCount·analysisDataUpdateCount·cueUpdateCount |
| 5 | message | |
| 6 | kuvo_public("ON" → kuvoDeliver) | kuvoDeliver |
| 7 | autoload_hotcues("ON" → hotCueAutoLoad) | hotCueAutoLoad |
| 8·9 | 모름 | |
| 10 | dateCreated | |
| 11 | releaseDate | |
| 12 | mix_name | subtitle |
| 13 | 모름 | |
| 14 | 분석 파일 경로 | analysisDataPath |
| 15 | dateAdded | |
| 16 | comment | |
| 17 | title | |
| 18 | 모름 | |
| 19 | 파일 이름 | fileName |
| 20 | 파일 경로 | path |

- 뜻 모를 문자열 5, 8, 9, 13, 18의 값은 `UsbPdbTrackExtras`에 남긴다. 참·거짓 문자열 6, 7의 원래 값도 거기에 남긴다. 문자열 21개의 모양도 마찬가지다. 다시 쓸 때 비어 있지 않은 값이나 "ON"·''가 아닌 값을 잃지 않게 하기 위해서다.
- OneLibrary에만 있는 칸은 Device Library 리더의 기본값으로 둔다(§2.6). 예는 titleForSearch, lyricistArtistID, kuvoDeliveryComment다.

### 3.6 exportExt.pdb 표

| 번호 | 표 | 행 |
|---|---|---|
| 3 | tags | 아래 "tags 행" |
| 4 | tag_tracks | u32 0, u32 track_id, u32 tag_id, u32 3 |
| 7 | (My Tag property) | subtype 0x0700(60바이트): 0x18 u32 myTagMasterDBID, 0x1C u8 0x03, 0x1D–0x21 빈 문자열 오프셋 다섯 |
| 0·1·2·5·6·8 | (모름) | 산 행 수만 `unknownRows` |

**tags 행**

- subtype 0x0680은 아래 칸으로 이뤄진다.

| 오프셋 | 값 |
|---|---|
| 0x0C | u32 부모(분류면 0) |
| 0x10 | u32 부모 안 순서(0부터) |
| 0x14 | u32 id |
| 0x1B | u8 분류면 1 |
| 0x1C | u8 0x03 |
| 0x1D | u8 이름 오프셋(ASCII 0x1F, UTF-16 0x20) |
| 0x1E | u8 두 번째 문자열 오프셋 |

- 먼 모양 0x0684는 아티스트·앨범 먼 모양과 같은 규칙으로 읽는다. 0x1C u16 0x0003, 0x1E u16 이름 오프셋, 0x20 u16 두 번째 문자열 오프셋이다. [Deep Symmetry 분석 문서](https://djl-analysis.deepsymmetry.org/rekordbox-export-analysis/exports.html)의 tag rows와 rekordcrate가 같은 자리를 쓴다(#189).
- 이름 오프셋은 두 번째 오프셋보다 작아야 하고, 둘 다 0x22 이상이어야 한다. 아니면 그 행을 버린다.
- 읽은 행도 rekordbox로 확인하지 못한 모양이다. 그래서 구조 문제(`unconfirmedRowShape`)로 남겨 Device Library 편집을 막는다.

My Tag ID와 myTagMasterDBID는 u32라 Int32를 넘을 수 있다. 그래서 64비트로 담는다.

### 3.7 읽기가 견뎌야 할 것

rekordbox는 Device Library를 제자리에서 고친다. 읽기는 아래를 견딘다(`PdbReader`).

- **죽은 행:** 산 행은 presence 비트가 켜진 자리뿐이다. 죽은 행이 멀쩡한 복제일 수 있다. 같은 id가 두 벌 있는 경우다. 그래서 행 수를 짐작하지 않는다. 해석되는 죽은 행의 id는 `deadIDs`에 모은다. 지운 ID를 다시 쓰지 않게 하기 위해서다.
  - 해석되는 표는 tracks, artists, albums, genres, keys, labels, artwork, playlist_tree다.
- **flags 0x34:** 지운 행이 있는 쪽이다. 인덱스 쪽의 항목 목록도 쓰지 않는다.
- **index_shift:** 행 0x02의 index_shift는 산 행 순번이 아니라 자리 × 0x20이다. 해석에 쓰지 않는다.
- **패딩:** 행 사이 패딩 바이트는 보지 않는다.
- **파일 끝 너머 후보:** empty_candidate와 next_unused_page가 파일 끝 너머를 가리킬 수 있다. 사슬은 empty_candidate에서 끝난다.
- **flag10 ≠ 5:** 열린 채 뽑힌 USB다. 읽기는 멈추지 않고 보고서에 값을 남긴다.
- **멈추지 않는 구조 문제:** 아래 문제는 `PdbReadReport.issues`에 종류, 표, 쪽, 자리만 넣는다. 값은 넣지 않는다. 그 표는 읽은 데까지만 쓴다.
  - 쪽 번호 ≠ 위치
  - 파일 밖 쪽
  - 순환 사슬
  - 다른 표의 쪽
  - last_page에서 끝나지 않는 사슬
  - 힙 밖 행 오프셋
  - 산 행끼리 같은 자리
  - 산 행 수 ≠ presence 비트 수
  - 해석하지 못하는 산 행
  - 같은 id 산 행
  - 확인 안 된 행 모양. 예는 먼 모양 My Tag 행이다.
  - 없는 목록을 가리키는 산 목록 항목(`orphanEntry`). rekordbox는 목록을 지울 때 그 항목도 함께 죽인다.
- **먼 오프셋 모양:** 아티스트, 앨범, My Tag 행을 먼 모양으로 읽으면 `PdbReadReport.farShapeRows`에 표마다 수를 센다. 먼 모양의 subtype은 0x0064, 0x0084, 0x0684다.
  - 왕복 검사(§3.8)는 다시 쓴 파일의 수와 비교한다.
  - 쓴 뒤 검증(`PdbVerifier`)은 아티스트·앨범 밖의 먼 모양 행만 문제로 본다.
  - 옮기기(§8.4)는 아티스트·앨범 먼 모양 행을 막지 않는다. 먼 모양 My Tag 행은 구조 문제라 막는다.

`djc lab pdb-dump <파일> [--pages] [--rows <표>]`는 임시 폴더 아래 파일을 임시 사본으로 뜬다. 출력은 다음과 같다.

- 머리와 표 포인터
- 표마다 산 행/자리와 쪽 수
- `far_shape_rows <수>`
- 마지막 줄 `issues <수>`. 0이 아니면 종류별 수와 쪽 번호를 찍는다.

`--rows`는 자리, 오프셋, 산/죽음, index_shift, 문자열 모양, 길이만 찍는다.

`djc lab usb-diff`는 `--onelibrary`나 `--device-library`로 한 형식만 비교한다. 기본은 두 형식을 합친 모델끼리 비교한다. 각 쪽의 형식 불일치 종류와 수를 먼저 찍는다.

### 3.8 쓰기(`PdbWriter`)

근거: rekordbox 7.2.18 골든(2026-09-26 내보내기)에서 칸 값만 읽어 아래 규칙으로 쪽을 다시 만들었다. 다시 만든 쪽은 원본과 바이트가 같았다(`djc lab pdb-verify`).

제자리 수정 이력이 있는 쪽은 비교에서 뺐다.

- 지운 행이 있는 데이터 쪽
- 0x20·0x22가 한 번에 씀이나 덧붙임 모양이 아닌 데이터 쪽
- 지운 쪽 목록이 있는 인덱스 쪽

코드는 다음과 같다.

- `PdbWriter`: 두 파일, 쓴 모델, 규칙
- `PdbLayout`: 쪽 배치, 순번, 쪽 바이트
- `PdbRowEncoder`: 행, `PdbRowSize`
- `PdbRoundTrip`: 왕복 검사
- `PdbPageCheck`: 쪽 다시 만들기 비교

입력과 막힘:

- 입력은 모델의 Device Library 투영(`projected(to: .deviceLibrary)`)이다. 두 형식을 합친 모델이어도 된다. OneLibrary에만 있는 칸·곡·목록은 쓰지 않는다.
- 아래 경우는 쓰지 않고 막는다. 막으면 `UsbError.writeRefused`의 code를 낸다.
  - 곡 0개: `pdbNoTracks`
  - 기기 기록이나 모르는 표의 행: `carriedDeviceRows`
  - My Tag 연결: `myTagLinks`. v1의 tag_tracks는 0행이다.
  - file_type과 파일 이름 확장자가 다른 곡: `pdbFileTypeMismatch`
  - 가까운 모양에 들어가지 않는 My Tag 행: `pdbFarOffsetRows`. 할당 크기가 255를 넘는 행이다.
  - 빈 쪽에도 들어가지 않는 행: `pdbRowTooLarge`
  - 칸 크기를 넘는 값: `pdbValueOutOfRange.<칸>`
  - ASCII가 아닌 ISRC: `pdbISRCNotASCII`
  - 편집 모드에서 새 순번이 u32를 넘는 경우: `pdbSequenceOverflow`
- 이 막힘들은 규칙이 없는 것이다. 문구는 일반 문구다. 문구는 "USB에 쓰지 않았습니다. 조건을 확인한 뒤 다시 시도하세요"다.
- 쓰는 쪽은 같은 조건을 계획 단계에서 먼저 막는다. 쓰는 쪽은 USB 내보내기와 고치기이고, 막는 코드는 `PdbRowSize` 등이다. 그때는 할 일이 적힌 문구를 보여 준다. 작성기의 막힘은 마지막 안전장치다.

**쪽 배치**

```
next = 1
표마다(type 오름차순): 인덱스 쪽 = next, 빈 후보 = next + 1, next += 2     // 인덱스 2t+1, 후보 2t+2
넣는 순서의 표마다(행이 있을 때만):
    cur = 후보; 후보 = next; next += 1          // 후보를 데이터 쪽으로 쓰는 순간 새 후보
    행마다: 들어가지 않으면 cur를 닫고 cur = 후보; 후보 = next; next += 1
next_unused = next
표 포인터 = (type, 후보, 인덱스 쪽, 마지막 데이터 쪽 또는 인덱스 쪽)
파일 길이 = 후보가 아닌 쪽 중 가장 큰 번호 + 1쪽. 그 안의 후보는 0으로 채운 쪽, 그보다 큰 후보는 파일 끝 너머
```

- 들어가는지는 `used + L + dir(nro + 1) ≤ 4056`으로 본다. `dir(n) = 2n + 4⌈n/16⌉`이다. 12바이트 행은 쪽당 284개가 들어간다.
- 넣는 순서는 export 19, 6, 16, 17, 18, 7, 2, 1, 3, 4, 5, 0, 13, 8, 11, 12, exportExt 7, 3, 4다. export 9, 10, 14, 15는 늘 빈 표다.
- 사슬은 아래와 같다.
  - 인덱스 쪽 next = 첫 데이터 쪽(없으면 후보)
  - 데이터 쪽 next = 다음 데이터 쪽
  - 마지막 쪽 next = 후보
- 빈 표도 인덱스 쪽과 후보가 있다. 인덱스 쪽 본문 0x2C는 0x03FFFFFF다.
- 쪽 안 행 순서는 id 순이다.
  - category와 sort는 (순서, id) 순이다.
  - columns는 id 순이다.
  - My Tag는 분류를 순서대로 놓고, 분류마다 그 태그를 순서대로 놓는다.
  - 목록 항목은 목록 id 순이고, 목록 안 순서대로 entry_index를 1부터 붙인다.
- rekordbox는 곡마다 표를 번갈아 넣어서 뒤쪽 쪽 번호가 생긴다. 작성기는 이 번호를 맞추지 않는다. 기기가 사슬을 따라간다고 본다[추정].

**순번과 쪽 머리**

| 쪽 | 순번 | 모양 |
|---|---|---|
| 모든 인덱스 쪽 | 1 | 인덱스(§3.2, 지운 쪽 목록 없음) |
| export 6·16·17·18 데이터 | 2부터 | 한 번에 씀 |
| 그 밖의 export 데이터 | 이어서 쪽을 닫는 순서대로 | 한 행씩 덧붙임 |
| export 19 데이터 | 마지막 | 행 하나 |
| exportExt 7 / 3 / 4 데이터 | 1 / 2부터 / 그 뒤 | 7·3 한 번에 씀, 4 덧붙임 |
| 파일 머리 0x14 | 가장 큰 쪽 순번 + 1 | 0x10 = 5 |

- 한 번에 씀: 0x20 = 자리 수, 0x22 = 0, tx 비트 = presence 비트.
- 덧붙임: 0x20 = 1, 0x22 = 마지막 자리, tx 비트는 마지막 자리만.
- 행 하나인 쪽은 두 모양이 같다.
- 데이터 쪽의 flags는 0x24다. 0x24·0x26은 0이다(0x1FFF를 쓰지 않는다).
- 데이터 쪽의 free는 `4096 − 0x28 − used − dir(nro)`다. used는 행 할당 크기의 합이다.
- 힙과 행 인덱스 사이는 0이다.
- 행 0x02 index_shift는 자리 × 0x20이다(subtype이 있는 행).
- **편집 모드**(`PdbWriteMode.edit`): 모든 쪽 순번은 옛 파일 머리 순번에 위의 상대 순번을 더한 값이다. 인덱스 쪽도 같다. 머리는 늘 옛 머리보다 크다. 옛 머리 순번은 USB에서 읽은 값이다. 새 머리 순번이 u32를 넘으면 쓰지 않고 막는다(`pdbSequenceOverflow`). 왕복 검사에서는 문제로 남는다.

**행**

- 할당 크기 L은 `PdbRowSize`가 정한다.
  - 단순 행은 align4(마지막 문자열 끝)이다. 단순 행은 genre, label, key, color, artwork, columns, playlist_tree다.
  - 고정 행은 playlist_entries 12, category 8, sort 8, 표 19 40이다.
  - 오프셋 문자열 행은 align4 고정 칸 + Σ align4 문자열 길이 + 4다. 고정 칸과 문자열 길이에 각각 align4를 적용한다.
  - 고정 칸은 트랙 0x88, 아티스트 0x0A, 앨범 0x16, 태그 0x1F, exportExt 표 7 0x22다.
  - 아티스트·앨범 먼 모양도 같은 공식이다.
  - 트랙 행은 224바이트 이상이다.
  - 문자열 뒤 할당 끝까지는 0이다.
- 트랙 행 상수는 0x04 bitmask 0x000C0700, 0x56 0x0029, 0x5C 3이다.
- 평점과 재생 수는 `deviceFields[.deviceLibrary]` 값을 쓴다. 없으면 모델 칸을 쓴다.
- 뜻 모를 문자열 5, 8, 9, 13, 18은 빈 값이다. 6·7은 켜짐이면 "ON"이고 아니면 빈 값이다. 빈 값은 추정이다.
- 아티스트 0x08, 앨범 0x14, 태그 0x1C는 0x03이다. 앨범 0x04·0x10은 0이다.
- 분류 태그는 0x0C(부모) = 0, 0x18 = 0x01000000이다. 태그의 두 번째 문자열은 빈 값이다(오프셋 = 이름 끝).
- keys는 모델 키만 모델 id로 쓴다. 고정 24개 표를 쓰지 않는다. colors는 모델 색을 쓴다.
- category의 Disable이 없으면 보임 0, 숨김 1이다. sort의 Disable이 없으면 보조 칸 2, 숨김 1, 보임 0이다.
- 표 19는 늘 한 행이다.
  - 곡 수 = 산 트랙 행 수
  - 날짜 = 모델 `pdbDate`(고칠 때 보존). 없으면 OneLibrary `createdDate`(내보낸 날). 그것도 없으면 오늘.
  - 버전 "1000"
  - 두 번째 문자열 빈 값
- exportExt 표 7은 myTagMasterDBID와 빈 문자열 다섯(오프셋 0x22–0x26)이다.
- 문자열 경계는 다음과 같다.
  - 126자까지 순수 ASCII는 짧은 ASCII다. 127자 이상 순수 ASCII는 긴 ASCII(0x40)다.
  - 긴 ASCII를 본 칸에는 규칙을 붙이지 않는다. 그 칸은 트랙 행 문자열, 아티스트 이름, 앨범 이름이다.
  - 그 밖의 칸에는 `pdbLongAscii`를 붙인다. 판정은 `UsbTrackRules.pdbStringRules`와 같다. 계획기는 재생 목록, 장르, 키, 레이블 이름에만 쓴다.
  - UTF-16과 긴 ASCII는 행 기준 4바이트 경계로 앞을 0으로 채운다. 짧은 ASCII는 앞 문자열 바로 뒤에 붙인다.
- 트랙 행 문자열에서 나온 규칙은 `PdbFiles.rulesByTrack`(content id별)에 모은다. 모든 규칙은 `PdbFiles.rules`에 모은다. 쓰는 쪽은 `rules`를 변경 묶음 `requiredRules`에 합친다.

**먼 모양·긴 ASCII**

근거는 rekordbox 7.2.x 경계 실험(2026-10-08)이다. 이어서 7.2.19 실험 X1(2026-10-08)을 했다.

방법:

- 사용자가 rekordbox에서 한 곡의 아티스트·앨범을 시험 문자열로 차례로 바꿨다.
- 바꿀 때마다 USB 동기화를 하고, 단계마다 USB의 pdb를 떠서 행을 읽었다.
- 끝에 원래 이름으로 되돌렸다.
- 첫 실험은 '가' × 116, 117, 119, 120을 썼다. 'A' × 126, 127, 236, 244, 250도 썼다.
- X1은 그 사이를 가르려고 썼다. '가' × 100, 108, 109, 110, 112, 113, 114, 115를 썼다. 'A' × 200, 220, 226, 228, 229, 231도 썼다.

할당 크기는 공식 값이다. 새로 붙인 행은 자리 사이 거리도 같았다. 쪽이 차서 지운 자리를 제자리에서 다시 쓴 행은 원래 자리 크기를 썼다.

| 이름 | 문자열 모양·바이트 | 아티스트 행(이름 끝) | 앨범 행(이름 끝) |
|---|---|---|---|
| 'A' × 126 | 짧은 ASCII 127 | 가까운, 할당 144(137) | 가까운, 할당 156(149) |
| 'A' × 127 | 긴 ASCII 131 | 가까운(이름 @0x0C), 할당 148(143) | 가까운(이름 @0x18), 할당 160(155) |
| '가' × 100, 'A' × 200 | UTF-16·긴 ASCII 204 | 가까운, 할당 220(216) | 가까운, 할당 232(228) |
| '가' × 108·109 | UTF-16 220·222 | 가까운, 할당 236·240(232·234) | 가까운, 할당 248·252(244·246) |
| '가' × 110, 'A' × 220 | UTF-16·긴 ASCII 224 | 가까운, 할당 240(236) | **먼**, 할당 252(248) |
| '가' × 112–115, 'A' × 226–231 | 228–235 | 가까운, 할당 244–252(240–247) | 먼, 할당 256–264(252–259) |
| '가' × 116 | UTF-16 236 | **먼**, 할당 252(248) | 먼, 할당 264(260) |
| '가' × 117·119·120 | UTF-16 238·242·244 | 먼, 할당 256·260·260 | 먼, 할당 268·272·272 |
| 'A' × 236·244·250 | 긴 ASCII 240·248·254 | 먼, 할당 256·264·272 | 먼, 할당 268·276·284 |

- 먼 모양 행은 가까운 모양의 u8 오프셋 칸을 0으로 둔다. 이 칸은 아티스트 0x09, 앨범 0x15다. 그 뒤 u16 오프셋에 이름 자리를 적는다. 오프셋 칸은 0x0A와 0x16이고, 이름 자리는 0x0C와 0x18이다. 할당 크기 공식은 가까운 모양과 같다.
- 모양은 `PdbRowSize.isFarShape`가 고른다. 기준은 **이름 끝**이다. 이름 끝은 가까운 모양으로 썼을 때 이름 자리에 문자열 바이트(머리 포함)를 더한 값이다. 이름 끝이 248 이상이면 먼 모양이다.
  - 아티스트: 이름 끝 247이 가까운 모양이다. 'A' × 231이 이 경우다. 이름 끝 248이 먼 모양이다. '가' × 116이 이 경우다.
  - 앨범: 이름 끝 246이 가까운 모양이다. '가' × 109가 이 경우다. 이름 끝 248이 먼 모양이다. '가' × 110과 'A' × 220이 이 경우다.
  - 할당 크기는 기준이 아니다. 'A' × 231과 '가' × 116 아티스트는 할당이 똑같이 252인데 모양이 달랐다.
  - 문자열 바이트로 말하면 아티스트 236, 앨범 224부터 먼 모양이다.
- 실험이 보지 못한 것은 앨범 이름 끝 247 하나뿐이다. 긴 ASCII 219자, 문자열 223바이트다. 같은 기준(가까운 모양)으로 쓰되 `pdbFarOffsetRows`를 붙인다(`PdbRowSize.nameShapeConfirmed`).
- 제자리에서 다시 쓴 행은 다른 모양이 남긴 바이트를 지우지 않았다. 예는 두 가지다. 먼 모양 자리에 쓴 가까운 아티스트 행의 0x0A–0x0B와, 가까운 모양 자리에 쓴 먼 앨범 행의 0x15다. 읽기는 이 칸을 쓰지 않으므로 영향이 없다. 작성기는 늘 새로 쓰므로 이 칸이 0이다.
- 다시 만들기 확인은 X1과 첫 실험 단계, 실제 USB 사본으로 했다. pdb 40개의 아티스트·앨범 산 행과 죽은 행을 모두 봤다. 고정 칸과 이름까지 이 규칙으로 다시 만든 바이트와 같았다. 다른 것은 제자리 고쳐 쓰기의 남은 바이트와 더 큰 자리뿐이었다. 모양이 다른 행은 0이었다.
- My Tag(X1): 시험 My Tag 하나를 시험 곡에 붙였다. 이름을 바꿔 가며 동기화했다. 이름은 '가' × 60, 100, 110, 116, 120과 'A' × 127, 236이다.
  - 단계마다 USB의 `export.pdb`·`exportExt.pdb`·`exportLibrary.db`(`-wal` 포함)가 하나도 바뀌지 않았다. 바뀐 것은 `playlists3*.sync`뿐이다.
  - 그래서 My Tag 행의 먼 모양(0x0684)과 긴 ASCII는 여전히 보지 못했다.
  - 가까운 모양에 안 들어가는 My Tag 행은 계속 막는다.
  - 가까운 모양에 들어가는 My Tag 이름의 긴 ASCII(127자 이상)는 실험으로 보지 못한 모양이다. 그래도 막지 않고 0x40으로 쓰며 `pdbLongAscii` 알림을 붙인다.
  - 확인하려면 동기화가 아니라 다른 실험이 필요하다. 그 태그가 든 곡을 새로 내보내거나, rekordbox가 exportExt.pdb를 다시 쓰게 해야 한다.
- 확인: `djc lab pdb-verify`로 먼 모양 아티스트 행이 든 쪽이 "같음"이 됐다. 전에는 "행을 다시 만들지 못함"이었다. 실험 단계와 실제 USB 사본 모두 왕복 검사 문제가 0이었다.

**쓴 모델과 확인**

`PdbFiles.written`은 입력 투영에 작성기가 정하는 칸을 채운 모델이다. 채우는 칸은 다음과 같다.

- 트랙 행 관찰값
- 표 19의 곡 수, 날짜, 버전, 두 번째 문자열
- 기기 칸의 평점과 재생 수
- Disable
- 폴더 여부
- 0인 참조(→ nil)
- 사람이 읽는 문자열(NFC, §3.4)

Device Library 경로가 없는 아트워크는 뺀다.

쓴 두 파일을 다시 읽은 모델은 이 모델과 `UsbLibraryDiff`(formats: [.deviceLibrary]) 차이가 0이어야 한다. Device Library에서 읽은 모델을 쓰면 입력의 투영과 같다.

**왕복 검사**(`PdbRoundTrip.check`)

고쳐 쓰기 전에 읽기 → 모델 → 쓰기(편집 모드) → 다시 읽기를 한다. 알려진 표의 칸이 모두 같고 트랙 상수 칸이 관찰값이면 통과한다(빈 배열).

아래는 문제로 남긴다.

- 원본의 구조 문제. 먼 모양 My Tag 행도 포함한다.
- 작성기가 막는 행
- 작성기가 고르지 않는 문자열 모양. 트랙 행 문자열 모양이 다른 경우다.
- 표마다 먼 모양 행 수가 다시 쓴 파일과 다른 경우(`far_shape_rows <표> <원본> -> <다시 씀>`)
- 트랙 문자열 6, 7에 "ON"도 ''도 아닌 값이 든 곡. 6은 kuvo 공개이고 7은 핫큐 자동 불러오기다.

트랙 문자열 6·7은 "ON"만 참으로 읽고, 작성기는 "ON"·''만 쓴다. 그래서 읽기가 원래 값을 `UsbPdbTrackExtras.flagStrings`에 남긴다. 모델은 같아도 다시 쓰면 바뀌기 때문에 문제로 본다.

지운 행 id는 비교하지 않는다. 다시 쓰면 사라지는 것이 정상이다. 지운 ID를 다시 쓰지 않게 지키는 것은 편집 쪽 몫이다.

NFC로 바꿔 쓰는 문자열(§3.4)은 기대값을 NFC 철자 쪽으로 옮겨 비교한다(`PdbRoundTrip.expectingNFC`).

- 트랙 문자열 모양: 원본 모양이 원래 철자로 작성기가 고를 모양과 같을 때만 NFC 철자의 모양으로 옮긴다. 예: U+212A KELVIN SIGN은 NFC가 ASCII "K"라 UTF-16이 짧은 ASCII가 된다.
- 아티스트·앨범 먼 모양 행 수: 원래 철자와 NFC 철자로 고른 모양이 다른 행만큼 옮긴다. 풀어 쓴 한글은 NFC가 짧아 먼 모양이 가까운 모양이 될 수 있다.

**v1에 없는 것**

- My Tag 먼 오프셋 모양 행(0x0684)
- 기기 기록 표(11·12)의 행
- My Tag 연결(tag_tracks)
- 모르는 표의 행
- 제자리 수정. 지운 행과 지운 쪽 목록이 해당한다.

**실험 명령**

- `djc lab pdb-verify <USB 폴더>`는 두 pdb를 사본으로 떠서 쪽마다 칸 값만으로 다시 만들고 바이트를 비교한다. 쪽 번호, next, 순번, 행 자리 순서는 원본 값을 쓴다.
  - 작성기가 NFC로 바꿔 쓰는 문자열이 든 데이터 쪽은 뺀다. rekordbox와 일부러 다르기 때문이다. §3.4의 "NFC로 바꿔 쓰는 문자열이 든 데이터 쪽"을 본다.
  - 제자리 수정 이력이 있는 쪽도 뺀다. 지운 행이 있는 데이터 쪽과 지운 쪽 목록이 있는 인덱스 쪽이다.
  - 지운 행은 없지만 0x20·0x22가 그 표의 쓰기 모양과 다른 데이터 쪽도 뺀다. 쓰기 모양은 세 가지다. 한 번에 씀은 자리 수와 0이다. 덧붙임은 1과 마지막 자리다. 행 하나면 1과 0이다.
    - rekordbox가 제자리에서 고친 행은 할당 크기가 이 규칙보다 클 수 있다. 읽기는 문제없다.
  - 다른 쪽은 쪽 번호, 처음 다른 오프셋, 행마다 할당 크기만 찍는다.
  - 행을 해석하지 못하면 쪽을 만들지 않고 "행을 다시 만들지 못함"과 이유를 찍는다. 다시 만든 행이 원본보다 커서 한 쪽에 들어가지 않을 때도 같다. 예는 작성기가 막는 먼 모양 My Tag 행과 제자리에서 줄인 행이다. 들어가지 않을 때는 행마다 크기도 찍는다.
- `djc lab pdb-export --db <사본> --share <share> (--playlist <ID> | --tracks <ID,…>) --out <폴더> [--snapshot-time <ISO 8601>]`는 로컬 사본으로 두 형식 모델을 만든다. `<폴더>/PIONEER/rekordbox/export.pdb`·`exportExt.pdb`만 쓰고, 다시 읽기 차이와 왕복 문제 수를 찍는다. 골든과는 `djc lab usb-diff --device-library`로 비교한다.
## 4. ANLZ 변환

`UsbAnlzTransform`은 로컬 분석 파일과 `djmdCue`로 USB 분석 파일 세 개를 만든다. 로컬 분석 파일은 `share` 아래에 있다. 경로는 `djmdContent.AnalysisDataPath`에서 확장자만 `.DAT`·`.EXT`·`.2EX`로 바꾼 것이다. 로컬 파일 이름은 `ANLZ0000`이 아닐 수 있으므로 가정하지 않는다.

근거는 모두 rekordbox 7.2.18 골든 관찰이다. 골든의 곡을 로컬 곡과 짝지어 다시 만들었다. 스냅샷을 뜬 뒤 로컬 분석 파일이 바뀐 곡을 빼면 세 파일이 바이트까지 같았다(§4.10). 모든 칸은 빅엔디언이다.

### 4.1 파일 머리

- `PMAI`
- len_header 28
- len_file: 파일 전체 길이. 태그를 바꾼 뒤 다시 적는다.
- 나머지 16바이트: 로컬 그대로.

### 4.2 태그 처리

태그 순서는 로컬 순서 그대로 둔다. 태그 목록을 차례로 보고 새 목록을 만든다. 같은 이름 태그는 PCOB 둘과 PCO2 둘이다. 이들은 태그 0x0C의 목록 종류로 가린다. 목록 종류 1은 핫큐, 0은 메모리 큐다.

골든에서 본 태그 순서는 다음과 같다.

- `.DAT`: `PPTH PVBR PQTZ PWAV PWV2 PCOB(핫) PCOB(메모리)`
- `.EXT`: `PPTH PWV3 PCOB(핫) PCOB(메모리) PCO2(핫) PCO2(메모리) PQT2 PWV5 PWV4 [PVB2] [PSSI]`
- `.2EX`: `PPTH PWV7 PWV6 PWVC PVDI`

| 태그 | USB |
|---|---|
| 모든 파일 `PPTH` | `/Contents/…` 경로로 새로(§4.3) |
| `PVBR` `PQTZ` `PWAV` `PWV2` `PWV3` `PWV4` `PWV5` `PWV6` `PWV7` `PWVC` `PVB2`, 비지 않은 `PQT2`, 모르는 태그 | 바이트 그대로 |
| `.DAT` `PCOB` 둘, `.EXT` `PCOB` 둘·`PCO2` 둘 | `djmdCue`로 새로(§4.4–4.6). 로컬 share의 큐 태그는 비어 있다 |
| `.EXT` `PSSI` | 평문(mood 1–3)이면 마스크(§4.7). 이미 마스크된 모양이면 빼고 경고 `maskedLocalPSSIDropped` |
| `.2EX` `PVDI` | 평문이면 마스크(§4.8). 이미 마스크된 모양이면 그대로 두고 경고. 모르는 모양이면 그 자리에 빈 `PVDI`를 두고 경고. 없으면 파일 끝에 빈 `PVDI` |
| `.EXT` 빈 `PQT2` | 뺀다(§4.9) |
| `.3EX` | 만들지 않는다 |

로컬 `.2EX`가 없으면 USB `.2EX`도 만들지 않는다. 이 경우를 막는 것은 계획 몫이다. 경고는 `UsbAnlzWarning`의 코드로 남긴다. 계획 보고에서 이 코드를 문구로 바꾼다.

### 4.3 경로 태그(PPTH)

| 오프셋 | 칸 | 값 |
|---|---|---|
| 0x00 | `PPTH` | |
| 0x04 | len_header u32 | 0x10 |
| 0x08 | len_tag u32 | 0x10 + len_path |
| 0x0C | len_path u32 | 경로 바이트 수. UTF-16BE이고 끝 NUL 2바이트를 포함한다 |
| 0x10 | 경로 | `/Contents/{Artist}/{Album}/{File}` UTF-16BE + `00 00` |

로컬 경로는 `?/{파일 이름}`이다. USB에서는 세 파일에 같은 경로를 쓴다. 이 경로는 Device Library `file_path`·OneLibrary `path`와 글자까지 같다(NFC). 코드는 `AnlzPathTag`다.

### 4.4 큐 배치·순서

입력은 `djmdCue`에서 그 곡의 `rb_local_deleted = 0`인 행이다. 읽기는 `UsbCueSource`, 배치는 `UsbCuePlacement`가 맡는다.

| 태그 | 넣는 큐 |
|---|---|
| `.DAT` PCOB(핫, 종류 1) | 핫큐 A–C(Kind 1·2·3) |
| `.DAT` PCOB(메모리, 종류 0) | 메모리 큐 전부(Kind 0) |
| `.EXT` PCOB(핫) | 핫큐 D–H(Kind 5–9) |
| `.EXT` PCOB(메모리) | 늘 비움 |
| `.EXT` PCO2(핫) | 핫큐 A–H 전부 |
| `.EXT` PCO2(메모리) | 메모리 큐 전부 |

- 핫큐 번호는 Kind < 4면 Kind, 5–9면 Kind − 1이다(A=1 … H=8). Kind 4는 어느 태그에도 넣지 않는다. 대신 경고 `cueKindDropped`를 낸다.
- 목록마다 `created_at` 내림차순으로 늘어놓는다. 같으면 `InMsec` 내림차순으로 한다.
- `created_at`은 시각으로 풀어 비교한다. 형식은 `YYYY-MM-DD HH:MM:SS.fff +00:00`이고, 밀리초·시간대를 뺀 형식도 푼다. 하나라도 풀지 못하면 그 목록은 글자로 비교한다. 이때 경고 `cueCreatedAtUnparsed`를 낸다.
- 이 순서는 골든 전 곡의 큐 태그에서 맞았다. 행 순서(rowid) 내림차순 규칙과는 골든으로 가를 수 없었다.

### 4.5 PCOB·PCPT

PCOB 머리는 24바이트다.

| 오프셋 | 값 |
|---|---|
| 0x00 | `PCOB` |
| 0x04 | len_header 0x18 |
| 0x08 | len_tag = 24 + 56n |
| 0x0C | 목록 종류 u32 |
| 0x10 | u16 0 |
| 0x12 | 항목 수 n u16 |
| 0x14 | u32. 핫은 `0xFFFFFFFF`, 메모리는 n − 1이고 n = 0이면 `0xFFFFFFFF` |

빈 PCOB는 로컬 새 곡의 빈 태그와 같다.

| 오프셋 | 칸 | 값 |
|---|---|---|
| 0x00 | `PCPT` | |
| 0x04 | len_header u32 | 0x1C |
| 0x08 | len_entry u32 | 0x38 |
| 0x0C | hot_cue u32 | 메모리 0, 핫 1–8 |
| 0x10 | status u32 | 0. 활성 루프도 0으로 쓴다. 확인 안 된 모양은 `cueVariant` |
| 0x14 | u32 | `0x00010000` |
| 0x18 | 앞 항목 u16 | 메모리 i − 1(첫 항목 `0xFFFF`), 핫 `0xFFFF` |
| 0x1A | 뒤 항목 u16 | 메모리 i + 1(끝 항목 `0xFFFF`), 핫 `0xFFFF` |
| 0x1C | type u8 | 1 큐, 2 루프(OutMsec > InMsec) |
| 0x1D | u8 | 0 |
| 0x1E | u16 | `0x03E8` |
| 0x20 | u32 | InMsec |
| 0x24 | u32 | 루프면 OutMsec, 아니면 `0xFFFFFFFF` |
| 0x28–0x37 | 16바이트 | 0 |

### 4.6 PCO2·PCP2

PCO2 머리는 20바이트다.

| 오프셋 | 값 |
|---|---|
| 0x00 | `PCO2` |
| 0x04 | len_header 0x14 |
| 0x08 | len_tag |
| 0x0C | 목록 종류 u32 |
| 0x10 | 항목 수 u16 |
| 0x12 | u16 0 |

| 오프셋 | 칸 | 값 |
|---|---|---|
| 0x00 | `PCP2` | |
| 0x04 | len_header u32 | 0x10 |
| 0x08 | len_entry u32 | 0x58 + len_comment |
| 0x0C | hot_cue u32 | 메모리 0, 핫 1–8 |
| 0x10 | type u8 | 1 큐, 2 루프 |
| 0x11 | u8 | 0 |
| 0x12 | u16 | `0x03E8` |
| 0x14 | u32 | InMsec |
| 0x18 | u32 | 루프면 OutMsec, 아니면 `0xFFFFFFFF` |
| 0x1C | 색 id u8 | 골든은 모두 0. 아래 색 큐 설명을 본다 |
| 0x1D | u8 | 1 |
| 0x1E | u16 | 0 |
| 0x20 | u32 | 0 |
| 0x24 | u16 | 박 루프 분자 = `BeatLoopSize >> 16`(NULL은 0) |
| 0x26 | u16 | 박 루프 분모 = `BeatLoopSize & 0xFFFF` |
| 0x28 | len_comment u32 | 주석 UTF-16BE 바이트 + NUL 2. 주석이 NULL·빈 글자면 0 |
| 0x2C | 주석 | UTF-16BE + `00 00`(패딩 없음) |
| C = 0x2C + len_comment | 색 4바이트 | 핫큐 `00 1A FF 00`, 핫 루프 `00 FF 8C 00`, 메모리 `00 00 00 00` |
| C + 0x04 | u64 | In 프레임 시작. FLAC만, `InPointSeekInfo` 첫 값 |
| C + 0x0C | u64 | Out 프레임 시작. FLAC 루프만, `OutPointSeekInfo` 첫 값 |
| C + 0x14 | u64 | In 바이트 위치. FLAC만, 둘째 값 |
| C + 0x1C | u64 | Out 바이트 위치. FLAC 루프만, 둘째 값 |
| C + 0x24 | u32 | In 블록 크기. FLAC만, 셋째 값 |
| C + 0x28 | u32 | Out 블록 크기. FLAC 루프만, 셋째 값 |

색 큐는 핫 `ColorTableIndex`, 메모리 `Color`로 색 id를 쓴다. `Color`는 1–8이고 그 밖은 0이다. 이 모양은 확인하지 않았다(`cueVariant`).

SeekInfo는 `"a,b,c"` 글자다. `"0,0,0"`·NULL·빈 글자는 0으로 쓴다. 탐색 칸은 FLAC(`FileType` 5)만 채운다. M4A와 MP3 CBR(`InMpegFrame` 0)은 모두 0으로 확인했다. 그 밖의 형식은 VBR MP3, WAV, AIFF, ALAC 등이다. 이들은 0으로 쓰되 `cueSeekFields`로 표시한다.

### 4.7 PSSI 마스크

로컬 평문 PSSI는 바이트 18부터 끝까지 `b[i] ^= (마스크[(i − 18) % 19] + 항목 수) & 0xFF`로 마스크한다. 바이트 0–17은 그대로다. 항목 수는 u16 @0x10이다. 마스크 상수는 `AnlzMasks.pssiMask`다. 이것은 pyrekordbox(MIT)의 XOR 규칙이다. 골든으로 다시 확인했다.

평문인지는 mood(u16 @0x12)가 1–3인지로 가린다. 로컬에 이미 마스크된 PSSI가 있으면 USB에서 빼고 경고를 낸다.

### 4.8 PVDI 마스크

로컬 PVDI 머리는 24바이트다.

- `PVDI`
- len_header 0x18
- len_tag
- `00 00 04 00`
- `56 22 00 01`
- 본문 길이 u32 = len_tag − 24

USB에서는 바이트 12를 `0x00` → `0x80`으로 바꾼다. 바이트 24부터 끝까지는 `b[i] ^= 키[(i − 24) % 19]`를 한다. 키는 `AnlzMasks.pvdiKey`다. 이 키는 골든과 로컬의 같은 곡 PVDI를 XOR해 얻은 관찰값이다. 키는 길이와 관계없이 같다.

- 로컬에 PVDI가 없으면 `.2EX` 끝에 빈 PVDI를 붙인다. 빈 PVDI는 `AnlzMasks.emptyPVDI`다. 구성은 `PVDI`, 0x18, 0x18, `00 00 04 00`, `56 22 00 01`, 0이고 플래그는 0이다.
- 로컬 PVDI의 바이트 12가 이미 `0x80`이면 그대로 옮긴다. 이때 경고 `maskedLocalPVDIKept`를 낸다. 이것은 로컬에서 본 적 없는 모양이다.
- 24바이트보다 짧은 PVDI는 마스크를 씌울 수도 그대로 옮길 수도 없다. 바이트 12가 `0x00`·`0x80`이 아닌 PVDI도 같다.
- 이런 PVDI는 로컬에 PVDI가 없는 곡처럼 빈 PVDI를 둔다. 태그 순서를 지키려고 그 자리에 빈 PVDI를 둔다. 이때 경고 `unknownLocalPVDIDropped`를 낸다.

### 4.9 빈 PQT2

len_tag가 56이고 0x0C부터 `00 00 00 00 01 00 00 02`이며 나머지가 0인 `PQT2`는 USB에서 뺀다. 비지 않은 `PQT2`는 그대로 둔다.

### 4.10 확인 안 된 규칙

변환 결과의 규칙 표시(`UsbAnlzResult.rules`)는 곡 큐 모양 분류(`UsbCueRules.rules`) 그대로다(§9 `cueVariant`·`cueSeekFields`).

실험 명령은 둘이다. 모두 읽기만 한다.

- `djc lab usb-anlz-naming <USB 폴더>`는 export.pdb 곡마다 분석 폴더가 곡 경로의 rekordbox 해시 이름(§5)과 같은지 수만 센다.
- `djc lab usb-anlz-check`는 USB 폴더의 분석 파일을 로컬 분석 파일·큐로 다시 만들어 바이트를 비교한다.

`usb-anlz-check`는 곡을 다음 순서로 짝짓는다.

- USB `PPTH` 경로의 음원 파일 이름·크기를 로컬 `djmdContent`의 (`FileNameL`, `FileSize`)와 맞춘다.
- 맞는 로컬 곡이 하나가 아니면 짝 없음으로 센다.
- 라이브러리에 이름·크기가 같은 곡이 여럿이면 `--playlist <재생 목록 ID>`로 내보낸 재생 목록의 곡만 후보로 둔다.
- 스냅샷을 뜬 뒤 로컬 분석 파일이 바뀐 곡은 따로 센다.

## 5. 경로·음원·아트워크

`UsbExportPlanner`(DJCDomain, 입출력 없음)가 내보낼 곡을 USB 어디에, 어떤 ID로, 어떤 이름으로 둘지 정한다. 입력은 로컬 스냅샷 사본과 share에서 읽은 후보다(`UsbExportCandidates`). share 파일은 lstat만 한다. USB에 이미 있는 것은 `UsbExistingState`로만 받는다. 실험 명령 `djc lab usb-plan`이 같은 계획을 수치로만 찍는다.

### 음원 경로

경로는 `/Contents/<아티스트>/<앨범>/<파일 이름>`(NFC)이다. 아티스트는 곡의 Artist(`djmdContent.ArtistID`)이고 앨범 아티스트가 아니다. 앨범은 `djmdAlbum.Name`이다.

폴더 성분(아티스트·앨범)은 이 순서로 짓는다.

1. NFC로 맞춘다. 비었거나 공백·점뿐이면 `UnknownArtist`나 `UnknownAlbum`을 쓴다(`emptyArtistAlbum`).
2. `" * / : < > ? \ | ~`와 제어 문자(U+0000–U+001F, U+007F)를 `_`로 바꾼다. `" * / : > ? ~`는 확인했다. 나머지(`< \ |`·제어 문자)가 있었으면 `forbiddenCharacters`를 낸다.
3. 끝이 `.`이면 마지막 `.` 하나를 `_`로 바꾼다.
4. 앞 48 유니코드 스칼라로 자른다. 서로게이트를 가르지 않는다. 자른 성분에 보충 평면 글자가 있으면 `supplementaryCharacters`를 낸다.
5. 끝의 공백과 `.`을 모두 지운다.
6. 비면 Unknown 이름을 쓴다.
7. 앞 공백은 그대로 둔다. 대신 `leadingSpace`를 낸다.

파일 이름은 음원 경로(`FolderPath`)의 끝 성분에서 얻는다(NFC). 경로가 없으면 `FileNameL`을 쓴다. 폴더 성분과 같은 금지 글자 규칙을 쓴다.

- 48 스칼라 이하면 그대로 둔다. 줄기 끝의 공백·점도 그대로 둔다.
- 48 스칼라를 넘으면 확장자(마지막 `.` 뒤)를 남긴다. 줄기만 잘라 48에 맞춘다. 그 뒤 줄기 끝의 공백·점을 지운다(`fileNameTruncation`). 빈 줄기는 `_`로 쓴다.

OneLibrary와 Device Library의 파일 이름은 최종 경로의 끝 성분이다.

근거는 2026-10-08 빈 USB 실험이다(#233). 글자 바꾸기와 파일 이름 원본을 다룬다. rekordbox 7.2.x가 빈 USB에 내보낸 704곡의 USB 경로를 로컬 스냅샷 사본과 견주었다. 견준 것은 아티스트, 앨범, 파일 이름이다.

| 바뀐 글자 | 폴더 성분(아티스트·앨범, 서로 다른 이름 수) | 파일 이름 |
|---|---|---|
| `:` → `_` | 26 | 없음. macOS 파일 이름에 올 수 없다 |
| `/` → `_` | 27 | 없음 |
| `~` → `_` | 6 | 1 |
| `"` → `_` | 6 | 본 적 없음 |
| `*` → `_` | 4 | 본 적 없음 |
| `?` → `_` | 5 | 본 적 없음 |
| `>` → `_` | 2 | 본 적 없음 |
| 끝 `.` → `_` | 5 | 바꾸지 않음. 48 이하면 그대로 |

- 그대로 둔 글자는 다음과 같다.
  - ASCII `! # & ' ( ) + , - . = @ [ ] _`
  - 비ASCII 문장 부호, 기호, 공백, 서식 문자. 유니코드 범주는 Pd, Ps, Pe, Pf, Po, Sm, So, Zs, Cf다.
  - 가나·한자·라틴 확장 글자. 한글은 이 골든에 없었다.
- 자르기, 끝 공백·점 지우기, NFC도 위 순서 그대로 맞았다. 자르기는 48 스칼라이고 폴더 이름 48개와 파일 이름 3개였다.
- 이 골든에 없어 확인하지 못한 것은 `< \ |`, 제어 문자, 빈 아티스트, 빈 앨범이다.
- `FileNameL`이 실제 파일 이름과 다른 곡이 1개 있었다. 파일 이름을 바꾼 뒤 옛 값이 남은 것이다. rekordbox는 이 곡을 실제 파일 이름(`FolderPath` 끝 성분)으로 내보냈다.
- 같은 로컬 사본으로 `djc lab onelib-export`가 계획한 경로를 골든과 견주면 내보낸 508곡 중 505곡이 같다. 3곡은 아티스트 폴더의 대소문자만 다르다.
- rekordbox는 대소문자만 다른 아티스트 이름을 곡마다 제 철자로 적는다(FAT에서는 한 폴더). DJCrate는 먼저 지은 철자로 맞춘다(`pathCollision`, 아래).
- 고치기 전 DJCrate 내보내기는 500곡이 같았다. 5곡은 `~`와 파일 이름 원본 때문에 달랐다.
- 2026-10-09 전 DJCrate는 `~`를 그대로 두었다. 파일 이름도 `FileNameL`로 지었다. 그때 쓴 USB의 곡도 알아보도록 `UsbTrackMatch`는 옛 이름(`~` 그대로)과 `FileNameL` 이름도 받는다.

### 분석 뒤 바뀐 음원

로컬 음원 크기가 rekordbox가 적은 `djmdContent.FileSize`와 다른 곡이 있다. 분석 뒤 태그를 고쳐 파일이 바뀐 곡 등이다. 이런 곡도 막지 않는다. rekordbox처럼 내보낸다. 이것은 사용자 결정이다(2026-10-09, #233).

- 음원은 지금 파일을 그대로 복사한다. 복사 크기 검사는 계획 때 본 실제 크기(`UsbTrackPlan.audioSize`)로 한다. 계획 뒤에 파일이 또 바뀌면 복사가 실패해 쓰기를 되돌린다.
- 두 DB의 파일 크기 칸은 로컬 `FileSize` 그대로다. 칸은 OneLibrary `fileSize`와 pdb 트랙 0x10이다.
- 길이, 비트레이트, 샘플레이트, 비트 깊이도 로컬 DB 값이다. 분석 파일·큐도 로컬 것 그대로다. 모두 옛 파일 기준이다.
- 그래서 곡 규칙 `audioChangedSinceAnalysis`를 싣는다. 이것은 CDJ에서 확인하지 않은 항목이다.
- 불변식 ④는 음원 크기 = 파일 크기 칸이다. 이 쓰기가 이렇게 적은 곡은 ④에서 뺀다(`UsbInvariantVerifier.audioSizeFromDatabase`). 복사한 크기는 목표 지문이 본다.
- ④의 크기 문제 글은 형식 이름 없이 곡마다 한 번이다. 그래서 같은 곡의 이 차이를 새 문제로 보지 않는 경우가 있다. 이는 rekordbox가 만든 Device Library만 있는 USB에 OneLibrary를 더할 때다(§8.4).
- 파일이 없거나 읽을 수 없는 곡은 예전처럼 막는다(`audioMissing`).

근거는 2026-10-08 빈 USB 실험이다(#233). 값은 적지 않는다.

- rekordbox 7.2.x가 내보낸 704곡 중 196곡은 지금 로컬 음원 크기가 `FileSize`와 달랐다. 177곡은 더 컸다. 19곡은 더 작았다. 파일 형식 번호별로는 번호 1이 169곡, 번호 4가 23곡, 번호 6이 4곡이다. 번호 1은 MP3이고 번호 4와 6은 M4A다.
- 그 196곡 모두 두 DB의 파일 크기 칸이 로컬 `FileSize`와 같았다. 이 값은 실제 크기와 달랐다. 두 DB는 B3·B6 사본과 이어진 동기화 실험 G0 사본이다.
- 그 196곡의 길이, 비트레이트, 샘플레이트, 비트 깊이도 로컬 DB 값과 같았다.
- USB에 복사한 음원 크기는 196곡 모두 지금 로컬 파일 크기와 같았다. 이 크기는 G0·G10 파일 목록에서 읽었다. 나머지 508곡은 세 값이 모두 같다.
- 같은 선택을 2026-10-09 전 DJCrate로 계획하면 이 곡들을 `audioSizeMismatch`로 막아 508곡만 내보냈다.
- 지금 계획(`djc lab usb-plan`)은 704곡 모두 넣는다. 막힘은 0이고 `audioChangedSinceAnalysis`는 196곡이다.
- `djc lab onelib-export`와 `pdb-export`가 같은 704곡으로 두 DB를 만들었다. 두 DB의 파일 크기, 길이, 비트레이트, 샘플레이트, 비트 깊이 칸이 골든과 704곡 모두 같았다(2026-10-09).

### 같은 경로가 될 때

FAT는 대소문자와 NFC·NFD를 가리지 않는다. 그래서 이름은 `UsbLayout.collisionKey`로 비교한다.

- 폴더: 같은 부모 안에 키가 같은 폴더가 USB에 있거나 먼저 계획했으면 그 철자를 쓴다. 철자가 달랐으면 `pathCollision`을 낸다.
- 파일: 같은 폴더에 키가 같은 파일이 있으면 내용을 견준다.
  - USB의 그 파일이 같은 내용(크기와 SHA-256)이면 다시 쓰지 않는다(`reuse`). USB에 있는 철자로 가리킨다. 철자가 다르면 `pathCollision`을 낸다.
  - 내용이 다르면 줄기에 ` (2)`, ` (3)` … ` (99)`를 붙인다. 48 스칼라 안으로 줄기를 더 자른다. 이때 `pathCollision`을 낸다. 확장자가 길어 줄기를 남길 수 없으면 이름 전체를 줄기로 보고 자른다.
  - 99까지 다 차면 그 곡을 막는다.
- 같은 음원 파일을 가리키는 두 곡은 한 파일을 함께 쓴다.
- 긴 ASCII는 rekordbox 모양인 0x40으로 확인했다(§3.4). 대상은 경로, 파일 이름, 아티스트 이름, 앨범 이름이다. 그래서 곡 규칙 `pdbLongAscii`를 싣지 않는다.

### 분석 파일(ANLZ) 자리

- 새 곡의 `PIONEER/USBANLZ/` 아래 폴더 이름은 rekordbox 이름이다(`RekordboxAnalysisNaming`). 계산은 다음과 같다.
  - USB 음원 경로(`/Contents/…`, NFC)의 UTF-16 단위마다 `h = (h × 0x5BC9 + c) × 0x93B5 + c`를 계산한다. h는 u32이고 넘침은 버린다. 처음 값은 0이다.
  - `H = h mod 200003`을 `%08X`로 쓴다.
  - H의 0, 2, 6, 7, 9, 13, 16번 비트를 차례로 모은 7비트를 `P%03X`로 쓴다.
  - 이 계산 모양은 MIT 라이선스 rekordbox_converter를 참고했다(THIRD_PARTY_NOTICES.md).
- 근거 하나: rekordbox 7.2.x가 빈 USB와 기존 USB에 쓴 곡 708개의 pdb 분석 경로가 모두 이 계산과 같았다. 실험은 2026-10-08 빈 USB 실험과 동기화 실험들이다. 해시가 겹친 1곡은 `ANLZ0001`이다. 확인은 `djc lab usb-anlz-naming <USB 사본>`으로 했다.
- 근거 둘: DJCrate 고유 이름으로 내보낸 USB를 CDJ-2000NXS에 꽂았다. 고유 이름은 content ID로 만든 `P000/%08X`다. CDJ-2000NXS는 Device Library만 읽는 기기다.
  - 곡 정보와 소리는 나왔다. 그러나 불러오기 표시가 계속 깜빡였다. 파형과 큐는 없었다.
  - 기기는 그때 불러온 곡 5개의 빈 `.DAT`를 정확히 이 계산의 폴더에 만들었다. 이 `.DAT`는 큐가 0개이고 비트 그리드도 0개다(2026-10-09, #233).
  - 즉 그 기기는 pdb 문자열 14를 보지 않는다. 곡 경로에서 폴더를 다시 계산한다.
- 보충 평면 글자(서로게이트 둘)를 UTF-16 단위 둘로 넣는 것은 관찰하지 못했다. 그런 글자가 든 경로는 `supplementaryCharacters`를 싣는다.
- 시험용 고유 이름(`IdentifierAnalysisNaming`, `analysisFolderNaming`)은 계획기 시험에서 폴더를 ID로 고정할 때만 쓴다.
- USB 수정(곡 더하기)은 계획이 고른 폴더만 USB에서 읽어 자리를 보고 다시 계획한다. 경로와 ID는 그대로다. 파일 번호만 바뀔 수 있다. 모든 분석 파일을 열지 않는다.
- 기존 곡은 USB DB에 적힌 분석 경로를 그대로 쓴다.
- 폴더 안 파일 번호는 `ANLZ%04X`다.
  - 같은 곡 경로(PPTH)의 파일이 있으면 그 번호를 다시 쓴다.
  - 다른 곡의 파일이 있으면 가장 작은 빈 번호를 쓴다. 덮어쓰지 않는다.
  - 번호가 0이 아니면 `analysisSlotCollision`을 낸다.

### 아트워크

- 원본은 로컬 `ImagePath`(share 기준 `…/artwork.jpg`)와 같은 폴더에 있다. 바이트를 그대로 복사한다. `artwork.jpg`는 쓰지 않는다.
  - `artwork_s.jpg`(작은 그림)는 `a{id}.jpg`·`b{id}.jpg`로 간다.
  - `artwork_m.jpg`(중간)는 `a{id}_m.jpg`·`b{id}_m.jpg`로 간다.
  - Device Library는 `a`, OneLibrary는 `b` 경로를 가리킨다.
- image ID는 그림 있는 곡마다 새로 준다. 같은 그림도 합치지 않는다.
- 그림 없는 곡은 `artworkMissing`을 낸다. `ImagePath`는 있는데 그림 파일이 없으면 그림 없이 내보낸다. 이때 경고 `artworkMissingFile`을 낸다.
- rekordbox는 `ImagePath`가 있으면 그림 파일이 없어도 image 행을 만든다. 2026-10-08 빈 USB 실험(#233)의 704곡 중 40곡이 이 경우였다.
  - 그 40곡은 로컬 아트워크 폴더가 비어 있었다. `artwork.jpg`, `_s`, `_m`이 모두 없었다. 39곡은 음원에 내장 그림도 없었다.
  - rekordbox는 두 형식에 image 행을 만들었다. ID는 701개이고 1부터 빈틈이 없다. 그 40곡의 `a`·`b`·`_m` 파일은 USB에 쓰지 않았다. 가리키는 파일이 없는 행이다.
  - 내장 그림을 꺼내 쓰지도 않았다.
- DJCrate는 가리키는 파일이 없는 행을 쓰지 않는다(검증기 ④). 그 곡을 그림 없이 내보낸다. 그래서 같은 곡에서 DJCrate의 image ID는 rekordbox보다 작게 이어진다. 실제 그림은 같다.
- 폴더는 `PIONEER/Artwork/%05d/`이고 1부터 센다. 합은 a, b, a_m, b_m 네 파일의 크기다. 폴더 안 합이 1,000,000바이트를 넘게 되면 다음 폴더로 간다. 빈 폴더에는 크기와 상관없이 넣는다.
- [추정] 나누는 기준은 관찰에서 추정했다. 두 폴더 이상 쓰면 `artworkFolderSplit`을 낸다.

### ID

- 새 USB: content는 내보낸 순서대로 1..N이다. image는 그림 있는 곡 순서다. 재생 목록은 트리 순서다. 트리 순서는 깊이 우선이고 Seq 순이다. 막힌 곡·목록은 ID를 받지 않는다.
- 기존 USB: 다음 네 값 중 가장 큰 값의 다음 번호를 쓴다(`UsbIDAllocator`). 네 값은 산 행, 죽은 행, 기기 기록이 가리키는 ID, 저널 highWater다. 지운 ID는 다시 쓰지 않는다.
- 같은 부모 안 목록 순번은 기존 형제의 가장 큰 순번 다음이다. 형제가 없으면 0부터 센다(`playlistSiblingBase`).

### 용량

새 파일 용량은 다음을 모두 더한다.

- 클러스터 크기로 올려 센 음원. 새로 쓰는 것만 센다.
- 분석 파일 셋.
- 아트워크 넷.
- DB 어림. 파일마다 곡당 4 KiB + 64 KiB다.

임시 용량은 가장 큰 DB × 2다. 바꾸는 동안 옛 파일이 함께 있기 때문이다. 여유는 64 MiB와 가용 용량의 1% 중 큰 값이다.

### 막힘

곡 단위(`UsbBlock.scope = .track`)로 막힌 곡은 계획에서 빠진다. 그 곡이 든 목록에서도 빠진다.

| code | 조건 |
|---|---|
| `streaming` | 스트리밍 곡(`FolderPath`가 `/`로 시작하지 않음) |
| `audioMissing` | 음원 경로가 없거나 파일이 없음 |
| `fileTypeUnknown` | 음원 형식 번호를 모름 |
| `fileTooLarge` | 음원이 4 GiB 이상. FAT32 한계지만 exFAT에서도 똑같이 막는다(사용자 결정 2026-10-07, 어디서나 4GB 제한) |
| `analysisIncomplete` | 로컬 분석 파일 셋(`.DAT`·`.EXT`·`.2EX`)이 다 없음 |
| `analysisNewerThanSnapshot` | 로컬 분석 파일이 스냅샷 사본을 뜬 뒤에 바뀜 |
| `pathCollisionExhausted` | 같은 이름이 ` (99)`까지 다 참 |
| `namingUnavailable` | 분석 파일 폴더 이름을 지을 수 없음 |
| `smartPlaylist` | 스마트(인텔리전트) 재생 목록. 목록 단위이고, 그 곡은 다른 목록·곡 선택대로 간다 |
| `directoryEntryLimit` | 한 폴더 항목 수 어림이 60,000을 넘음(볼륨 단위). 어림은 짧은 이름 1 + 긴 이름 UTF-16 13단위마다 1 |
## 6. 설정 파일

USB `PIONEER/`의 `MYSETTING.DAT`, `MYSETTING2.DAT`, `DJMMYSETTING.DAT`는 기기 설정 파일이다. 대상 기기는 CDJ와 DJM이다. rekordbox 내보내기는 로컬 rekordbox 설정 폴더의 같은 이름 파일을 옮겨 쓴다. 근거는 rekordbox 7.2.18 내보내기(2026-09-26) 관찰이다. 칸 뜻의 근거 이슈는 #45.

모양(리틀엔디언):

| 위치 | 칸 | MYSETTING·MYSETTING2 | DJMMYSETTING | DEVSETTING |
|---|---|---|---|---|
| 0x00 | 문자열 길이 u32 | 0x60 | 0x60 | 0x60 |
| 0x04 | 제조사 32바이트 | `PIONEER` | `PioneerDJ` | `PIONEER DJ` |
| 0x24 | 소프트웨어 32바이트 | `rekordbox` | `rekordbox` | `rekordbox` |
| 0x44 | 버전 32바이트 | `0.001` | `1.000` | 앱 버전 |
| 0x64 | 본문 길이 u32 | 40 | 52 | 32 |
| 0x68 | 본문 | MYSETTING은 `78 56 34 12 02 00 00 00`로 시작, MYSETTING2는 머리 표지 없음 | `78 56 34 12 01 00 00 00 20 00 00 00`로 시작 | `78 56 34 12 01 00 00 00`로 시작 |
| 끝−4 | CRC u16 | CRC-16/XMODEM(다항식 0x1021, 초깃값 0) | 같음 | 같음 |
| 끝−2 | u16 | 0 | 0 | 0 |
| CRC 범위 | | 본문(0x68 ~ 끝−4) | **파일 처음** ~ 끝−4 | 본문 |
| 크기 | | 148 | 160 | 140 |

뜻을 아는 칸(1바이트):

| 파일 | 위치 | 칸 |
|---|---|---|
| MYSETTING | 0x72 | quantize |
| MYSETTING | 0x80 | quantize beat value(0x80 1박 … 0x83 1/8박) |
| MYSETTING | 0x81 | hot cue auto load |
| MYSETTING2 | 0x74 | beat jump beat value |
| MYSETTING2 | 0x6D–0x6E | 뜻 모르는 새 칸. rekordbox 7.2.18 내보내기는 `80 80`, 옛 버전이 쓴 로컬 파일은 `00 00` |
| DJMMYSETTING | 0x78 | beat FX quantize |

규칙:

- 읽기 검증(`DeviceSettingFile`): 다음 조건이 모두 맞아야 한다. 하나라도 어긋나면 그 파일은 만들지 않는다.
  - 문자열 길이 = 0x60.
  - 본문 길이 = 파일 크기 − 0x68 − 4.
  - 크기가 종류별 값.
  - 종류별 범위의 CRC 일치.
  - 끝 2바이트 0.
- 고치기(`DeviceSettingPatch`): 구조체로 다시 만들지 않는다. 모르는 칸이 0으로 지워지기 때문이다. 읽은 바이트를 그대로 옮긴다. 아는 칸 바이트와 CRC만 덮는다. 그 뒤 다시 읽어 검증한다.
- 내보내기용(`DeviceSettingPatch.forExport`): 머리 문자열, 길이, 본문은 그대로 둔다.
  - MYSETTING2의 0x6D와 0x6E가 둘 다 0이면 둘 다 0x80으로 채운다. 그리고 CRC를 다시 계산한다.
  - 둘 다 0x80이면 그대로 둔다.
  - 한쪽만 0이거나 다른 값이면 그 파일을 만들지 않는다. rekordbox가 쓴 적을 보지 못한 모양이기 때문이다.
  - 그 밖의 파일은 바이트가 바뀌지 않는다.
- 로컬 설정 폴더는 읽기만 한다. 세 파일 이름만 연다. 폴더를 훑지 않는다.
- 첫 판 USB 내보내기는 설정 파일을 만들지 않는다. 이 코드는 선택으로 켜는 설정 옮기기용이다. 기본은 꺼짐이다.
- `DEVSETTING.DAT`는 만들지 않는다. rekordbox 내보내기도 이 파일을 만들지 않는다. `djprofile.nxs`도 만들지 않는다.
- 실험 명령은 둘이다.
  - `djc lab setting-check <PIONEER 폴더>`는 크기, 길이, CRC를 확인한다.
  - `djc lab setting-export --local <로컬 설정 폴더> --out <빈 폴더>`는 내보내기 모양으로 옮긴다. 하나라도 만들지 못하면 실패로 끝난다.
  - USB 폴더와 출력 폴더는 임시 폴더 아래만 받는다.

## 7. 쓰기 절차

USB에 쓰는 길은 `UsbWriter.write` 하나다. 되돌리기와 회복도 같은 확인을 먼저 거친다. 되돌리기는 `restore`와 `djc usb-restore`다. 회복은 `recover`와 `djc usb-recover`다.

쓰기는 형식을 모른 채 변경 묶음을 파일 단위로 쓴다. 형식은 OneLibrary와 Device Library다. 변경 묶음 `UsbChangeSet`에는 DB 교체, 음원 복사, 준비 파일 쓰기, 지우기, 목표 지문이 든다. 형식별 막힘과 검증은 주입한다. 주입하는 것은 `UsbWriteInspector`와 `UsbWriteVerifier`다.

### 7.1 단계

| 단계 | 하는 일 | 실패하면 |
|---|---|---|
| A 막힘 확인 | 부작용 없음(7.2) | `writeRefused`. USB·백업·저널 그대로 |
| B 준비 | 준비 폴더 파일의 크기·해시가 계획과 같은지 본다. 저널은 `staged`다. 드라이 런은 저널을 `dryRun`으로 닫고 끝낸다 | 〃 |
| C 백업(Mac) | `usb-backups/<볼륨 UUID>/<시각>-<이름>/`에 모은다. 내용은 표 아래 "C 백업" 목록이다. 저널 `backedUp`이 디스크에 내려간 뒤에만 D로 간다 | 백업 폴더를 지우고 막음 |
| D 파일(취소 가능) | 음원 → 분석 파일 → 아트워크 → 그 밖 순서로 쓴다. 없는 폴더는 위에서부터 한 단계씩 만들고 저널에 적는다 | H |
| E DB 교체(커밋 지점) | exportLibrary.db → export.pdb → exportExt.pdb 순서로 바꾼다. 세부는 표 아래 "E DB 교체" 목록이다 | H |
| F 지우기 | 지우기 허용 목록의 파일만 지운다. 세부는 표 아래 "F 지우기" 목록이다 | H |
| G 검증 | 목표 지문을 매체에서 다시 읽어 비교한다. 없어야 할 경로, 우리 폴더의 임시 파일 0개, 이번에 바꾼 경로의 `._` 0개도 본다. 주입한 검증도 돈다 | H |
| H 되돌리기 | 7.6 | `restoreFailed`. 백업 폴더와 `djc usb-restore`를 안내한다 |
| I 끝 | 백업 폴더에 `report.json`(결과 DB SHA-256)과 `journal.json`(닫는 저널 사본)을 남긴다. 백업을 정리한다(7.9). 저널을 `verified`로 한다 | — |

**C 백업**:

- 백업 폴더에 담는 것:
  - DB, 사이드카, `export.pdb.bak`.
  - 덮어쓸 파일.
  - 지울 파일. 음원은 뺀다.
  - 그 파일들의 원래 있던 `._`.
  - `manifest.json`.
- 파일마다 복사 전후 크기와 mtime이 같아야 한다.

**E DB 교체**:

- DB 항목을 저널에 먼저 적는다. 그 뒤 임시 이름에 쓰고 rename한다.
- OneLibrary는 rename 전에 USB의 `-wal`, `-shm`, `-journal`을 지운다. 이 파일은 백업에 있다.

**F 지우기**:

- 크기와 SHA-256이 계획과 같아야 지운다.
- 분석 파일은 PPTH도 계획과 같을 때만 지운다.
- 맞지 않으면 건너뛰고 알린다. 이것은 실패가 아니다.
- 비게 된 우리 폴더만 지운다.

rekordbox와 rekordboxAgent는 A 단계에서 본다. D 전, DB마다, F 전에도 다시 본다. 켜져 있으면 멈추고 H로 간다.

### 7.2 A 막힘 확인 순서

1. **가드의 볼륨 정보와 무관한 확인이 맨 처음이다.**
   - 실물 쓰기가 닫혀 있는 동안 루트의 realpath(3)가 임시 폴더 뿌리 아래가 아니면 `physicalDisabled`로 끝낸다. 닫혀 있다는 것은 코드 관문 `UsbPhysicalWriteGate.buildEnabled`가 닫혔거나 사용자 동의가 없다는 뜻이다(§12).
   - 이때 잠금 파일을 만들지 않는다. USB 파일 연산도 하지 않는다.
   - 주입한 가드가 "디스크 이미지"라고 해도 같다. 가드 값 하나가 거짓이면 관문과 가드 값 확인이 함께 뚫리기 때문이다.
   - 디스크 이미지는 lab 도구와 앱 자가 테스트가 늘 임시 폴더 아래에 붙인다. 실물은 `/Volumes` 아래에 붙는다.
   - 시험 프로세스는 관문이 열려 있어도 임시 폴더 밖 루트를 같은 자리에서 거부한다. 거부 문구는 "시험 실행은 임시 폴더 아래 디스크 이미지에만 씁니다"다.
   - 관문이 열린 실행에서 루트가 임시 폴더 밖이면 가드가 디스크 이미지라고 해도 실물로 판정한다(`judgedForWrite`). 그러면 4의 실물 관문을 거친다. 볼륨 이름 확인도 거친다.
   - 이어서 루트가 정말 마운트 지점인지 본다. statfs `f_mntonname`이 realpath와 같아야 한다. 아니면 `notMountPoint`다.
   - 이 값을 기준 마운트 지점으로 기억한다(7.5).
2. 가드로 볼륨 정보를 읽는다. 읽기만 한다. 볼륨 UUID가 없으면 `noVolumeUUID`다. 잠금 전이라 잠금 파일이 생기지 않는다.
3. 잠금: `usb-sessions/<볼륨 UUID>.lock`에 `flock(LOCK_EX | LOCK_NB)`를 건다. 못 잡으면 `volumeBusy`다. 쓰기, 되돌리기, 회복이 끝날 때까지 쥔다.
4. 다음 확인을 한다.
   - rekordbox 실행: `rekordboxRunning`.
   - 볼륨 정책 `UsbVolumePolicy`와 보호 경로 `protectedPath`.
   - 실물 관문 `UsbRuleCheck`(§12). 닫혀 있으면 `physicalDisabled`다.
   - 늘 막는 확인 안 된 규칙 `carriedDeviceRows`.
5. 닫히지 않은 저널이 있으면 `recoveryNeeded`다.
   - 닫힌 상태는 `UsbJournal.closedStates` 한 곳에 둔다. 값은 verified, rolledBack, restored, recovered, dryRun, needsReplan이다.
   - 드라이 런은 USB에 아무것도 쓰지 않는다. 그래서 다음 쓰기를 막지 않는다.
   - needsReplan은 회복이 우리 임시 파일을 이미 지웠다. 그래서 다음 쓰기를 막지 않는다.
   - 저널 파일을 읽지 못하면 쓰기, 되돌리기, 회복 모두 `journalUnreadable`로 막는다. 회복도 거부하므로 회복하라고 안내하지 않는다.
   - 앱은 `UsbWriter.journalStatus`로 없음, 열림, 닫힘, 깨짐을 가른다.
6. 우리 폴더에 `.djc-part-*`가 있으면 `tempFilesPresent`다. 우리 폴더는 `PIONEER/rekordbox`, `PIONEER/USBANLZ`, `PIONEER/Artwork`, `Contents`다. 이 파일은 다른 Mac이나 다른 `DJC_HOME`의 쓰기 흔적이다. 이름만 본다.
7. 지문과 빈 곳을 본다.
   - 수정: 지금 DB 지문이 계획 때 `base`와 같아야 한다. 지문은 크기와 SHA-256이고 사이드카를 포함한다. mtime은 FAT 2초 단위이고 복원 때 바뀌므로 비교하지 않는다. 다르면 `usbChanged`다.
   - 내보내기: `PIONEER/` 바로 아래에 `.`으로 시작하지 않는 이름이 없어야 한다. 있으면 `notEmpty`다. 개수는 바로 아래 이름만 센다. 열지 않는 경로로는 내려가지 않는다.
8. 형식 검사기 `UsbWriteInspector`의 막힘을 본다. 10의 경로 막힘이 있으면 검사기를 부르지 않는다. 받을 수 없는 경로를 검사기가 읽지 않게 하려는 것이다.
9. 용량을 본다. 조건은 새로 쓸 크기 + 가장 큰 DB × 2 + 여유 − 지울 크기 ≤ 가용이다. 새로 쓸 크기는 클러스터 단위로 올린다. 여유는 64 MiB와 가용 1% 중 큰 값이다.
10. 대상 경로를 본다.
   - 상대 경로여야 한다. `..`이 없어야 한다. 열지 않는 경로가 아니어야 한다. 부모 경로에 심볼릭 링크가 없어야 한다.
   - 모양 규칙은 `UsbWriter.isSafeRelativePath`다. 첫 성분은 PIONEER나 Contents다. 빈 성분, "." 성분, ".." 성분은 없어야 한다.
   - 되돌리기와 회복도 기록을 읽을 때 같은 모양 규칙을 쓴다.
   - 세션 번호는 임시 이름이 되므로 영문, 숫자, `-`, `_`만 받는다.
11. **만들 대상 충돌(`destinationExists`):**
   - rename(2)은 대상이 있으면 조용히 바꿔친다. FAT(macOS msdos)는 대소문자나 NFC/NFD만 다른 이름을 같은 이름으로 본다.
   - 만들 파일, 내보내기의 DB, 새 폴더마다 부모 폴더 목록을 본다. 같은 `UsbLayout.collisionKey`의 이름이 있으면 막는다.
   - 받을 수 없는 경로는 stat하지 않고 열거하지 않는다. 건너뛴다. 10이 그 경로를 막는다.
   - 폴더는 NFC까지 같은 철자면 있는 폴더로 쓴다. 철자만 다르면 막는다.
   - D 단계의 rename 직전에 한 번 더 본다. 그 사이 생긴 이름은 우리 것이 아니므로 H도 건드리지 않는다.
   - 이 규칙은 백업에도 없는 사용자 파일을 잃지 않게 한다. 예: `Contents/`에 직접 넣은 음원.

### 7.3 파일 하나 쓰기

- 임시 이름은 `UsbLayout.tempName(session:sequence:)`로 만든다. 같은 폴더에 `.djc-part-…` 모양으로 둔다. 대상 이름과 무관하므로 `._`나 `_`로 시작하는 이름과 겹치지 않는다.
- 파일 하나는 다음 순서로 쓴다.
  1. 저널 항목(pending)을 먼저 적는다.
  2. `O_EXCL`로 데이터만 복사한다. 확장 속성과 ACL은 복사하지 않는다. 준비 파일은 복사 대신 쓴다.
  3. 음원과 아트워크는 원본 mtime을 맞춘다.
  4. `F_FULLFSYNC`를 한다.
  5. 덮어쓰기면 대상의 지금 SHA-256이 계획과 같은지 본다. 분석 파일은 PPTH도 본다. 만들기면 충돌을 다시 확인한다.
  6. rename한다.
  7. 정확한 이름 `._<대상>`와 `._<임시>`만 지운다.
  8. 폴더 fsync를 한다.
  9. 저널 항목을 done으로 한다.
- `._` 파일은 패턴으로 쓸지 않는다. 사용자의 `._` 파일은 남는다.
- `RENAME_SWAP`과 `renamex_np`를 쓰지 않는다. FAT에서는 맞바꾸지 않고 덮어쓴다.
- 재사용 파일은 쓰지 않는다. 크기와 내용 해시만 확인한다.
  - 분석 파일과 아트워크는 계획 SHA-256과 비교한다.
  - 음원은 목표 지문의 SHA-256과 비교한다. 없으면 로컬 원본의 SHA-1과 비교한다.
  - 음원에 둘 다 없을 때만 크기만 본다.
  - 음원은 덮어쓰지 않는다.

### 7.4 Mac 쪽 내구 쓰기와 저널

- 저널, manifest, 보고서는 `UsbDurableFile`로 쓴다. 순서는 다음과 같다.
  1. 같은 폴더에 임시 파일을 만든다.
  2. write한다.
  3. `F_FULLFSYNC`를 한다.
  4. rename한다.
  5. 폴더 fsync를 한다.
- C 백업은 모든 쓰기에서 완성한 manifest를 전체 계획과 저널의 필수 범위와 대조한다. 대조한 뒤에만 `backedUp`으로 확정한다.
  - 준비 뒤 백업 전에 DB나 덮어쓸 파일이 바뀌어 기준이 어긋나면 D와 E의 USB 연산에 들어가지 않는다.
  - 일반 편집도 알려진 DB와 사이드카의 `base` 누락을 원래 부재로 비교한다. 새 WAL 등을 백업 기준으로 흡수하지 않는다.
  - `base`가 없는 새 내보내기도 생성할 DB와 OneLibrary 사이드카의 부재를 검사한다. 검사 시점은 C의 시작, manifest 대조, 확정 직전이다.
  - `base`가 관찰하지 않는 `.bak`는 기존 별도 처리대로 보존한다.
- 저널 `usb-sessions/<볼륨 UUID>.json`에는 다음을 담는다.
  - 파일·DB 항목. 종류는 created, reused, overwritten이고 상태는 pending, done이다.
  - 만든 폴더.
  - 지운 사이드카.
  - 지우기 상태. removed나 skipped와 그 이유를 적는다.
  - 백업 폴더.
- 저널 상태 값은 `committing`과 `committed` 중 하나다. 형식별 진행은 DB 항목에서 읽는다. 읽는 값은 `committedFormats`와 `committingFormat`이다.
- 저널 파일은 볼륨마다 하나다. 드라이 런을 포함한 새 세션이 닫힌 옛 저널을 덮는다. 그래서 되돌리기와 백업 정리는 백업 폴더의 `journal.json`과 `report.json`을 읽는다.

### 7.5 마운트 확인과 볼륨이 사라질 때

- 루트가 아직 기준 마운트 지점에 붙어 있는지 다음 시점에 본다.
  - C 시작.
  - D의 파일마다 쓰기 전과 rename 직전.
  - E의 DB마다.
  - F 전과 G 전.
  - H 시작과 H의 파일마다.
  - 회복과 되돌리기의 파일 연산 전.
- 실물은 뽑히면 마운트 폴더가 사라진다. 디스크 이미지를 강제로 떼면 임시 폴더의 마운트 지점이 빈 폴더로 남는다. 확인 없이 이어 가면 USB가 아니라 Mac 폴더에 쓴다.
- 사라졌으면 그 자리에서 멈춘다. 되돌리지 않는다(`volumeLost`). 저널은 마지막 내구 상태 그대로 둔다. 같은 볼륨이 다시 붙으면 회복이 이어 판정한다.
- **같은 자리에 다른 볼륨이 붙을 때**: 쓰는 도중 USB A가 빠지고 같은 이름의 USB B가 같은 `/Volumes/<이름>`에 붙을 수 있다. 마운트 지점 문자열은 그대로라 위 확인을 지난다. 그대로 이어 가면 B에 쓴다. 실패 뒤 H가 A의 백업으로 B를 덮는다. H는 A가 만든 경로도 B에서 지운다. 그래서 볼륨 정체도 본다.
  - 열 때 루트 폴더 fd를 열어 쥔다(`UsbFileSystem.holdVolume`). 시점은 7.2의 1 뒤이고 볼륨 정보를 읽기 전이다.
  - 마운트 확인마다 그 fd의 `fstatfs`와 경로의 `statfs`가 같은 파일 시스템인지 본다. 같은 파일 시스템은 fsid, 장치, 마운트 지점, 형식이 모두 같은 것이다.
  - 빠진 볼륨의 fd는 죽은 vnode가 되어 어긋난다. B가 같은 `/dev/diskN`을 받아도 fd 쪽이 죽어 있어 어긋난다. fd를 쥐고 있는 동안은 보통 꺼내기도 실패한다.
  - 다음 시점에는 가드로 볼륨 정보를 다시 읽어 UUID와 용량이 처음과 같은지도 본다. 읽지 못해도 다른 볼륨으로 본다.
    - C 시작.
    - D의 파일 묶음마다. 묶음 순서는 음원 → 분석 → 아트워크 → 그 밖이다.
    - E의 DB마다.
    - F 전과 G 전.
    - H 시작.
    - 회복과 되돌리기 시작. `usb-restore`는 저널을 열기 전에 본다.
  - 어긋나면 그 볼륨에는 아무것도 쓰지 않는다. H도 하지 않는다. 멈추고 `volumeChanged`로 알린다. 안내 문구는 "처음 USB를 다시 꽂고 회복하세요"다.
  - 한 번 어긋나면 그 실행의 모든 확인이 실패한다. 저널은 처음 USB의 볼륨 키에 그대로 남는다. A가 다시 붙으면 회복이 이어 판정한다. B에서는 저널이 없어 회복이 할 것이 없다.
  - 앱은 사용자가 확인 창에서 본 볼륨의 UUID를 쓰기, 회복, 되돌리기에 넘긴다. 인자는 `UsbWriteOptions.expectedVolumeUUID`이고, `recover`와 `restore`에도 같은 인자가 있다. 열 때 지금 볼륨과 다르면 잠금도 잡지 않는다. `volumeChanged` 막힘으로 끝낸다.
  - 한계: 확인과 다음 파일 연산 사이에 짧은 틈이 남는다. 이 틈은 경로로 연다. 그 틈에 바뀌면 다음 확인에서 멈춘다.

### 7.6 H 되돌리기

- 순서는 다음과 같다.
  1. 마운트를 확인한다. 사라졌으면 멈춘다.
  2. rekordbox를 다시 확인한다. 켜져 있으면 저널을 `restorePending`으로 한다.
  3. pending 항목은 임시 이름만 지운다. 대상 이름의 파일은 우리 것이 아닐 수 있다.
  4. 만든 파일을 지운다. 정확한 `._`도 지운다.
  5. 덮어쓴 파일은 백업에서 임시 이름으로 되살린 뒤 rename한다.
- DB는 저널의 DB 항목대로 한다.
  - 내보내기에서 쓰기 전에 없던 DB는 그 DB, `-wal`, `-shm`, `-journal`과 정확한 이름의 `._`만 지운다.
  - 수정에서 덮어쓴 DB는 USB 사이드카를 지운다. 백업의 DB, 사이드카, 원래 있던 `._<DB>`를 되살린다.
- 지운 파일은 백업에서 되살린다.
  - 지운 음원은 로컬 원본의 SHA-1이 같을 때만 다시 복사한다.
  - 원본이 없거나 바뀌었으면 알림만 남기고 지문 비교에서 뺀다. 되돌릴 수 없는 것을 실패로 세면 회복이 끝나지 않기 때문이다.
  - 쓰기 전에 이미 없던 파일은 되살릴 것이 없다.
- 만든 폴더는 거꾸로 비었으면 지운다. 우리 경로 지문이 쓰기 전과 같으면 `rolledBack`이다. 아니면 `restoreFailed`다.
- 복원도 임시 파일 준비, rename/delete 진입, 완료를 저널에 기록한다.
  - 재개 전에는 완료한 XML, DB, 사이드카도 현재 해시, 부재, 링크를 다시 확인한다.
  - 승인 뒤 바뀐 대상이 있으면 `restorePending`과 재승인 필요 기록으로 남긴다. 외부 삭제와 구분할 수 없는 중단도 같다. 이때 복원 temp를 보존한다.
  - 옛 저널의 temp는 두 조건을 모두 만족할 때만 새 의도로 이어받는다. 조건은 같은 세션에서 유일함, 백업 해시·크기와 일치함이다.
- 완료 전 의도도 처음 기록한 기대 해시와 링크 신원, 단계별 허용 결과로 재개한다. 저장된 폐기 승인이 그 뒤의 외부 변경까지 허용하지는 않는다. 기준을 다시 채택하는 것은 같은 백업을 명시적으로 재승인한 복원뿐이다.
- 폐기 승인 저널을 저장하기 전에 아직 의도가 없는 뒤쪽 대상까지 전체 기준을 고정한다.
  - 고정하는 대상은 DB, 사이드카, XML, 삭제 파일, 다시 복사할 음원, 백업의 AppleDouble이다.
  - 전체 기준이 없는 옛 승인 저널은 기존 의도와 temp를 보존한다. 미기록 대상의 현재 상태를 새 승인으로 간주하지 않는다. 재승인을 요구한다.

### 7.7 회복(`djc usb-recover`) — 대상 먼저

- 쓰기와 같은 확인을 먼저 거친다. 범위는 7.2의 1–4이고 관문을 포함한다. 회복도 USB 파일을 지우고 이름을 바꾸는 쓰기다. 앱의 회복도 같다.
- 저널의 경로, 임시 이름, 세션이 7.2-10의 모양 규칙을 어기면 파일 연산 없이 `journalUnreadable`로 막는다. 백업 폴더가 이 볼륨의 `usb-backups/<볼륨>/` 밖이어도 같다. 없어진 백업 폴더는 없는 것으로 본다. 기록을 새로 만들지 않는다.
- `usb-restore`가 연 저널(끊긴 되돌리기)은 되돌리기로 마저 한다. 그리고 `restored`로 닫는다. 그 쓰기의 백업 기록은 바꾸지 않는다.
- DB마다 옛 해시, 새 해시, 없음, 그 밖으로 나눈다.
  - "그 밖"은 기기가 바꾼 경우다. 하나라도 있으면 저널에 적힌 우리 임시 파일만 지우고 `needsReplan`으로 닫는다.
  - 다음 쓰기는 지금 USB를 다시 읽어 만든 새 계획이어야 한다. 옛 계획은 `usbChanged`로 막힌다.
- 대상이 없고 임시 파일이 새 해시와 같으면 rename을 마친다. 만들기는 충돌을 다시 확인한 뒤에 한다.
  - 모든 DB가 새것이면 F와 G를 다시 해서 `recovered`로 닫는다.
  - 일부만 바뀌었으면 준비 폴더가 온전하고 남은 DB가 옛것일 때 마저 쓴다.
  - 그렇지 않으면 H로 `rolledBack`을 만든다.
- rename 진입(`writePhase = renameEntered`) 뒤 대상이 없는 항목은 둘로 나눈다.
  - DB는 USB에 DB가 없는 채로 둘 수 없다. 완전한 temp(새 해시)로 마저 쓴다. 옛 DB는 백업에 있다.
  - 덮어쓴 파일(DB 밖)은 FAT 두 단계 rename이 끊긴 것과 그 사이 밖에서 지운 것을 구분할 수 없다. temp가 완전해도 마저 쓰지 않는다. `restorePending`(재승인 필요)으로 멈춘다.
  - 추측해 쓰면 밖에서 한 변경을 덮을 수 있다. 그래서 안전한 쪽을 골랐다(`completeInterruptedRenames`).
- `.syncSelection` 묶음은 일부만 이어 쓰지 않는다. DB와 두 선택 파일을 전체 복원한다.
  - 외부 변경, 삭제, 모호한 rename 중단은 `restorePending`으로 멈춘다. 반복 회복에서도 승인 대기를 유지한다.
  - 같은 쓰기의 백업으로 `--discard-device-changes`를 명시한 복원이 승인 경로다.
  - native DB와 선택 파일이 쓰기 전 기준과 다르면 성공으로 닫지 않는다.
- 저널에 적힌 임시 파일은 판정이 끝난 뒤 지운다. 저널이 없으면 USB의 `.djc-part-*`를 보고만 한다. `--discard-temp`일 때만 지운다.
- 닫을 때 그 쓰기의 백업 폴더에 `journal.json`과 `report.json`을 남긴다. `report.json`에는 회복 뒤 지금 DB 해시를 적는다. 끊긴 쓰기도 백업 정리와 되돌리기가 알아보게 하려는 것이다. 백업 전에 끊겼으면 USB에 쓴 것이 없다. 알림만 남긴다.

### 7.8 되돌리기(`djc usb-restore`)

- 같은 확인을 먼저 거친다. 무엇을 되돌릴지는 그 백업 폴더의 `journal.json`에서 읽는다.
  - 백업 폴더는 realpath가 이 볼륨의 `usb-backups/<볼륨>/` 바로 아래여야 한다(`backupOutside`).
  - `journal.json`과 `manifest.json`의 경로가 7.2-10의 모양 규칙을 어기면 파일 연산 없이 `backupUnreadable`로 막는다.
- manifest는 원래 변경 묶음, 파일·DB, 삭제, 복원 의도의 필수 백업 범위와 대조한다. 필요한 기록이나 파일이 빠졌거나 해시가 다르면 USB 연산 전에 거부한다. 새 저널은 manifest 해시도 기록한다. 이 optional 값이 없는 옛 저널에도 범위 검사는 적용한다.
- 되돌리기를 마치면 백업 폴더에 `restored.json`을 남긴다.
  - 정상적으로 닫힌 세션의 같은 백업으로 다시 되돌리면 "이미 되돌렸습니다"로 끝낸다. 그 뒤 USB를 바꾼 것은 기기가 아니라 이 되돌리기다.
  - 표지 저장 뒤 저널 닫기 전에 중단된 열린 세션은 완료 항목 검사와 명시적 재승인 경로를 먼저 거친다.
  - `--backup`을 빼도 가장 최근 백업을 고른다. 그래서 두 번 돌려도 더 옛 쓰기까지 되돌리지는 않는다.
- 지금 DB 해시가 `report.json`의 결과 해시와 같고 USB에 `-wal`과 `-journal`이 없을 때만 진행한다. 아니면 막는다. 기기가 쓴 기록이 한 예다. `--discard-device-changes`를 줘야 기기 변경을 버리고 되돌린다. 회복이 needsReplan으로 닫은 쓰기는 해시가 같아도 이 인자를 요구한다.
- 만든 파일, 폴더, DB는 지운다. 덮어쓴 것은 백업에서 되살린다. 재사용한 것은 그대로 둔다. 지웠던 음원은 로컬 원본의 SHA-1이 manifest와 같을 때만 다시 복사한다. 그래서 내보내기 직후 되돌리면 빈 USB로 돌아간다.

### 7.9 백업 정리

볼륨마다 최근 다섯 개만 남긴다. 다음 백업은 이 수와 상관없이 남긴다.

- 닫히지 않은 저널이 가리키는 백업.
- 마지막 verified 쓰기의 백업.
- 마지막 needsReplan 백업. 다음 verified 전까지 남긴다.

판정은 백업 폴더의 `journal.json` 상태로 한다.

### 7.10 디스크 이미지(`djc lab usb-image`)

- 모든 경로 인자는 임시 폴더 아래만 받는다(`UsbScratchPath`). 경로 비교는 realpath(3)끼리 한다. `hdiutil info`의 image-path는 attach 때 준 철자 그대로라서 `/tmp`와 `/private/tmp`가 섞이기 때문이다.
- 만드는 순서는 다음과 같다.
  1. sparse raw 파일을 만든다.
  2. MBR을 쓴다. 파티션은 하나이고 2048섹터부터이며 형식은 0x0B 또는 0x0C다.
  3. `hdiutil attach -nomount`로 붙인다.
  4. 장치는 그 attach plist의 `content-hint`로 고른다. 전체는 `FDisk_partition_scheme`, 파티션은 `DOS_FAT_32` 또는 `Windows_FAT_32`다. 배열 순서에 기대지 않는다.
  5. 파괴 명령 직전에 image-path, `BusProtocol == "Disk Image"`, `Internal == false`를 다시 확인한다.
  6. `newfs_msdos -F 32`를 돌린다.
  7. 파티션 표 값만 확인한다. 포맷 직후의 파일 시스템 이름은 비어 있거나 "MS-DOS"라서 보지 않는다.
  8. 떼고 BPB로 FAT32를 판정한다. 클러스터 수 ≥ 65,525가 기준이다.
- 클러스터: 파티션 8 GiB 이하는 4 KiB부터 시작한다. 클러스터 수가 FAT32 최소에 모자라면 반으로 줄인다. 64 MiB보다 작은 이미지는 받지 않는다.
- hdiutil은 성공해도 stderr에 경고를 찍는다. 성공과 실패는 rc와 stdout plist로만 판정한다.
- 붙이기는 `diskutil mount -mountOptions nobrowse -mountPoint`로 한다. 파일 시스템 이름이 "MS-DOS FAT32"로 보일 때까지 기다린다.
- 장치 번호는 인자로 받지 않는다. 늘 이미지 경로에서 `hdiutil info`로 찾는다. rekordbox가 켜져 있으면 만들기, 붙이기, 채우기, 쓰기 시험을 거부한다.
- 볼륨이 디스크 이미지인지는 세 조건이 모두 맞을 때만 참이다. 모르면 실물로 본다.
  - DiskArbitration `DADeviceModel == "Disk Image"`.
  - `hdiutil info`의 짝.
  - image-path가 일반 파일.
- FAT32는 볼륨 종류, 볼륨 형식("MS-DOS (FAT32)"), 파티션 형식이 모두 맞을 때만이다. 0x0B 파티션 안의 FAT16은 FAT16이다.

### 7.11 근거

디스크 이미지 강제 분리 시험은 `djc lab usb-commit-crash`다. 빈 FAT32 틀의 복제본에 합성 묶음을 쓰는 도중 무작위 시점에 강제로 뗀다. 다시 붙여 원시 상태를 본 뒤 회복한다. 반복 시험에서 파일마다 옛것 또는 새것이었다. 회복 뒤 트리는 쓰기 전 또는 목표와 같았다. 분리 뒤 Mac 폴더에 쓴 흔적은 없었다.

### 7.12 빈 USB 내보내기(`UsbExportSession`, `djc usb-export`)

로컬 스냅샷 사본의 곡과 재생 목록을 빈 USB에 두 형식으로 내보낸다. USB는 FAT32 또는 exFAT이고 파티션 표는 MBR 또는 GPT다. 흐름은 후보 → 계획 → 빌더 → 준비 → 쓰기 → 검증이다. 세션 `UsbExportSession`은 DJCApplication의 유스케이스다. 세션이 이 단계를 순서대로 부른다.

세션은 입출력을 포트로만 한다.

- USB 읽기, 계획, 준비, 쓰기는 `UsbLibraryEngine`이 한다.
- 이 Mac의 일은 `UsbDevice`가 한다. 일은 라이브 판정, 세션 사본, 사본 지우기, 파일 있음이다.
- 실제 구현은 DJCAdapters에 있다. 조립 지점인 앱과 CLI가 고른다.

미리 보기 `preview`와 드라이 런은 준비까지 같다. USB에 쓰지 않는다.

1. **원본**: 받은 사본이 라이브 master.db면 열지 않고 `liveDatabase`로 막는다. 판정은 `UsbLiveDatabase.isLive`가 한다.
   - 이 Mac의 실제 `~/Library/Pioneer/rekordbox/master.db`는 늘 라이브다.
   - 이 실행의 rekordbox 폴더(`DJC_REKORDBOX_DIR`)의 master.db도 늘 라이브다.
   - 그 밖에 조립 지점이 덧붙인 경로가 있다.
   - 실경로나 링크를 따라간 같은 inode, 같은 표준 경로도 라이브로 본다.
   - 스냅샷 시각을 이때 원본에서 푼다. 순서는 `UsbSnapshotTime`의 `--snapshot-time` → 사본 이름 → 수정 시각이다. 세션이 다시 뜨는 사본은 이름과 시각이 달라지기 때문이다.
2. **볼륨 단위 막힘**: 여기서 막히면 로컬 사본도 뜨지 않는다. 막힘은 다음과 같다.
   - 이 Mac의 rekordbox가 확인한 버전이 아님: `localVersionUnverified`.
   - 볼륨 정책 `UsbVolumePolicy`(내보내기).
   - 보호 폴더 `protectedPath`.
   - 실물 관문 `UsbRuleCheck`. 실물이거나 루트가 임시 폴더 밖이면 §12의 조건을 따른다. 동의가 없으면 `physicalDisabled`다. 이름이 다르면 `confirmMismatch`다.
   - 정책, 보호 폴더, 관문에 막힌 볼륨은 이름도 열거하지 않는다. 여기서 멈춘다. 쓰기 절차 A 단계와 같은 순서다.
   - 그 다음에야 USB를 본다.
     - `PIONEER/rekordbox/`에 DB 이름이 있으면 `libraryExists`다. USB 수정으로 안내한다.
     - DB는 없지만 `PIONEER/` 바로 아래에 `.`으로 시작하지 않는 이름이 있으면 `leftoverPioneer`다. 이름만 세고 열지 않는 경로로 내려가지 않는다.
   - rekordbox 실행은 쓰기 절차가 본다. 켜진 채 미리 보기는 된다.
3. **세션 사본**: 받은 사본을 `usb-snapshots/local-<세션>/`에 한 번 더 뜬다.
   - 원본은 받은 사본이고 `force: true`다. 우리 사본이라 실행 중 확인과 WAL 거부가 없다. 곁의 `-wal`을 사본 안에서 합친다. 원본과 그 `-wal`은 읽기만 한다.
   - 사용자 스냅샷 폴더는 목적지로도 원본으로도 쓰지 않는다. 읽지도 않는다.
   - 세션이 끝나면 이 폴더를 지운다. 성공, 실패, 취소 모두 같다. 클라우드 토큰이 든 DB 사본을 남기지 않게 하려는 것이다.
4. **계획**: 이미 `Contents/`가 있으면 그 아래 이름과 철자를 모아 `UsbExistingState.contentsOnly`로 넘긴다. 모으는 도구는 `UsbTree.walk`이고 파일은 열지 않는다.
   - 같은 충돌 키의 파일이 같은 내용이면 그 파일을 가리킨다. 같은 내용은 크기와 SHA-256이 같은 것이다. 쓰지 않는다.
   - 내용이 다르면 ` (2)`처럼 번호를 붙인다. 폴더는 USB 철자를 쓴다(§5).
   - 클러스터 크기는 볼륨 값이다.
5. **빌더와 곡 막힘**: `UsbLibraryBuilder.build`가 만든다. myTagMasterDBID는 난수이고 createdDate는 오늘이다.
   - Device Library를 쓰면 작성기가 거부할 곡을 먼저 본다. 작성기가 곡 하나 때문에 내보내기 전체를 멈추지 않게 하려는 것이다.
   - 곡을 막는 경우는 다음과 같다.
     - 트랙 행이 빈 쪽에도 안 들어가면 그 곡이다: `trackRowTooLarge`, `PdbRowSize`.
     - 파일 확장자가 file_type과 다르면 그 곡이다: `fileTypeMismatchForDeviceLibrary`.
     - ISRC가 ASCII가 아니면 그 곡이다: `isrcNotASCIIForDeviceLibrary`.
     - 디스크 번호나 연도 같은 칸 값이 칸 크기를 넘으면 그 곡이다: `valueOutOfRangeForDeviceLibrary`. 문구에 칸 이름을 넣는다.
     - 아티스트나 앨범 행이 빈 쪽에도 안 들어가면 그 이름을 쓰는 곡이다: `nameTooLongForDeviceLibrary`. 긴 이름은 먼 모양으로 쓴다(§3.8).
   - My Tag 행이 가까운 모양(255바이트)에 안 들어가면 볼륨을 막는다: `myTagNameTooLongForDeviceLibrary`. My Tag 정의는 곡과 무관하게 모두 들어가므로 곡을 빼서 풀 수 없다.
   - 막힌 곡을 빼고 다시 계획해 ID가 빈틈없게 한다.
6. **준비**(`UsbExportAssembly`): Mac의 `usb-staging/<세션>/`에 USB와 같은 자리로 만든다.
   - 곡마다 분석 파일 셋을 만든다(§4). 경고는 `analysisPSSIMasked`, `kind4CueDropped` 등이다.
   - 곡마다 아트워크를 만든다. `artwork_s.jpg`는 a와 b로, `artwork_m.jpg`는 a_m과 b_m으로 바이트 복사한다. 원본 수정 시각을 쓴다. a는 Device Library를 쓸 때만, b는 OneLibrary를 쓸 때만 만든다.
   - OneLibrary: `OneLibraryWriter.create` 뒤 `verify`를 돈다. 준비한 DB를 읽기 전용으로 열지 않는다. WAL 모양 파일 곁에 사이드카가 남기 때문이다.
   - Device Library: `PdbWriter.files(.fresh)` 뒤 `PdbRoundTrip.check`가 빈 배열이어야 한다.
   - 음원은 복사 목록만 만든다. 목록은 원본 → 계획 경로, 크기, 원본 수정 시각이다.
     - 크기는 계획 때 본 실제 크기다. 분석 뒤 바뀐 곡은 DB의 `FileSize`와 다르다(§5).
     - `--settings`면 로컬 설정 파일 셋을 더한다(§6).
   - 목표 지문: DB 셋, 분석 파일, 아트워크는 크기와 SHA-256이다. 음원은 크기다. 해시는 복사하며 잰다.
   - 확인 안 된 규칙은 다음 넷의 합집합이다.
     - 계획 규칙. 목록 이름의 `pdbLongAscii`를 포함한다.
     - 분석 파일 규칙.
     - Device Library 작성기 규칙. 긴 ASCII를 본 적 없는 칸의 `pdbLongAscii`가 있다. 장르, 레이블, 키, My Tag 이름까지 해당한다. 실험이 보지 못한 이름 끝(앨범 247)의 `pdbFarOffsetRows`도 있다.
     - `settingFiles`. 켰을 때만 넣는다.
   - 규칙별 곡 수는 계획 곡 규칙에 작성기의 곡별 규칙을 더해 센다. 같은 곡은 한 번만 센다.
7. **막힘 모음**: 곡·목록 단위 막힘은 그 곡이나 목록만 빼고 쓴다. 볼륨 단위 막힘이 하나라도 있으면 쓰지 않는다. 볼륨 단위 막힘은 2와 5의 볼륨 막힘, 확인 안 된 규칙, 용량 `insufficientSpace`, 곡이 없음 `noTracks`다.
8. **쓰기**: `UsbWriter.write`를 부른다(§7.1).
   - 검사기는 `UsbEmptyVolumeInspector`다. A 단계에서 한 번 더 본다. `PIONEER/` 바로 아래 이름이 0개여야 한다. 만들 대상과 충돌 키가 같은 이름이 없어야 한다.
   - 검증기는 `UsbFingerprintVerifier`, `OneLibraryVerifier`, `PdbVerifier`, `UsbInvariantVerifier`다. 쓰기 직전 USB의 `._*` 목록을 함께 준다.
   - `ppthReader`는 분석 파일의 PPTH 태그를 읽는다.
9. **정리**: 준비 폴더를 지운다. 끝나지 않은 쓰기는 회복이 쓸 수 있게 남긴다. 끝나지 않은 쓰기는 볼륨이 사라진 경우, 되돌리기가 실패한 경우, 되돌리기를 미룬 경우다.

진행 이벤트는 두 쪽에서 나온다. 세션이 `planning` → `staging`을 낸다. `staging`은 곡 n/N을 알리고 취소할 수 있다. 이어서 쓰기 절차가 `backup` → `files` → `commit` → `cleanup` → `verify`를 낸다. `commit`은 취소할 수 없다. 준비 중 취소하면 저널도 만들지 않는다.

**검증기**: G 단계에서 USB에서 다시 사본을 떠서 연다. 문제는 표, 칸 이름, 곡 id, 수만 적는다.

- `OneLibraryVerifier`는 세 가지를 본다.
  - 사이드카(`-wal`, `-shm`, `-journal`)가 없다.
  - 사본의 무결성과 암호 검사가 통과한다.
  - 다시 읽은 모델이 기대 모델의 OneLibrary 투영과 같다(`UsbLibraryDiff`, formats: [.oneLibrary]).
- `PdbVerifier`는 다음을 본다.
  - 두 파일의 칸이 작성기가 쓴 모델(`PdbFiles.written`)의 Device Library 투영과 같다.
  - 머리 0x10이 5다.
  - 머리 순번이 모든 쪽 순번보다 크다.
  - 구조 문제가 0이다.
  - 아티스트와 앨범 밖의 먼 모양 행이 0이다.
  - 표마다 사슬 마지막 쪽이 포인터 last_page이고, 그 쪽 next가 빈 후보다.
  - 빈 후보는 0으로 채운 쪽이거나 파일 끝 너머다.
- `UsbInvariantVerifier`는 일곱 가지를 본다.
  1. 곡마다 pdb 분석 경로와 OneLibrary 분석 경로(NFC)가 같다.
  2. `.DAT` PPTH가 두 DB의 곡 경로와 같다.
  3. 파일 이름이 경로 끝 성분과 같다.
  4. DB가 가리키는 파일이 모두 있다. 파일은 음원, 분석 파일 셋, 아트워크다. 음원 크기는 파일 크기 칸과 같다. 이 쓰기가 로컬 `FileSize`로 적은 `audioChangedSinceAnalysis` 곡은 뺀다. 크기 문제는 형식과 무관하게 곡마다 한 번 센다(§5).
  5. 분석 파일 폴더 안 같은 번호를 두 곡이 쓰지 않는다.
  6. 곡 수 칸과 두 형식의 곡 수가 같다. 곡 수 칸은 OneLibrary property와 pdb 표 19다.
  7. 이 쓰기가 남긴 `._*`와 `.djc-part-*`가 0개다. 쓰기 직전부터 있던 `._*`는 세지 않는다. 예: 루트 `._.Trashes`, 사용자 음원 옆의 것. 쓰기 전 확인이 이것을 막지 않기 때문이다.

디스크 이미지에서 확인하는 법은 `docs/cli.md`의 "USB 내보내기"에 있다. 골든과는 `djc lab usb-diff <골든> <이미지> --ignore-anlz-folder --files --anlz --mtime`로 비교한다. 재생 목록 표는 rekordbox가 항목을 한 번 더 넣는 모양이 있어 `--skip`으로 뺀다. 다시 만들기는 `djc lab usb-rebuild`로 본다(§8.2). 골든과 달라야 정상인 것은 다음과 같다.

- 설정 파일 셋. 기본은 끔이다.
- DB 세 파일의 바이트. 칸 비교로 판정한다.
- property의 createdDate와 myTagMasterDBID. Device Library 날짜도 포함한다.
- 지운 행 id. 새 파일에는 없다.
- 분석 파일의 수정 시각. 쓴 시각이다.

## 8. USB 안 수정

### 8.1 읽기 점검(`UsbRead`, `djc usb-info`)

고치기 전과 앱 사이드바가 USB를 보여 줄 때, USB를 읽기만 해서 무엇이 있는지와 건강한지를 본다. USB에는 아무것도 쓰지 않는다. 명령과 JSON 모양은 `docs/cli.md`의 "USB 읽기"에 있다.

1. 볼륨 판정:
   - 대상 경로의 `statfs` 마운트 지점이 Mac 시동 볼륨이 아니면, 그 볼륨(`UsbVolumes.info`)으로 본다. Mac 시동 볼륨은 `/`와 `/System/Volumes/Data`다.
   - 대상이 볼륨 맨 위가 아닌 하위 폴더여도 같다.
   - 실물 USB도 등록 없이 읽는다(사용자 결정, 2026-10).
   - 볼륨 정책 문제(`UsbVolumePolicy`)를 내보내기와 고치기 각각에 대해 함께 적는다.
   - 앱 사이드바는 정책에 걸리는 볼륨의 사본을 뜨지 않는다. 이유만 보인다. 예를 들어 APFS가 그렇다.
   - 옛 쓰기 금지·허용 목록 파일 `usb-physical-deny.json`과 `usb-physical-allow.json`이 남아 있어도 읽지 않는다. 지우지도 않는다.
   - 부르는 쪽이 볼륨 없이(폴더 대상으로) 넘겨도 `UsbRead.info`가 마운트 지점을 다시 본다. Mac 시동 볼륨이면 읽지 않는다.
   - 사본 폴더가 있다면 비어 있어야 한다. 아니면 거부한다. 끝나면 그 호출이 뜬 사본만 지운다.
2. 형식: `PIONEER/rekordbox/` 바로 아래 파일 이름만 본다. `exportLibrary.db`는 OneLibrary, `export.pdb`는 Device Library다.
3. DB: `UsbSnapshot.take`로 Mac 쪽 사본을 뜬다(§2.3). 사본을 읽은 뒤 지운다.
   - OneLibrary는 다음을 읽는다.
     - 사이드카(`-wal`·`-journal`) 유무
     - 머리 모양(wal 또는 rollback)
     - `integrity_check`와 `cipher_integrity_check`
     - 호환 검사(§2.4)
     - 곡 수, 재생 목록 수, My Tag 수, 기록 수
   - 사본이 온전하지 않으면 OneLibrary는 읽지 못한 것으로 적는다. 그때는 pdb 둘만 따로 떠서 읽는다.
   - Device Library는 다음을 읽는다.
     - 머리 0x10(두 파일). 5가 아니면 rekordbox가 정상으로 닫지 않은 것이다.
     - 기록 표 산 행
     - 모르는 표 산 행
     - 구조 문제 수(§3.7)
     - 왕복 검사(`PdbRoundTrip.check`, §3.8). 순서는 읽기, 모델, 다시 쓰기, 다시 읽기다.
   - 왕복 검사가 통과하지 못하면 경고 `pdbRoundTripFailed`를 문제 수만 적어 낸다. 작성기가 다시 만들 수 없는 것이 있기 때문이다. My Tag 연결과 모르는 표 행이 그 예다.
4. 두 형식 일치(`UsbLibrary.merge`, §2.6): 다음을 본다.
   - 곡 ID와 경로가 같은지
   - 다른 재생 목록 수
   - 고치기를 막는 불일치(`blocksEditing`)가 있는지
   - 모든 곡의 masterDbId가 한 값인지
   - 두 형식의 myTagMasterDBID가 같은지

   식별값 자체는 내지 않는다.
5. 분석 파일: 곡마다 다음을 본다.
   - 두 DB가 가리키는 경로(같으면 한 번)의 `.DAT`·`.EXT`·`.2EX`가 일반 파일로 있는지
   - `.DAT` PPTH가 NFC 곡 경로와 같은지(§4.3)
   - 파일 번호가 0이 아닌지(§5)

   DB 경로가 열지 않는 경로나 링크를 거치면 없는 파일로 센다. 그 파일은 열지 않는다.
6. 음원: 읽은 두 DB의 서로 다른 NFC 음원 경로마다 확인한다. 본 것은 일반 파일이 있는지뿐이다. 다음은 누락으로 센다. 빈 경로, 탈출 경로, 금지 경로, 링크, 폴더. 음원 바이트나 형식은 검사하지 않는다.
7. 설정 파일:
   - DB 유무와 관계없이 `PIONEER/`의 `MYSETTING.DAT`, `MYSETTING2.DAT`, `DJMMYSETTING.DAT`, `DEVSETTING.DAT`만 고정 이름으로 확인한다. 폴더를 훑지 않는다.
   - 기존 `DeviceSettingFile`(§6)로 크기, 길이, 끝 칸, CRC를 검증한다. 파일별 상태와 첫 실패 code만 낸다.
   - 종류별 크기가 맞아야 한다. 읽을 수 있을 때만 CRC 일치를 적는다. 설정 칸의 뜻은 추측하지 않는다.
   - 없는 파일은 정상이다. 손상된 파일과 읽을 수 없는 파일에는 경고를 낸다.
   - `UsbRoot`가 거부하는 경로와 링크는 열지 않는다.
8. 이 Mac의 rekordbox 버전이 확인한 버전인지 본다(`RekordboxCompatibility.verifiedAppVersions`).

경고 code는 다음과 같다.

`pdbOpenFlag`, `unknownTableRows`, `pdbStructure`, `pdbRoundTripFailed`, `deviceLibraryUnreadable`, `oneLibrarySidecar`, `oneLibraryUnsupported`, `oneLibraryUnreadable`, `formatMismatch`, `analysisMissing`, `analysisPathMismatch`, `mediaMissing`, `settingsInvalid`.

다음 둘은 수로만 적는다. 경고는 내지 않는다.

- 곡마다 파일 번호가 0이 아닌 것
- 두 형식의 항목만 다른 재생 목록(rekordbox도 만드는 모양)

### 8.2 실험 도구

- `djc lab usb-diff <A> <B> --files --anlz`: 모델 비교(§2.6)에 더해 파일 트리와 분석 파일을 비교한다.
  - 파일 트리는 NFC 경로, 크기, SHA-256을 본다. macOS 파일, `._*`, 열지 않는 경로는 뺀다.
  - 분석 파일은 PPTH와 확장자로 짝지어 태그 목록과 태그 바이트를 비교한다.
  - 경로 대신 묶음 이름, 곡 id, 태그 이름, 수만 찍는다. 묶음은 DB, 설정, USBANLZ, Artwork, Contents다.
  - `--ignore-anlz-folder`면 파일 트리에서도 USBANLZ 파일을 (PPTH, 확장자)로 짝짓는다.
  - 한쪽에 같은 (PPTH, 확장자) 파일이 여럿일 수 있다. 예를 들어 같은 곡의 분석 파일을 다른 폴더에 한 벌 더 둔 사본이 그렇다. 이 파일은 모두 비교한다. 버리지 않는다. "PPTH 겹침"으로 따로 센다.
  - "n/N 바이트 같음"의 N은 한쪽의 모든 분석 파일 수다. 큰 쪽 값을 쓴다.
  - `--mtime`이면 내용이 같은 파일의 수정 시각도 FAT 단위(2초로 내림)로 비교해 묶음별로 센다.
  - PPTH를 읽지 못한 분석 파일은 A·B 쪽별로 파일마다 "비교 불가(PPTH 못 읽음)" 차이 한 건으로 센다. 양쪽 모두 읽지 못해도 일치를 확인한 것이 아니므로 "차이 0"을 보고하지 않는다.
- `djc lab usb-rebuild <USB 폴더> <출력 폴더>`: USB의 두 형식을 사본으로 떠서 합쳐 읽는다. 합친 모델로 DB 셋만 새 내보내기 모양(`OneLibraryWriter.create`, `PdbWriter` fresh)으로 다시 만든다. 음원과 분석 파일은 복사하지 않는다.
  - `djc lab usb-diff <USB> <출력> --ignore-ids`가 "차이 0"이면 읽기 → 쓰기가 모델을 잃지 않은 것이다.
  - 입력과 출력은 임시 폴더 아래만 쓴다. 출력 폴더는 비어 있어야 한다. 없어도 된다.
- `djc lab usb-migrate-check <USB 폴더> [--ignore-ids]`: 두 형식이 다 있는 USB(골든 사본 등)를 쓴다. 그 USB의 Device Library를 옮기기 변환(§8.4)으로 OneLibrary 모델로 만들어, 그 USB의 OneLibrary와 표·칸 단위로 비교한다. 찍는 것은 수와 칸 이름뿐이다. USB에는 쓰지 않는다. 입력은 임시 폴더 아래만 쓴다.
- `djc lab usb-anlz-relocate <USB 사본> --track <id> --folder <P???/????????> [--db-only|--files-only|--decoy-slot0|--cue-variant]`: 기기가 분석 파일을 DB 경로로 찾는지 확인하려고 한 곡을 일부러 어긋나게 만든다. 이 도구는 다음을 지킨다.
  - Mac 데이터 볼륨의 임시 폴더 아래 **사본 폴더**에만 쓴다.
  - 다음은 거부한다. 마운트한 볼륨의 맨 위, 그 안 폴더, 링크, 임시 폴더 밖, rekordbox 실행 중.
  - pdb 분석 경로는 같은 길이 문자열로 제자리 교체한다. 길이가 다르면 거부한다.
  - OneLibrary는 `UPDATE` 뒤 `wal_checkpoint(TRUNCATE)`로 사이드카를 남기지 않는다.
  - 모든 확인을 먼저 한다. 하나라도 걸리면 아무것도 바꾸지 않는다.
  - 기본과 `--db-only`: 파일을 새 폴더로 옮긴다. 두 DB 경로도 옮긴다.
  - `--files-only`: 파일은 그대로 둔다. 두 DB 경로만 같은 길이의 없는 폴더로 바꾼다.
  - `--cue-variant`: 새 폴더에 파일을 복사한다. 그쪽 `.DAT`의 핫큐 A 위치만 바꾼다. 인코더로 원래 핫큐 목록을 다시 만든 바이트가 원본과 같을 때만 바꾼다. DB는 새 폴더를 가리킨다.
  - `--decoy-slot0`(`--folder` 없음): 원래 폴더의 `ANLZ0000`은 PPTH만 바꾼 가짜다. 진짜는 `ANLZ0001`이고, DB는 `ANLZ0001.DAT`를 가리킨다.
- `djc lab usb-fields <USB 폴더> --out <파일.json>`: 두 리더가 읽은 모델을 JSON에 쓴다.
  - 형식마다 표, 행, 칸 해시를 쓴다.
  - Device Library 구조는 숫자로 쓴다. 파일 머리, 표 포인터, 쪽 사슬, 쪽 머리 칸, 산 행 오프셋이 해당한다.
  - 해시는 정규형의 SHA-256 앞 16자다.
  - 정규형은 다음과 같다.

    - 글자: `s:<값>`(NFC로 바꾸지 않음)
    - 정수: `i:<10진>`
    - 없음: `n`
    - 참거짓: `b:1|0`
    - 목록: `l:<a,b,…>`
    - 형식: `e:<이름>`
  - 글자 값은 파일과 출력에 남기지 않는다.
  - 입력과 출력은 임시 폴더 아래만 쓴다. 출력은 새 파일이어야 한다.
- **외부 파서 대조(#189)**: `scripts/usb-parser-compare.py`가 같은 USB를 rekordcrate와 pyrekordbox로 읽는다.
  - rekordcrate는 Device Library용이고 라이선스는 MPL-2.0이다. pyrekordbox는 OneLibrary용이고 라이선스는 MIT다.
  - 두 파서로 읽은 값을 같은 정규형으로 해시해 `usb-fields` 결과와 견준다.
  - 외부 코드는 저장소에 넣지 않는다. 임시 폴더에 받아 돌린다.
  - 2026-10-03 대조는 rekordcrate `14d54ed`와 Rust 1.98, pyrekordbox `5feacbc`로 했다.
  ```sh
  W=$(mktemp -d)
  git clone https://github.com/Holzhaus/rekordcrate $W/rekordcrate && git -C $W/rekordcrate checkout 14d54ed
  # rustup을 RUSTUP_HOME·CARGO_HOME=$W 아래로 깔고(--no-modify-path) $W/rekordcrate에서 cargo build --release --locked
  git clone https://github.com/dylanljones/pyrekordbox $W/pyrekordbox && git -C $W/pyrekordbox checkout 5feacbc
  uv venv -p 3.12 $W/venv && VIRTUAL_ENV=$W/venv uv pip install $W/pyrekordbox
  DJC_USB_PARSER_FIXTURE=$W/fx scripts/check.sh --quick --filter UsbParserFixtureCapture   # 합성 USB: basic·hard·fartag·written
  DJC_HOME=$(mktemp -d) DJC_REKORDBOX_DIR=$(mktemp -d) .build/debug/djc lab usb-fields $W/fx/hard --out $W/hard.json
  $W/venv/bin/python scripts/usb-parser-compare.py --djc $W/hard.json --usb $W/fx/hard --rekordcrate $W/rekordcrate/target/release/rekordcrate
  ```
  - 출력은 표마다 행 수, 짝지은 행, 비교한 칸, 다른 칸 이름과 수다. 차이 위치도 낸다. 위치는 형식, 표, 행 키, 칸이다. 마지막 줄은 "차이 N"이다.
  - 종료 코드는 다음과 같다.

    | 코드 | 뜻 |
    |---|---|
    | 0 | 차이 없음 |
    | 1 | 차이 있음, 또는 행이 있는데 비교한 칸이 0인 표 |
    | 2 | 준비 실패 |

  - `--rekordcrate`가 없으면 `--only ol`을 줘야 한다.
  - 개인 골든은 `PIONEER/rekordbox`의 DB 셋만 임시 폴더로 복사한다. `--no-keys`로 돌린다. 이 옵션은 행 키를 찍지 않는다. 결과는 표마다 차이 수만 적는다.
  - 범위, Device Library: 쪽 구조 전부를 견준다.
    - rekordcrate가 해석하는 표는 칸을 견준다. 해당 표는 export 0–8, 11, 12, 13, 16, 17, 19와 exportExt 3, 4다.
    - 해석하지 않는 표는 행 수만 견준다. 해당 표는 export 18 sort와 exportExt 7이다.
  - 범위, OneLibrary: 모델에 담는 표는 칸을 견준다. 담지 않는 표는 행 수를 견준다. cue 표가 그 예다. pyrekordbox 모델 칸과 고정 스키마도 견준다.
  - DJCrate가 §2.5·§3.5대로 하는 변환은 외부 쪽에 같게 적용한다. 그 칸은 따로 찍는다. 이것은 독립 확인이 아니다. 변환은 다음과 같다.
    - 0·NULL → 없음
    - "ON" → 참
    - U+FFFA·U+FFFB 떼기
    - NULL 글자 → ""
  - 날짜 세 칸은 pyrekordbox가 datetime으로 바꾸므로, 같은 연결에서 원래 글자로 읽는다.
  - 알려진 외부 파서 쪽 차이가 있다. DJCrate는 그대로 둔다.
    - rekordcrate는 0x90 글자의 다섯째 바이트가 0x03이면 칸과 상관없이 ISRC 특수형으로 읽는다. 그래서 七(U+4E03)처럼 아래 바이트가 3인 글자로 시작하는 UTF-16을 깨뜨린다. ISRC 특수형은 트랙 문자열 0만이다(§3.4).
    - pyrekordbox는 playlist_content를 (playlist_id, content_id) 기본 키로 매핑한다. 한 목록에 같은 곡이 두 번 들면 ORM이 행을 합친다. 비교기는 같은 연결의 원래 행으로 항목을 한 번 더 견준다.
    - pyrekordbox 모델의 cue `outFileOffsetInBlock`은 스키마 `OutFileOffsetInBlock`과 대소문자만 다르다.
    - rekordcrate는 트랙 문자열 10·15를 date_added·analyze_date로 부른다. 값은 번호로 견줘 같다.

### 8.3 수정(`UsbEditSession`, `UsbEditEngine`, `djc usb-edit`)

이미 라이브러리가 있는 USB에 곡 더하기, 곡 빼기, 곡 갱신과 재생 목록 편집 8종을 쓴다. 편집은 초안으로 쌓는다. 편집 파일로 줘도 된다. 초안은 `usb-drafts/<볼륨 UUID>.json`에 둔다. 초안은 만든 때의 USB DB 지문 `base`를 들고 있다. 반영 때 한 번에 쓴다.

명령과 편집 JSON 모양은 `docs/cli.md`의 "USB 수정"에 있다.

**순서**(세션):

1. 원본을 확인한다. 라이브 master.db는 거부한다.
2. 볼륨을 확인한다. 수정 목적의 볼륨 정책, 보호 폴더, 실물 관문을 본다. 막히면 USB를 열거하지 않는다.
3. 저널을 본다. 닫히지 않은 쓰기는 `recoveryNeeded`다. 닫힌 저널에서 ID highWater를 이어 받는다.
4. USB DB 사본(`UsbSnapshot`)을 뜬다. 남은 `-wal`과 hot `-journal`은 사본에서 합친다.
5. USB DB 사본을 읽어 합친다.
6. 곡 더하기, 곡 갱신, 목록 동기화가 있으면 세션 전용 로컬 사본(`usb-snapshots/local-<세션>/`)을 만든다. 받은 사본에서 `force`로 만든다. 끝나면 지운다.
7. 계획과 준비를 한다(`UsbEditEngine.plan`).
8. 확인 안 된 규칙을 본다.
9. `UsbWriter.write`로 쓴다. 검사기는 `UsbEditInspector`다. 검증기는 목표 지문, 쓴 형식의 모델, 불변식을 본다.

초안의 base가 지금과 다르면 지금 USB 상태로 계획한다. 이때 "USB가 그 사이 바뀌어 다시 계획했습니다"를 알린다. 회복이 `needsReplan`으로 닫은 볼륨도 같다. 옛 계획을 그대로 쓰는 길은 없다.

**USB 전체 막힘**(모든 편집을 막는다):

- 곡이 한 형식에만 있다. 같은 id가 다른 파일을 가리켜도 막는다(`formatTrackMismatch`).
- 맨 위에서 닿지 않는 재생 목록이 있다(`formatPlaylistConflict`).
  - 부모가 없다. 고리여도 그렇다. 그래서 대표 번호와 부모를 정할 수 없다.
  - 번호만 다른 같은 목록은 §2.6대로 짝지어 막지 않는다(#233). 같은 번호의 다른 목록도 마찬가지다.
- 사본 무결성 검사나 암호 검사가 실패한다. pdb를 읽지 못해도 막는다(`libraryCorrupt`).
- OneLibrary 호환 검사가 실패했다(`oneLibraryUnsupported`).
- 볼륨 정책에 걸린다. APFS와 HFS+ 등은 "이 USB 형식(…)에는 rekordbox 라이브러리를 쓸 수 없습니다"로 막는다.

고칠 수 있는 형식이 하나도 없으면 그 형식 막힘으로 멈춘다. 예를 들어 Device Library만 있고 그 형식이 막힌 경우가 있다.

**Device Library만 막힘**:

그 형식은 그대로 둔다. OneLibrary는 쓴다.

- 두 pdb 머리 0x10이 5가 아니다(`pdbNotClosed`). rekordbox에 연결했다가 정상으로 꺼내면 풀린다.
- 기기 기록이나 모르는 표에 산 행이 있다(`carriedDeviceRows`). 대상 표는 export 9, 10, 11, 12, 14, 15와 exportExt 0, 1, 2, 5, 6, 8이다.
- 왕복 검사(`PdbRoundTrip.check`)가 실패한다(`pdbRoundTripFailed`). 구조 문제와 My Tag 연결도 검사에 든다. 첫 문제를 적는다.

USB에 이미 있는 기기 행을 새 파일로 옮기는 일은 아직 하지 않는다. 그래서 그 USB의 Device Library 편집을 막는다. ANLZ 태그를 바이트 그대로 옮기는 것은 다르다. rekordbox 자신의 내보내기와 같은 동작을 골든으로 확인했기 때문이다. 기기 행은 뜻을 모른다.

한 형식이 막힌 채 곡을 빼면 그 형식은 곡을 아직 가리킨다. 그래서 파일 지우기를 미룬다(`deferred`). 다음 USB 읽기에서 두 형식 곡이 달라 편집이 막힌다. rekordbox에서 다시 내보내 푼다.

재생 목록의 이름과 부모는 합친 모델에 한 값만 있다. 한 형식이 막힌 채 두 형식에 있는 목록의 이름이나 폴더를 바꾸면, 같은 목록이 형식마다 달라진다. 그러면 다음 읽기부터 짝을 잃는다. 두 목록으로 보인다. 그래서 그 편집은 막는다(`playlistInBlockedFormat`). 순서와 항목은 형식마다 따로라 막지 않는다.

**연산별**: 편집 하나가 막히면 그 편집만 뺀다. 나머지는 쓴다. 대상이 없으면 `targetMissing`이다.

- 곡 빼기(`editRemoveTracks`):
  - 기기 재생 기록이 가리키는 곡은 막는다(`historyReferenced`). 기록은 OneLibrary `history_content`와 pdb 표 12다.
  - 남는 곡이 0이 되는 형식이 있으면 막는다(`lastTrack`).
  - 빼는 행은 다음과 같다.
    - content(두 형식)
    - 모든 목록 항목. 형식마다 그 목록의 항목에서 뺀다. 남은 항목은 1..N으로 다시 매긴다.
    - My Tag 연결
  - 새로 고아가 된 artist, album, genre, key, label, image 행을 치운다. 색, 메뉴, 카테고리, 정렬, My Tag 정의는 USB 값 그대로 둔다.
  - 곡 수 칸을 고친다. 지운 id는 다시 쓰지 않는다(저널 highWater).
  - OneLibrary 단계에서 기기 큐나 추천 행이 그 곡을 가리키면 그 편집만 되돌린다.
- 곡 갱신(`editRefreshTracks`). 부분 갱신은 `info`, `cues`, `grid`, `artwork`다.
  - 곡마다 판정해 막힌 곡만 뺀다(`trackBlocks`). 그 곡을 보며 준비한 파일, 이름, 번호도 되돌린다. 이것은 막힌 곡에 한한다. 요청한 곡이 모두 막혔을 때만 편집을 막는다.
  - 로컬 짝은 `UsbTrackMatch`가 찾는다. 조건은 다음과 같다.
    - 이 곡을 내보낸 라이브러리의 DB ID가 같다. `masterDbId`이고 pdb 트랙 0x18이다.
    - 곡 ID가 같다. `masterContentId`이고 `MasterSongID`, pdb 트랙 0x14다.
    - USB 경로 끝 성분이 아래 셋 중 하나다.
      - 그 곡의 원본 이름 그대로. 음원 경로 끝 성분과 `FileNameL`이다.
      - 내보내기 이름 규칙으로 지은 이름. §5 금지 글자와 자르기를 따른다. 2026-10-09 전 규칙도 포함한다.
      - 위 이름에 번호(` (2)`…` (99)`)를 붙인 이름
    - 위 조건에 맞는 로컬 곡이 하나다.
  - 이름 비교는 FAT처럼 대소문자와 NFC/NFD를 무시한다. 그대로 맞는 곡이 번호로 맞는 곡보다 앞선다.
  - 아티스트·앨범 폴더 성분은 보지 않는다. 로컬에서 이름을 바꾼 곡도 갱신할 수 있게 하려는 것이다.
  - 짝이 없으면 막는다. 둘 이상이어도 막는다.
  - `UsbSyncStatus`는 다음과 같이 판정한다.
    - 기기에서 고친 곡은 통째로 건너뛴다. 건너뛴 것은 알린다. OneLibrary hasModified = 1이거나 기기 큐 행이 있는 곡이다.
    - 로컬과 같으면 `unchanged`다.
  - 로컬 음원의 크기나 SHA-1이 USB 파일과 다르면 막는다(`audioChanged`). 음원은 다시 쓰지 않는다.
  - 비교는 로컬 실제 파일과 USB 파일끼리 한다. 그래서 분석 뒤 바뀐 음원을 그대로 복사한 곡은 막지 않는다. DJCrate와 rekordbox 모두 지금 파일을 복사한다(§5). 이 곡의 파일 크기 칸도 USB 값 그대로 둔다.
  - 내보낸 뒤 로컬 음원이 또 바뀐 곡을 rekordbox 동기화가 USB에 다시 복사하는지는 골든에 없다. 실험 곡들의 로컬 음원은 그동안 바뀌지 않았다. 그래서 이 막힘을 그대로 둔다(2026-10-09).
  - 기존 곡의 음원·분석 파일 경로는 바꾸지 않는다. 아티스트 이름이 바뀌어도 같다.
  - `info`: 곡 정보 칸을 로컬 값으로 바꾼다. 평점, 재생 수, hasModified, 기록은 USB 값 그대로다.
    - 이름이 바뀐 아티스트, 앨범, 장르, 키, 레이블은 USB에 NFC로 정확히 같은 이름 행이 있으면 그 행을 쓴다. 없으면 새 id를 쓴다.
    - 고아가 된 옛 행은 치운다.
  - `cues`·`grid`: 로컬 분석 파일과 djmdCue를 §4처럼 바꿔 DB에 적힌 자리의 셋을 덮어쓴다. 폴더와 번호는 그대로다.
    - 덮어쓸 USB 파일의 PPTH가 그 곡 경로여야 한다.
    - 아니면 그 곡 분석 파일은 고치지 않는다. 고치지 않은 것은 알린다. 큐·그리드 갱신 횟수 칸도 USB 값 그대로 둔다. DB만 최신이라고 적으면 다음 갱신이 고치지 않기 때문이다.
    - 분석 파일을 고쳤을 때나 이미 같을 때는 갱신 횟수 칸도 로컬 값으로 한다.
    - 스냅샷 시각 뒤에 로컬 분석 파일이 바뀐 곡은 막는다(`analysisNewerThanSnapshot`).
  - `artwork`: 로컬 그림이 바뀌었으면 같은 image id와 폴더의 a·b·_m을 덮어쓴다. a는 Device Library용이고 b는 OneLibrary용이다.
    - 덮어쓸 자리는 USB DB에 적힌 경로다. 그래서 아트워크 파일 모양이 아니면 그 곡을 막는다(`artworkPathRefused`). 모양은 `PIONEER/Artwork/nnnnn/[ab]n(_m).jpg`이고 `..`과 `._`는 없다.
    - 그림이 새로 생긴 곡이나 다른 곡과 함께 쓰던 그림은 새 image id를 마지막 아트워크 폴더에 이어 둔다.
  - Device Library를 쓰면 바뀐 곡의 트랙 행을 미리 만들어 본다. 행 크기, 확장자, ISRC, 칸 범위, 긴 이름을 본다. 곡 막힘 code는 §7.12와 같다.
- 곡 더하기(`editAddTracks`):
  - 내보내기 계획기(`UsbExportPlanner`)에 지금 USB 상태(`UsbExistingState`)를 준다. `UsbLibraryBuilder.add`로 더한다. 이름 행은 NFC로 같은 이름이면 다시 쓴다 [추정].
  - `UsbExistingState`에는 다음이 든다.
    - `Contents/` 이름과 철자
    - ID highWater
    - 아트워크 폴더 사용량과 마지막 폴더
    - 새 곡 번호 범위의 분석 폴더 번호와 PPTH
  - 분석 폴더는 `IdentifierAnalysisNaming`과 `UsbAnalysisSlot`으로 정한다. PPTH가 다른 파일이 있으면 다음 번호를 쓴다(`analysisSlotCollision`).
  - 곡 단위 막힘(§7.12의 5)에 걸린 곡은 뺀다. 이미 USB에 있는 곡(`alreadyOnUsb`)도 뺀다. 나머지를 더한다.
  - 분석 뒤 크기가 바뀐 음원은 내보내기와 같이 더한다. 이때 `audioChangedSinceAnalysis`를 싣는다(§5). 검증은 `UsbEditResult.audioSizeFromDatabase`의 곡을 ④ 크기 비교에서 뺀다.
  - `playlist`를 주면 그 목록 끝에 넣는다. 항목 편집 규칙을 따른다.
- 재생 목록(`editPlaylists`): 아래 두 형식 목록 규칙을 따른다. 만들기는 `playlistSiblingBase`, 폴더면 `playlistFolderRow`다.
- 긴 ASCII: 127자 이상 순수 ASCII다. Device Library에 쓸 때 다룬다.
  - 편집이 만들거나 바꾸는 pdb 문자열 중 긴 ASCII를 본 적 없는 칸은 `UsbTrackRules.pdbStringRules`로 본다. 해당 칸은 갱신한 곡의 장르·키·레이블 이름과 목록 이름이다.
  - 작성기 규칙(`PdbFiles.rules`)을 한 번 더 합친다. 편집하지 않은 기존 행도 포함한다(§3.8). 싣는 code는 `pdbLongAscii`와 `pdbFarOffsetRows`다.
  - 곡 문자열, 경로, 아티스트 이름, 앨범 이름의 긴 ASCII는 확인한 모양이라 싣지 않는다.

**두 형식 목록 규칙**:

- 편집하지 않은 목록은 형식마다 있던 그대로 다시 쓴다. 항목이 다른 목록을 맞추지 않는다. 알림은 "형식 사이 목록 불일치 N"이다.
- 만들기:
  - 새 id는 두 형식 모두에서 가장 큰 값 + 1이다. 지난 쓰기 highWater를 포함한다.
  - 목록이 있는 형식은 USB에 있는 형식이다. 이번에 막히지 않아야 한다. 부모 폴더가 있는 형식이다.
  - 형제 순번은 그 부모의 형제 가장 큰 값 + 1이다. 시작값 0·1을 그대로 따른다. 형제가 없으면 0이다.
  - 순서 바꾸기는 형제의 시작값에서 다시 매긴다.
- 이름 바꾸기, 옮기기, 순서 바꾸기, 지우기: 그 목록이 있는 형식에 한다. 막힌 형식은 뺀다. 폴더를 지우면 안까지 지운다.
  - 이름·부모 바꾸기는 목록이 막힌 형식에도 있으면 막는다(`playlistInBlockedFormat`, 위).
  - 옮기기는 새 부모의 맨 끝으로 한다.
  - 자기 안으로 옮기기와 목록 안에 넣기는 막는다.
- 곡 넣기, 빼기, 옮기기 같은 항목 편집은 목록이 있는 형식의 항목이 모두 같은 목록만 다룬다. 두 형식에 같은 결과로 쓴다. 항목이 다르면 `playlistEntriesDiffer`다.
- `trackNo`는 1부터 센 자리다. `contentID`는 그 자리의 USB 곡이다. 둘이 다르면 막는다.
- 고친 목록의 OneLibrary `playlist_content`는 그 목록 행을 지우고 1..N으로 다시 넣는다.
- 한 형식에만 있는 목록·기록은 다른 형식에 만들지 않는다.

**쓰기**:

- OneLibrary는 준비 폴더의 USB DB 사본에 편집마다 한 단계를 적용한다. 이 일은 `OneLibraryWriter.apply`가 하고 각 단계는 SAVEPOINT다. SQL이 실패한 편집은 그 단계만 되돌리고 `applyFailed`로 막는다.
- 단계는 계획 때 id까지 정한 편집을 받은 모델에 다시 적용한다. 앞 편집을 건너뛰어 대상이나 행 같은 전제가 없으면 그 편집도 건너뛴다.
- Device Library는 적용 결과 모델 `r.applied`에서 새로 만든다. 순서는 다음과 같다.
  1. `PdbWriter.files(.edit(옛 머리 순번))`로 파일을 만든다.
  2. `PdbRoundTrip.check`로 검사한다.
  3. 다시 읽은 모델이 작성기 모델 `PdbFiles.written`과 같은지 본다.
- 그래서 두 형식에는 같은 편집 집합만 들어간다. 모델이 바뀌지 않은 형식은 다시 쓰지 않는다.
- 모델 비교는 NFC와 NFD를 같다고 보므로 철자를 따로 본다(#233).
  - OneLibrary는 같은 번호 목록의 이름 철자가 바뀌었으면 쓴다. 이 판정은 `UsbEditModel.playlistNamesRespelled`가 하고, 행 갱신도 철자로 본다.
  - Device Library는 USB의 pdb에 NFC가 아닌 이름이나 제목이 있으면 모델이 같아도 다시 만든다. 이 판정은 `UsbEditSource.deviceLibraryNeedsNFC`가 하고, 읽을 때 `PdbWriter.needsNFC`를 쓴다.
  - 그래서 rekordbox가 NFD로 쓴 USB는 다음 쓰기에서 Device Library를 NFC로 고친다. 동기화는 선택 파일을 늘 쓰므로 다음 동기화가 그 쓰기다. 고친 뒤에는 다시 만들 까닭이 없다.
  - 목록 이름 바꾸기는 OneLibrary에 있는 목록이면 철자로 비교한다. Device Library에만 있는 목록이면 정규형으로 비교한다. 이 비교는 `UsbNameSpelling.playlistNeedsRename`이 하고, 동기화 계획 `UsbSyncPlan`도 같다.
  - Device Library는 늘 NFC로 쓴다. 이 규칙은 NFD 로컬 이름이 동기화마다 바뀐 것으로 보이지 않게 한다.
- 변경 묶음은 다음과 같다.
  - `purpose .edit`이다.
  - `base`는 사본 지문이다.
  - ID highWater를 싣는다.
  - 확인 안 된 규칙은 연산 규칙, 곡 규칙, 분석 파일 규칙, 작성기 규칙의 합집합이다.
  - 합집합에 `pdbRegeneratedEdit`를 더한다. pdb를 쓸 때만 더한다.
  - 합집합에 `trackRemovalFiles`를 더한다. 지울 파일이 있을 때만 더한다.
- `UsbEditInspector`는 A 단계에서 한 번 더 본다.
  - 수정은 있던 DB만 바꾼다(`editCreatesDatabase`).
  - pdb를 바꾸면 두 pdb 머리 0x10 = 5다.
- 검증(G)은 세 가지를 본다.
  - 목표 지문: 쓴 파일은 있고 지운 파일은 없다(`mustNotExist`). 쓰기가 건너뛴 지우기는 뺀다.
  - 쓴 형식의 모델.
  - 불변식 1–7.
- 불변식 검사는 편집이 건드리지 않은 곡까지 USB 전체를 본다. 그래서 계획 때 USB에 이미 있던 문제는 세지 않고, 이번 쓰기가 새로 만든 문제만 센다. 이미 있던 문제는 `preexistingProblems`이고 곡·그림 id와 형식으로 적은 글이다. 예는 번호가 엉킨 분석 파일과 없는 음원이다.

**파일 지우기**:

- 지울 파일은 편집 전 참조에서 편집 뒤 참조를 뺀 것이다.
- 참조는 두 형식의 합집합이다. 막혀서 안 고친 형식의 참조도 넣는다.
- 참조는 음원 경로, 분석 파일 `.DAT`와 형제 `.EXT`·`.2EX`, 아트워크 그림과 `_m`이다.
- 한 형식이 막혀 있으면 모두 미룬다. 같은 음원을 다른 곡이 가리키면 지우지 않는다.
- 계획에는 USB 실파일의 크기와 SHA-256을 적는다. 사본이 아니라 USB 파일을 읽는다.
- 분석 파일은 셋의 PPTH가 그 곡일 때만 넣는다. 아니면 셋 모두 남기고 "분석 파일이 다른 곡 것이라 지우지 않았습니다"라고 알린다.
- 음원은 로컬 원본의 크기와 SHA-1이 같을 때만 넣는다. 되돌릴 때 원본에서 다시 복사한다. 같지 않으면 남기고 알린다.
- 로컬 사본은 곡 더하기, 갱신, 목록 동기화가 있을 때만 뜬다. 곡 빼기나 일반 목록 편집만 있는 묶음은 `--db`를 주어도 음원을 USB에 남기고 알린다.
- 그림은 아트워크 파일 모양일 때만 지운다.
- 다음 파일은 지우지 않는다.
  - 허용 목록 `UsbRemovalPolicy` 밖의 파일.
  - 기기 파일: 다른 곡 PPTH의 분석 파일, `USBMNG.DAT`, `RBFLTR.DAT`, `log/`, `export.pdb.bak`.
  - 모르는 파일.
- 쓰기 절차의 F 단계가 같은 조건을 다시 본다(§7).

**표별 출처**:

- 보존할 것은 USB 값 그대로 둔다.
  - 메뉴, 카테고리, 정렬, 색.
  - My Tag 정의.
  - property의 createdDate, myTagMasterDBID, deviceName, backGroundColorType.
  - pdb 표 19 날짜.
  - 기기 행: 기록, 큐, 추천, 핫큐 뱅크.
  - 곡의 기기 칸: 평점, 재생 수, hasModified.
- 한 형식에만 있는 칸은 지우지 않는다. 합친 모델이 pdb 전용 칸을 pdb 값으로 들고 있고, 편집은 그 값을 그대로 넘긴다. 편집한 곡의 `info` 갱신만 로컬 값을 쓴다.
- pdb 전용 칸은 작사가 글자, 카테고리 InfoOrder·Disable, 정렬 Disable, 표 19 날짜, 트랙 행 관찰값이다.
- 표 19의 두 번째 문자열은 작성기가 늘 비워 쓴다. 그래서 값이 있는 USB는 왕복 검사가 Device Library를 막는다(`pdbRoundTripFailed`). 이 값은 보존하지 않는다.
- OneLibrary 전용 칸은 고치지 않는 칸이라 USB 값 그대로다. 칸은 titleForSearch, artist·album nameForSearch, album, playlist image_id 등이다.
- 갱신하는 칸은 곡 수 칸뿐이다. property.numberOfContents와 표 19가 그것이다.

**불변식 8**(형식마다): 편집 결과 USB를 읽은 모델은 편집 뒤 모델을 새로 내보낸 모델과 같다.

- 예외는 ID, 보존한 행·표, pdb 순번, 기존 곡 파일 경로다.
- `djc lab usb-rebuild`와 `djc lab usb-diff --ignore-ids`로 본다. 차이는 0이다.
- 시험은 `UsbEditInvariantTests`다.

앱의 **초안 화면과 끌어 놓기**(#240)는 아래와 같다.

- USB 재생 목록 줄은 쓰기 전 초안의 항목 편집을 계획처럼 차례로 적용한 순서로 보인다(`UsbDraftProjection`). 항목 편집은 목록에 곡 넣기·빼기·옮기기와 USB에서 곡 빼기다.
- 쓰기 전에는 곡 번호와 결과를 모르는 편집이 있다. 로컬 곡 넣기와 목록 동기화다. 이 편집이나 목록 지우기가 닿은 목록은 읽은 그대로 보인다. 그 목록은 끌어서 순서를 바꾸지 않는다.
- 목록에서 빼기와 끌어 옮기기의 `trackNo`는 이 순서로 정한다. 미리 막힘 판정(`UsbEditRules.blockReason`)도 이 순서를 본다. 쓰기 대기 목록은 편집마다 그 앞 편집까지 얹은 목록으로 판정한다.
- 줄 ID는 곡과 그 곡의 몇 번째 출현이다. 그래서 순서를 바꿔도 선택이 곡을 따라간다.
- 곡 목록은 USB 곡을 `com.djcrate.usb-track-ids` 형식으로만 싣는다. 값은 볼륨키·content_id·목록 자리의 JSON이고, 줄마다 한 항목이다. 이 형식은 덱·로컬 목록·앱 밖에 놓이지 않는다.
- 같은 USB의 일반 목록에 놓으면 `playlist.addTracks`가 된다. 초안을 얹은 목록에 이미 든 곡은 뺀다(`UsbEditRules.tracksToAdd`).
- 보고 있는 목록 안에 놓으면 `playlist.moveTracks`가 된다(`UsbEditRules.moveEntriesEdit`).
- 로컬 곡은 `com.djcrate.track-ids` 형식으로 USB 컬렉션·일반 목록에 놓는다. 놓으면 `addTracks`가 된다.
- 두 형식은 `Info.plist`에 선언한다. 곡 목록 표는 AppKit이고 사이드바는 SwiftUI다. 표가 실은 형식을 사이드바가 받으려면 LaunchServices에 등록된 형식이어야 한다. 선언 전에는 로컬 곡이 파일 URL로만 들어가 USB 줄에 놓이지 않았다.
- 끌어 놓아 더한 편집은 편집 › 실행 취소로 뺀다. 초안 끝의 그 편집만 뺀다. 뒤에 다른 편집이 쌓였으면 빼지 않고 알린다.
- 쓰기는 늘 쓰기 대기의 미리 보기 → 확인 → `UsbWriter.write`다.

앱의 **USB 동기화**는 위 편집 경로를 재사용한다. `UsbSyncPlan`이 선택한 로컬 트리를 보고 다음 일을 초안으로 만든다.

- 폴더와 목록 만들기.
- 이은 목록끼리 순서 맞추기.
- 없는 곡 더하기.
- 로컬 변경 갱신.

USB 목록의 지우기, 옮기기, 새로 만들기는 rekordbox를 따른다(아래 #233).

- 지난 선택 파일 행으로 이었던 USB 목록은 원본을 선택에서 빼거나 로컬에서 지우면 지운다.
- 이름이 바뀐 원본은 새 USB 목록을 만들고 옛 목록을 연결 없이 남긴다. 이름이 바뀐 폴더는 하위 목록까지 새로 만든다.
- 옮긴 원본은 이은 목록을 새 자리로 옮긴다.

곡 빼기는 다음 순서로 한다.

- 동기화 뒤 어느 USB 목록에도 없는 곡은 확인 창을 거쳐 `removeTracks`로 뺀다. 재생 기록에 있는 곡은 넣지 않는다.
- 곡 빼기는 모든 형식에서 빼므로, 남는 곡은 목록이 있는 모든 형식의 항목을 합쳐 판정한다.
- 형식마다 항목이 다른 이은 목록의 지금 곡도 남긴다. 이런 목록은 곡 맞추기가 `playlistEntriesDiffer`로 막힐 수 있다.
- 곡 짝은 쓰기 계획과 같이 로컬 행의 `MasterDBID`와 `MasterSongID`로 찾는다. 이 라이브러리의 `djmdProperty.DBID`로 찾지 않는다. 다른 라이브러리에서 가져온 곡이 있기 때문이다.
- 빼면 곡이 하나도 남지 않는 형식이 생기면 곡 빼기만 하지 않는다. 목록 지우기와 선택 파일은 쓴 뒤 알린다. 예는 선택 전부 해제다.
- 곡 0개 라이브러리 모양은 확인하지 않아 쓰지 않는다(`lastTrack`).

선택 파일과 임시 사본은 다음과 같다.

- 선택 파일의 Timestamp는 스냅샷을 뜰 때 함께 복사한 `masterPlaylists6.xml`에서 읽는다. 그 파일 이름은 `master-….db.masterPlaylists6.xml`이다. 라이브 폴더의 XML은 읽지 않는다.
- SYNC가 여는 전용 DB 사본은 `UsbSyncSnapshotLease`이고 폴더는 `<pid>-<UUID>`다. 앱이 죽어서 남으면 다음 실행의 임시 파일 청소(#219)가 지운다. 주인 프로세스가 없는 것만 지운다.

`syncPlaylist`는 다음과 같이 움직인다.

- 로컬 ID를 기존 USB 짝이나 앞선 곡 더하기의 USB 번호로 푼다. 그 뒤 기존 `UsbEntriesChange`로 항목 전체를 맞춘다. 순서와 중복을 보존한다.
- USB에 짝이 없는 곡은 곡 더하기가 막힌 곡이다. rekordbox처럼 그 곡만 빼고 `syncTrackMissing` 곡 단위 막힘으로 알린다.
- 2026-10-08 실제 동기화에서 rekordbox는 분석 파일이 없는 곡을 내보내기 기록에 남기고 나머지를 동기화했다.
- 로컬 스냅샷에 없는 곡이나 짝이 모호한 곡은 목록 전체를 막는다.

선택 파일을 함께 쓰는 동기화 묶음은 다음과 같다.

- 더할 곡이 모두 막힌 곡 더하기도 건너뛴다.
- 곡 단위 막힘만 있으면 선택 파일까지 쓴다. 곡 단위 막힘은 `UsbBlock.isSkippableInSync`이고 `localTrackMissing`은 제외한다.
- 앱이 계획 전에 뺀 곡은 `UsbSyncSelectionDraft.skippedTracks`로 넘겨 확인 창과 결과에 함께 센다. 이런 곡은 잇지 못한 iTunes 곡, 스트리밍 곡, 추가 대기 곡이다. iTunes 곡은 경로 대신 해시로 적는다.
- 새로운 DB·분석 파일 형식을 만들지 않는다. 규칙은 `editPlaylists`이고 확인 목록을 넓히지 않는다.
- 이 편집도 세션 전용 로컬 사본이 필요하다.

**큐·그리드 가져오기**는 쓰기와 별개다.

- USB DB는 `UsbSnapshot` Mac 사본으로 읽는다. ANLZ는 `UsbRoot`로 경로, PPTH, 읽기 중 변경을 확인한다.
- `.EXT`의 PCO2를 먼저 읽고 `.DAT`·`.EXT`의 PCOB와 대조한다.
- 다음 큐가 있는 곡은 큐를 건너뛰고 알린다.
  - 큐 색.
  - 활성 루프.
  - 확장 정보 없는 루프.
  - OneLibrary의 미해석 기기 큐 행.
- 그리드는 독립으로 처리한다. 기존 초안, 형식 간 충돌, 초안 표현 손실을 확인한다. 형식 간 충돌은 두 형식의 갱신 횟수가 다른 경우다.
- 로컬 갱신 횟수가 더 커도 건너뛰지 않는다. 로컬이 더 새로워도 같다.
  - rekordbox의 "← CUE GRID INFO"는 확인 창(OK/취소)을 거친 뒤 돌았다. 장치 동기화가 꺼진 채로도 돌았다.
  - 로컬에서 메모리 큐를 하나 더한 곡의 큐를 USB의 큐로 되돌렸다(2026-10-08 실험 G5b).
- 평점·색·코멘트는 가져오지 않는다.
  - rekordbox 확인 창은 "트랙 정보(색상, 레이팅 및 코멘트)"도 적는다. <!-- prose: E3 -->
  - 7.2.19 실험 X1(2026-10-08, C1·C2)에서 USB에 평점 3, Red, 코멘트를 두었다. 로컬은 평점 5, Blue, 다른 코멘트로 바꾸고 메모리 큐를 하나 더했다.
  - 그 곡에 CUE GRID INFO를 하자 큐는 USB의 것으로 돌아갔다. 평점, 색, 코멘트는 로컬 값 그대로였다.
  - G5b에서는 USB 값이 비어 있어 가르지 못했다.
- 앱은 rekordbox 확인 문구를 초안 흐름에 맞게 고쳐 묻는다(`UsbSync.cueGridImportPrompt`).
- 로컬 초안만 저장한다. 로컬 rekordbox DB와 USB에는 쓰지 않는다.

**장치별 선택 XML(#233):** 로컬 iTunes 선택 파일인 `SYNC_ITUNES_PLAYLIST`와 다르다. 칸 규칙은 2026-10-08 rekordbox 7.2.x 실험으로 확인했다.

방법은 다음과 같다.

1. rekordbox 동기화 관리자에서 선택을 바꿔 SYNC한다. 바꾼 선택은 다음과 같다.
   - 새 폴더·목록 체크.
   - 하나만 해제.
   - 원본 이름 바꾸기.
   - 전부 해제.
   - "장치와 플레이리스트 동기화" 끄고 닫기.
   - 끈 채 다시 열기.
2. 단계마다 USB의 두 선택 파일과 DB를 사본으로 뜬다. 로컬 `master.db`와 `masterPlaylists6.xml`도 뜬다.
3. 사본을 칸 단위로 비교한다. 값은 적지 않는다.

모든 단계의 실제 파일을 아래 규칙으로 다시 만들었다. 바이트까지 같음을 사본으로 확인했다(`UsbSyncSelectionXML.render`).

- **모양**: rekordbox는 매번 파일 전체를 같은 모양으로 다시 쓴다.
  - 첫 줄은 `<?xml version="1.0" encoding="UTF-8"?>`이고 다음은 빈 줄이다.
  - `<Sync DBID AutomaticSync AllPlaylists IncludeCue ForcedSync Timestamp>`가 이어진다. 칸 순서가 이렇다.
  - 2칸 들여 `<Playlists>`를 쓴다.
  - 4칸 들여 `<NODE Id ParentId Attribute Lib_Type Dev_ID Timestamp CheckType/>`를 쓴다.
  - 이어서 `  </Playlists>`와 `</Sync>`를 쓴다.
  - 줄 끝은 모두 CRLF이고 마지막 줄도 같다. BOM은 없다.
  - 그래서 원문을 고쳐 쓰지 않고 칸 규칙대로 새로 만든다.
  - 이 모양 밖의 원문은 고쳐 쓰지 않고 막는다(`contractMismatch`). 모르는 칸·요소·주석과 줄 끝 차이가 그런 원문이다.
- **루트**:
  - `DBID`는 로컬 `djmdProperty.DBID`를 부호 있는 32비트 10진수로 적은 값이다. 음수일 수 있다. 읽을 때는 32비트 비트 모양으로 견준다.
  - `AutomaticSync`는 "장치와 플레이리스트 동기화" 체크 값이다.
  - `AllPlaylists`, `IncludeCue`, `ForcedSync`, `Timestamp`는 SYNC로 바뀌지 않는다. 원문 값을 그대로 둔다. `Timestamp`의 본 값은 늘 0이다.
- **행**:
  - `CheckType` 1인 체크한 목록과 `CheckType` 2인 부분 체크 폴더만 적는다. 해제한 목록은 행이 빠진다.
  - 라이브러리마다 뿌리 행이 있다. 값은 `Id`=0, `ParentId`=0, `Attribute`=1, `Dev_ID`=0, `Timestamp`=0, `CheckType` 1/2다.
  - 그 라이브러리에 체크한 것이 없으면 뿌리 행도 빠진다. 모두 해제하면 실험 전 바이트로 돌아갔다.
  - `Lib_Type` 0인 rekordbox 덩어리가 `Lib_Type` 1인 iTunes 덩어리보다 앞이다.
  - 덩어리 안은 트리 전위 순회다. 형제는 rekordbox 순서다. `masterPlaylists6.xml`의 줄 순서가 아니다.
  - 폴더를 체크하면 하위 목록도 모두 `CheckType` 1로 적는다.
- **원본 칸**:
  - `Id`, `ParentId`, `Attribute`, `Lib_Type`, `Timestamp`는 로컬 `masterPlaylists6.xml`의 같은 NODE 값 그대로다.
  - `Id`는 16진수 대문자다. rekordbox 목록은 `djmdPlaylist.ID`이고 iTunes 목록은 그 목록 ID다.
  - iTunes NODE의 `Timestamp`는 master에서도 0이다.
  - 원본 이름을 바꾸면 그 NODE의 `Timestamp`가 바뀐 master 값으로 바뀐다.
  - 앱은 rekordbox 폴더의 `masterPlaylists6.xml`을 읽기만 한다. 원본마다 `Timestamp`를 싣는다(`UsbSyncSourceNode.timestamp`).
  - 같은 `Id`·`ParentId`·`Attribute`의 NODE가 없는 목록을 체크해 쓰면 막는다. 안내 문구는 "rekordbox를 한 번 켰다가 종료…"다.
- **`Dev_ID`**: 그 형식 DB의 USB 재생 목록 ID(10진수)다.
  - 두 파일은 형식별이다. `playlists3.sync`는 Device Library이고 `playlists3Plus.sync`는 OneLibrary다.
  - 형식의 목록 ID가 다르면 두 파일도 다르다. 이름 바꾸기 단계에서 두 형식의 새 목록 번호가 달랐다.
  - 그 밖에는 두 파일이 바이트까지 같았다.
  - 읽을 때는 형식마다 그 형식 DB에 있는 번호인지 본다. 두 형식의 번호가 합친 모델의 같은 목록을 가리킬 때만 한 USB 목록에 잇는다. 같은 목록의 번호는 대표 번호다(§2.6, `UsbSyncSelectionBundle.representatives`).
  - 쓸 때는 형식마다 그 형식 번호를 `Dev_ID`로 쓴다. 초안과 저널의 참조는 대표 번호로 남긴다(`UsbSyncSelectionStage.resolve`).
- **동작**:
  - 변경 없는 SYNC는 선택 파일을 바꾸지 않는다. rekordbox 시작 때 자동 동기화도 같다.
  - 원본 이름을 바꾸면 rekordbox는 새 USB 목록(새 `Dev_ID`)을 만든다. 옛 목록은 지우지 않고 연결 없이 회색으로 남긴다.
  - 해제, 삭제, 옮기기는 아래 "정상 USB 실험"을 따른다.
  - 자동 동기화가 켜져 있으면 중간 이름도 목록으로 생겼다.
  - "장치와 플레이리스트 동기화"를 끄고 닫기만 해도 두 파일의 `AutomaticSync`만 0으로 쓴다. 다른 칸과 행은 그대로다.
  - 꺼져 있으면 rekordbox→장치 SYNC 버튼이 비활성이다.
  - 장치 동기화가 켜져 있는데 어느 목록에도 없는 USB 곡이 있으면 rekordbox가 확인 창(OK/취소)을 띄운다. 문구는 "플레이리스트에 더 이상 존재하지 않는 트랙은 삭제될 것입니다."이다.
- **새 파일**: 2026-10-08 빈 USB 실험이다.
  - 방법은 다음과 같다. 지운 USB를 rekordbox 동기화 관리자로 열고 동기화를 켠다. 시험 폴더와 빈 목록 둘을 체크하고 SYNC한다. 선택을 바꿔 SYNC한다. 단계마다 사본으로 떠 비교했고 값은 적지 않는다.
  - 빈 USB를 열면 "장치와 플레이리스트 동기화"는 꺼져 있다. 열고 닫기만으로는 PIONEER 파일이 생기지 않는다.
  - 켜면 OneLibrary 변환 안내에서 OK를 누른다. SYNC 전에 두 선택 파일이 각 173바이트로 생긴다. 빈 DB 셋도 함께 생긴다.
  - 이때 사본은 뜨지 못했다. 이 길이가 정확히 맞는 모양은 아래뿐이다.
    - 선언.
    - 빈 줄.
    - `<Sync DBID AutomaticSync="1" AllPlaylists="0" IncludeCue="1" ForcedSync="0" Timestamp="0">`
    - `  <Playlists/>`
    - `</Sync>`
    - 줄 끝은 CRLF이고 DBID는 11자다.
  - 그래서 행이 없는 파일은 `<Playlists/>` 한 줄로 쓴다(`UsbSyncSelectionXML.canonical`). 행이 있는 모양은 위와 같다.
  - 첫 SYNC 뒤 두 파일은 위 모양 그대로였다. 루트는 `AutomaticSync="1" AllPlaylists="0" IncludeCue="1" ForcedSync="0" Timestamp="0"`였다. `DBID`와 행 칸 규칙은 기존 파일과 같았다.
  - 빈 USB의 USB 목록 번호는 1부터다.
  - 첫 SYNC 결과 두 파일을 이 규칙으로 다시 만들어 바이트까지 같음을 사본으로 확인했다. `DBID`는 로컬 사본에서, `Timestamp`는 그때의 `masterPlaylists6.xml`에서, `Dev_ID`는 USB DB 사본에서 가져왔다.
  - DJCrate는 선택 파일을 USB에 있는 형식마다 하나 둔다. 내보내기는 만들 형식마다 하나다.
    - 모두 없으면 새로 만든다. 루트 처음 값은 `UsbSyncSelectionXML.newFileRootDefaults`이고 `AutomaticSync`는 체크 값이다.
    - 모두 있으면 고쳐 쓴다.
    - 한쪽만 있으면 막는다(`syncSelectionPartialFiles`, `gateBlock`).
    - 새 파일은 쓰기 묶음의 `create`라 백업에 "없던 파일"로 남는다. 복원과 회복이 지운다.
    - 빈 USB의 SYNC는 내보내기(`UsbExportSession`)에 선택 초안을 실어 DB와 같은 쓰기에서 만든다.
    - 파일이 없는 USB에서 켜짐만 켜면 행 없는 파일을 만든다. 끄기만 하면 쓸 것이 없다(`UsbSyncSelectionStage.writesNothing`).
    - 라이브러리가 없는 빈 USB에서 켜짐만 켜는 것은 쓰지 않는다. rekordbox는 이때 빈 DB도 만들지만 DJCrate는 SYNC 때 함께 만든다.
- **해제·삭제·옮기기**: 2026-10-08 정상 USB 실험이다.
  - 조건은 두 형식이 맞는 USB이고 장치 동기화가 켜짐이다.
  - 단계는 다음과 같다.
    1. 새 폴더와 빈 목록 X·Y를 체크하고 SYNC한다.
    2. X 이름 바꾸기 → SYNC.
    3. Y를 폴더 밖 맨 위로 옮기기 → SYNC.
    4. Y 해제 → SYNC.
    5. X2 삭제 → SYNC.
    6. 폴더와 Y 삭제 → SYNC.
  - 단계마다 USB 두 선택 파일, DB, `masterPlaylists6.xml`을 사본으로 떠 비교했다.
  - 해제한 목록은 SYNC 때 그 행의 `Dev_ID`가 가리키던 USB 목록을 두 형식에서 지웠다.
  - 체크한 원본을 로컬에서 지우면 SYNC 전에는 USB 목록이 남았다. SYNC 때 지웠다.
  - 옮긴 원본은 체크가 그대로였다. SYNC 뒤 새 자리에만 보였고 옛 자리에는 남지 않았다. Device Library는 같은 `Dev_ID`였고 OneLibrary는 새 `Dev_ID`였다.
  - 이름 바꾸기 전 X처럼 연결 없는 옛 목록이 든 USB 폴더는 원본 폴더를 지워도 회색으로 남았다.
  - 이 단계들에서 곡 삭제 확인 창은 나오지 않았다. 시험 목록이 비어 있었다.
  - 앞선 실험의 "해제해도 USB 목록이 회색으로 남는다"는 잘못된 결론이었다.
    - 그 USB는 끊긴 쓰기 뒤 두 형식의 목록 번호가 서로 어긋나 있었다. 같은 번호가 형식마다 다른 목록이었다.
    - rekordbox가 해제한 목록을 찾지 못해 남긴 것으로 보인다.
  - rekordbox가 켜져 있고 USB를 꽂아 둔 때는 다음과 같다.
    - 체크한 원본의 이름 바꾸기, 옮기기, 삭제만으로(SYNC 없이) `playlists3Plus.sync`만 다시 쓴다.
    - 이때 마지막 덩어리의 라이브러리 뿌리 행을 `  </Playlists>` 바로 앞에 한 번 더 붙인다. 관찰한 파일에서는 iTunes `Lib_Type` 1의 행이었다.
    - 붙은 행은 그 라이브러리의 첫 뿌리 행과 바이트까지 같다. 빼면 앞 단계 파일과 바이트까지 같았다.
    - `playlists3.sync`는 그대로였다. 이름 바꾸기, 옮기기, 삭제, 정리 네 단계 사본으로 확인했다.
    - 다음 SYNC는 두 파일을 그 행 없이 다시 쓴다.
    - 지운 원본의 NODE는 rekordbox를 종료할 때 `masterPlaylists6.xml`에서 빠졌다. 켜져 있는 동안은 남았다.
  - DJCrate는 끝에 붙은 뿌리 행을 접어 읽는다(`UsbSyncSelectionFile.trailingDuplicateRoots`).
    - 접는 행은 같은 `Lib_Type`의 첫 뿌리 행과 칸마다 같은 뿌리 행뿐이다.
    - 접은 행은 선택과 두 형식 비교에 넣지 않는다.
    - 뿌리가 아닌 행, 값이 다른 뿌리 행, 가운데의 중복은 그대로 `invalidFile`이다.
    - 쓰기에서 엄격한 모양 판정(`isCanonical`)은 그대로 둔다. 접은 행을 다시 붙인 모양이 원문과 같을 때(`isCanonicalWithTrailingDuplicateRoots`)만 선택 쓰기를 받는다. 이때 다음 SYNC처럼 그 행 없이 새로 쓴다.
    - 켜짐만 바꾸는 쓰기는 rekordbox처럼 다른 칸과 행을 그대로 둘 수 없어 막는다(`syncSelectionPendingRekordboxSync`). 안내는 rekordbox에서 한 번 SYNC하라는 것이다.
  - 목록 번호는 형식마다 다르게 붙는다.
    - rekordbox는 Device Library의 새 목록 번호로 빈 번호를 다시 쓴다.
    - OneLibrary는 가장 큰 값+1을 쓴다.
    - 그래서 같은 목록이 형식마다 다른 번호를 갖거나, 같은 번호가 형식마다 다른 목록이 되기도 한다. 평범한 SYNC 뒤에도 생긴다.
    - DJCrate는 목록을 자리, 이름, 종류로 짝지어 읽는다(§2.6). 형식마다 그 형식 번호로 고쳐 쓴다.
    - 이전에는 이런 USB를 `formatPlaylistConflict`로 막고 같은 목록을 두 번 보였다.
  - DJCrate의 지우기 규칙은 `UsbSyncPlan.playlistPlan`에 있다.
    - 지난 선택 파일 행으로 이은 USB 목록 중 원본을 선택에서 뺀 것을 지운다. 두 형식이 같은 목록을 가리키는 것만 이은 목록이다(`UsbSyncSelectionResolution.playlistIDs`).
    - 로컬에서 지운 rekordbox 원본의 행이 가리키던 목록도 지운다(`removedSourcePlaylistIDs`). 원본 목록에도 `masterPlaylists6.xml`에도 Id가 없을 때만 지운다.
    - master에 Id가 남아 있으면 로컬 사본이 오래된 것일 수 있다. 이때는 `sourceMissing`으로 막는다. iTunes 원본은 늘 막는다.
    - 폴더는 지운 뒤 안에 남는 목록이 없을 때만 지운다. 폴더 하나를 지우면 안의 것도 함께 지운다.
    - 안에 남는 목록이 있으면 폴더는 남기고 안의 지울 목록만 지운다.
    - 행으로 이은 적 없는 USB 목록은 지우지 않는다.
  - DJCrate의 옮기기·이름 바꾸기 규칙은 다음과 같다.
    - 원본 이름이 같고 자리만 옮겼으면 이은 목록을 새 자리로 옮긴다. 항목을 유지하고 두 형식이 같은 번호를 쓴다. rekordbox가 OneLibrary에 새 번호를 주는 것과 다르다.
    - 이름이 바뀐 원본은 새 목록을 만들고 옛 목록은 연결 없이 남긴다.
    - 선택 파일 행의 부모가 지금 원본의 부모와 달라도 막지 않는다. 옮긴 뒤 SYNC 전이 그런 경우다.
    - 동기화 창의 "동기화 후" 보기는 같은 계획으로 새로 만듦, 옮김, 연결 없음(흐리게), 지울 목록을 보인다.
    - 지운 목록에만 있던 곡은 기존 곡 삭제 확인을 거친다.
- **폴더 이름 바꾸기·체크 상태·닫기 확인**: 2026-10-08 실험 2, G0–G10이다.
  - 조건은 두 형식이 맞는 USB이고 장치 동기화가 켜짐이다.
  - 폴더 F 아래 목록 셋과 맨 위 목록 R을 만들어 하나씩 체크한다.
  - 단계는 다음과 같다.
    - SYNC(G1).
    - F를 직접 체크하고 새 하위 N을 만든다. SYNC(G2).
    - F를 F2로 바꾼다. SYNC(G3).
    - R을 R2로 바꾼다. SYNC. 다시 R로 바꾼다. SYNC(G4).
    - 동기화를 끄고 닫는다. 끈 채 체크를 시도한다. CUE GRID INFO를 한다. 켜고 닫는다(G5).
    - 해제, 삭제, 이름 바꾸기(G6–G10).
  - 단계마다 USB 두 선택 파일, DB, `masterPlaylists6.xml` 사본을 떠 구조만 비교했다. 값은 적지 않는다.
  - 이름을 바꾼 체크 폴더(G3):
    - 두 형식 모두 새 F2와 그 아래 하위 목록 넷을 새 USB 목록(새 `Dev_ID`)으로 만들었다.
    - 옛 F와 그 안의 옛 목록 넷은 지우지도 옮기지도 않고 연결 없이(회색) 남았다. 옛 F의 USB 번호도 그대로였다.
    - 두 선택 파일에서 F 행과 하위 행은 원본 `Id`가 같고 `Dev_ID`만 새 번호였다. 옛 번호는 파일에서 빠졌다.
    - DJCrate(`UsbSyncPlan.playlistPlan`)는 옛 폴더 안에 있던 이은 하위 목록을 옮기지 않고 새로 만든다. 부모 폴더가 이름이 바뀌어 새로 만들어질 때다. 하위 목록 이름이 같아도 그렇다. 하위 폴더도 같은 규칙을 아래까지 적용한다.
    - 이름이 그대로인 원본을 다른(새) 폴더로 옮긴 경우는 앞 실험대로 이은 목록을 옮긴다.
  - 하위를 하나씩 모두 체크한 폴더(G1):
    - 폴더는 `CheckType` 2였고 하위 행은 1이었다. 체크 화면도 부분 체크로 보였다.
    - 라이브러리 뿌리 행도 2였다.
    - DJCrate도 폴더 자체를 고르지 않았으면 2로 쓴다.
  - 폴더 자체를 체크한 뒤 그 폴더에 새로 만든 목록은 자동으로 체크 상태가 됐다. SYNC 뒤 `CheckType` 1 행으로 적혔다(G2).
  - 이름을 바꿨다가 원래 이름으로 되돌린 목록(G4b)은 처음 USB 목록의 `Dev_ID`를 다시 썼다. 두 형식 모두 그랬다. 그 사이 만든 목록(R2)은 연결 없이 남았다.
  - 동기화하지 않은 변경이 있는 채 닫으면 rekordbox가 확인 창을 띄웠다. 문구는 "변경 사항이 동기화되지 않았습니다. 변경한 내용을 지금 바로 동기화합니까?"(예/아니오)다.
    - 체크를 바꾼 뒤(G2a·G3)에도 물었다.
    - 끈 동기화를 켜기만 한 뒤(G5c)에도 물었다.
    - 끄고 닫을 때는 묻지 않았다(G5a).
    - "아니오"로 닫으면 바꾼 체크는 버렸다(G2a). 다시 열면 그 전 선택이었다.
    - 켜고 "아니오"로 닫은 G5c에서는 두 선택 파일의 `AutomaticSync`만 0→1로 바뀌었다.
    - Device Library 파일은 그 칸만 되돌리면 바이트까지 같았다. OneLibrary 파일은 끝 뿌리 행을 접은 뒤 행이 같았다.
  - DJCrate는 동기화가 켜져 있고 SYNC를 누를 수 있을 때 같은 문구로 묻는다. 선택이 USB 선택과 다르거나 켜기만 했을 때가 그렇다.
    - "예"는 SYNC 버튼과 같은 흐름이다.
    - "아니오"와 꺼진 채 닫기는 바꾼 체크를 USB 선택으로 되돌린다. 켜짐이 바뀌었으면 `AutomaticSync`만 쓴다.
    - 앱이 저장한 옛 선택은 선택 파일이 있는 USB에서 다시 채택하지 않는다. 연결만 이어 쓴다.
  - "장치와 플레이리스트 동기화"가 꺼져 있으면 체크를 바꿀 수 없었다(G5b). 체크 표시가 생기지 않았다. DJCrate도 꺼진 동안 iTunes·rekordbox 목록 체크와 전체 선택·선택 해제를 막는다(`UsbSync.canEditSelection`).
  - 곡이 든 목록을 해제한 SYNC와 로컬에서 지운 SYNC에서는 곡 삭제 확인이 나오지 않았다. 앞은 G6·G8b, 뒤는 G7이다.
    - 빠진 곡이 다른 이은 목록에 남아 있었다(G6·G7).
    - 또는 연결 없이 남은 회색 목록에만 남아 있었다(G8b).
    - 이것은 연결 없는 목록이 가리키는 곡을 지울 곡으로 보지 않는 DJCrate 규칙과 같다.
- **확인하지 않은 것**:
  - 행 없는 파일의 실제 바이트. 길이로만 맞췄다.
  - 한 형식만 있는 USB에서 rekordbox가 만드는 선택 파일.
  - 곡이 든 목록을 해제·삭제해 어느 목록에도 남지 않는 곡이 생길 때의 곡 삭제 확인. 두 실험 모두 그런 곡이 생기지 않았다.
  - 이름을 바꾼 자리에 같은 이름의 연결 안 된 USB 목록이 이미 있을 때. DJCrate는 그 목록에 잇는다.
  - 이름이 그대로인 원본을 새로 만든 폴더로 옮길 때. DJCrate는 이은 목록을 옮긴다.
  - CUE GRID INFO가 곡 정보 칸을 가져오는 다른 조건. 실험 X1에서는 값이 달라도 가져오지 않았다.

`.syncSelection` 초안은 선택 당시 두 XML 원문을 보관해 오래된 선택을 덮지 않는다.

- 적용한 DB 모델에서 형식마다 최종 USB 번호를 찾아 XML을 만든다(`UsbSyncSelectionStage.resolve`). 같은 쓰기 묶음에서 DB 뒤에 확정한다.
- 켜짐만 바꾸는 초안(`enabledOnly`)은 목록을 건드리지 않고 두 파일의 `AutomaticSync`만 바꾼다.
- 원문 경합, 형식 막힘, 불완전한 선택 목록은 전체 쓰기를 막는다.
- 사전 확인과 쓰기 뒤 검증은 같은 입력으로 만든 바이트가 준비 파일·USB 파일과 바이트까지 같은지 본다. 실제 목록 참조는 Mac DB 사본으로 다시 확인한다.
- 끊긴 native 동기화는 DB와 두 파일을 전체 복원한다. 외부 변경과 삭제는 `restorePending`으로 멈춘다.
- `UsbSyncXMLWriteContract.production`은 확인한 규칙(`confirmed`)이다. nil로 바꾸면 선택 파일 쓰기 전체를 백업 전에 막는 비상 스위치다.

전후 사본 대조는 `djc lab usb-sync-diff <전 폴더> <후 폴더>`로 한다.

- 폴더는 임시 폴더 아래의 sync 사본이나 USB 폴더 사본이다.
- 바뀐 속성 이름, 노드 추가/제거, 순서만 출력한다. 원본 ID, DBID, 시각 값은 출력하지 않는다.
- 새 rekordbox 버전에서 규칙을 다시 확인할 때도 이 도구로 단계별 전후를 대조한다.
### 8.4 Device Library만 있는 USB를 OneLibrary로 옮기기(`UsbMigration`, `UsbMigrateSession`, `djc usb-migrate`)

옛 Device Library만 있는 USB는 OneLibrary 전용 기기에서 목록이 보이지 않는다(#46). 옮기기는 pdb를 읽어 같은 USB에 `exportLibrary.db`를 더한다. 로컬 라이브러리는 읽지 않는다. 원래 파일은 바꾸지 않는다. 원래 파일은 pdb 둘, 분석 파일, 음원, a 그림이다.

근거는 rekordbox 7.2.18이 두 형식을 함께 쓴 골든(2026-09-26 내보내기)이다. 골든의 pdb와 OneLibrary를 칸 단위로 맞춰 봤다. rekordbox의 "Convert from Device Library" 결과와는 아직 견주지 못했다. 그래서 옮기기는 늘 `deviceLibraryMigration`을 싣는다.

**순서**(세션):

1. 볼륨을 확인한다. 수정 목적의 정책, 보호 경로, 실물 관문을 본다. 막히면 USB를 열거하지 않는다.
2. 저널을 본다. 닫히지 않은 쓰기는 `recoveryNeeded`다.
3. OneLibrary DB나 사이드카가 하나라도 있으면 사본을 뜨지 않고 `oneLibraryExists`로 막는다.
4. USB DB 사본(`UsbSnapshot`)을 뜬다.
5. 계획(`UsbMigration.plan`)을 세운다. 준비 폴더를 쓴다.
6. 확인 안 된 규칙을 모은다.
7. `UsbWriter.write`로 쓴다. 검사기는 `UsbMigrationInspector`다. 검증기는 목표 지문, `OneLibraryVerifier`, `UsbInvariantVerifier`다.

**막힘**(옮기기 전체):

- OneLibrary가 이미 있다(`oneLibraryExists`). rekordbox 변환은 덮어쓰지만 여기서는 덮지 않는다.
- pdb가 없다(`noDeviceLibrary`).
- 읽기가 실패한다(`libraryCorrupt`).
- 두 pdb 머리 0x10이 5가 아니다(`pdbNotClosed`).
- 구조 문제가 있다(`pdbUnreadableRows`). 읽기는 읽은 데까지만 모델에 넣는다. 그대로 옮기면 행이 조용히 빠진다. 먼 모양 My Tag 행도 여기에 든다. 아티스트·앨범 먼 모양 행은 다 읽으므로 막지 않는다.
- 기기 기록이나 모르는 표 행이 있다(`carriedDeviceRows`). 디스크 이미지에서도 막는다.
- 표 19 버전이 "1000"이 아니다(`pdbVersionUnsupported`).
- 곡이 0이다(`noTracks`).
- a 그림이 없거나 경로 모양이 `/PIONEER/Artwork/nnnnn/a{id}.jpg`가 아니다(`artworkMissingOnUsb`).
- b 자리에 다른 바이트의 파일이 있다(`artworkExists`). 같은 바이트면 다시 쓰지 않는다.
- 불변식 미리 보기(아래)에서 새 문제가 나온다(`libraryFilesMismatch`).

**칸**(`UsbMigration.model`): pdb 모델을 두 형식 모델로 바꾼다.

- Device Library 투영은 입력과 같다.
- 곡, 목록, My Tag 연결은 두 형식 모두에 둔다.
- 목록의 OneLibrary 순서와 항목은 pdb 값 그대로다. 순서와 중복까지 같다.

OneLibrary에만 있는 칸:

| 칸 | 값 |
|---|---|
| content.contentLink | 0x0C0700 \| (USB `.2EX`의 PVDI에 본문이 있으면 0x100000) |
| content.contentLink (`.2EX`가 없거나 읽지 못할 때) | 보컬 아님 |
| content.analysedBits | 105(골든에서 모든 곡이 이 값, pdb에 칸이 없다) |
| content.artist_id_lyricist / hasModified / titleForSearch / kuvoDeliveryComment | 0 / 0 / NULL / '' |
| 곡의 OneLibrary 기기 칸 | 평점·재생 수 = pdb 값, hasModified 0 |
| album image_id·isComplation·nameForSearch, playlist image_id, artist nameForSearch | NULL·0·NULL(내보내기와 같다) |
| image.path | pdb a 경로의 같은 폴더 `b{id}.jpg` |
| property createdDate | pdb 표 19 날짜(내보낸 날) |
| property deviceName / backGroundColorType | '' / 0 |
| property numberOfContents | 곡 수 |
| property dbVersion·myTagMasterDBID | pdb 값 |

- 파일: 새 `exportLibrary.db`를 만든다. 준비 폴더에서 `OneLibraryWriter.create`로 만든다(만들기·확인은 §2.9). 그림마다 `b{id}.jpg`(a 사본)를 만든다. `a{id}_m.jpg`가 있으면 `b{id}_m.jpg`도 만든다. 덮어쓰기, 지우기, 음원 복사는 없다.
- 변경 묶음:
  - `purpose .edit`, label `migrate`, `formats [.oneLibrary]`.
  - `base`는 사본 지문(pdb 둘)이다.
  - 목표 지문은 새 DB, b 그림, **원래 pdb 두 파일의 지금 해시**다. G 단계가 "원래 파일 그대로"를 매체에서 다시 확인한다.
  - `UsbMigrationInspector`가 A 단계에서 한 번 더 본다. DB는 OneLibrary 하나만 만들고, 그 파일과 사이드카가 없어야 한다. 덮어쓰기, 지우기, 복사는 없어야 한다. 두 pdb 머리 0x10은 5여야 한다.
- 불변식 미리 보기: 검증의 불변식 1–6(§7.12)을 두 번 본다. 한 번은 pdb만으로 보고, 한 번은 변환 모델의 OneLibrary를 더해 본다. 두 결과의 문제를 견준다.
  - 쓰기 전부터 있던 문제는 막지 않고 검증에서 뺀다. 예는 없는 음원, 없는 분석 파일, 음원 크기가 파일 크기 칸과 다른 것이다. 이것은 두 형식에 같은 문제다.
  - 음원 크기 차이는 rekordbox가 분석 뒤 바뀐 음원을 내보낸 USB에 흔하다(§5).
  - OneLibrary 쪽에만 새로 생기는 문제가 있으면 쓰지 않는다. 예는 PPTH나 파일 이름이 pdb와 어긋나는 것이다.
  - 두 형식 불일치(`UsbLibrary.merge`)가 있어도 쓰지 않는다. 쓰고 나서 검증이 되돌리지 않게 한다.
- 확인 안 된 규칙은 아래를 모두 합친 것이다.
  - `deviceLibraryMigration`
  - 목록 `playlistSiblingBase`
  - 폴더 `playlistFolderRow`
  - My Tag 연결 `myTagLinks`
  - 그림 없는 곡 `artworkMissing`
  - 빈 값으로만 본 곡 정보 칸 `metadataSeenEmptyOnly`. 칸은 레이블, 리믹서, 원곡자, 작사가, 색, 평점, 부제다.
  - `exportExt.pdb`가 없으면 `myTagMasterDBID`. 값은 0으로 둔다.
- 골든 대조: pdb만 남긴 골든 사본의 디스크 이미지를 만들고 `djc usb-migrate`를 돌린 뒤 `djc lab usb-diff --onelibrary <골든> <이미지> --ignore-ids --files --anlz`로 견줬다.
  - 곡, 이름 표, 그림, My Tag, 메뉴, 카테고리, 정렬, property 칸이 모두 같다.
  - b 그림 바이트와 분석 파일이 같다.
  - 설명된 차이는 둘이다. 하나는 DB 파일 바이트다. 이것은 칸으로 판정한다.
  - 다른 하나는 한 목록의 OneLibrary 항목이다. 골든 자체에서 두 형식의 그 목록 항목이 이미 다르다. rekordbox가 두 형식에 같은 곡을 서로 다르게 중복해 넣은 모양이고, 규칙은 확인하지 못했다.
  - 옮기기는 사용자의 pdb를 원본으로 보고 pdb 항목을 그대로 옮긴다.
  - `djc lab usb-migrate-check <골든 사본>`도 같은 결과다.
- 확인 안 된 것:
  - rekordbox 변환 결과의 칸. 칸은 analysedBits, createdDate, myTagMasterDBID, isComplation, 목록 항목이다.
  - rekordbox 5·6이 쓴 옛 pdb를 그대로 읽는지. `.2EX`나 `exportExt.pdb`가 없는 USB도 포함한다.
  - OneLibrary 기기가 옮긴 USB를 그대로 읽는지. 중복 항목이 있는 목록도 포함한다.

## 9. 확인 안 된 규칙

| 규칙 | 지금 값 | 표시 조건 |
|---|---|---|
| `physicalVolume` | 확인 안 됨(관문으로만 봄, §12) | 대상이 디스크 이미지가 아닌 실물 USB |
| `analysisFolderNaming` | 확인 안 됨 | 시험용 고유 이름(`IdentifierAnalysisNaming`)으로 분석 파일을 새로 쓸 때. 쓰기 경로는 rekordbox 이름을 써서 붙지 않는다(§5) |
| `analysisSlotCollision` | 확인 안 됨 | 새 분석 파일 폴더 이름이 이미 있는 폴더와 겹칠 때 |
| `playlistSiblingBase` | 확인 안 됨 | 재생 목록을 쓸 때(같은 폴더 안 순서 번호) |
| `playlistFolderRow` | 확인 안 됨 | 재생 목록 폴더를 쓸 때 |
| `myTagLinks` | 확인 안 됨 | My Tag가 붙은 곡을 쓸 때 |
| `myTagMasterDBID` | 확인 안 됨 | My Tag를 쓸 때 |
| `artworkFolderSplit` | 확인 안 됨 | 아트워크를 여러 폴더로 나눠야 할 때 |
| `artworkMissing` | 확인 안 됨 | 아트워크가 없는 곡을 쓸 때 |
| `fileNameTruncation` | 확인 안 됨 | 음원 파일 이름을 줄여야 할 때 |
| `forbiddenCharacters` | 확인 안 됨 | 이름에 rekordbox에서 보지 못한 금지 글자(`< \ |`·제어 문자)가 있을 때. `" * / : > ? ~`는 확인했다(§5) |
| `pathCollision` | 확인 안 됨 | 두 곡이 USB에서 같은 경로가 될 때. 대소문자와 NFC/NFD는 무시한다 |
| `emptyArtistAlbum` | 확인 안 됨 | 아티스트나 앨범이 빈 곡 |
| `supplementaryCharacters` | 확인 안 됨 | 이름에 이모지 등 보충 평면 글자가 있을 때 |
| `leadingSpace` | 확인 안 됨 | 이름이 빈칸으로 시작할 때 |
| `cueSeekFields` | 확인 안 됨 | 큐가 있는 곡의 음원 형식이 MP3(MPEG 프레임 칸 0)·M4A·FLAC가 아닐 때 |
| `cueVariant` | 확인 안 됨 | 아래 큐 모양 중 하나일 때 |
| `fileTypeUnverified` | 확인 안 됨 | 확인하지 않은 음원 형식의 곡 |
| `metadataSeenEmptyOnly` | 확인 안 됨 | 빈 값으로만 본 곡 정보 칸에 값이 있을 때 |
| `pdbLongAscii` | 확인 안 됨. 트랙 행 문자열, 아티스트, 앨범 이름은 확인(2026-10-08) | 긴 ASCII를 본 적 없는 칸에 긴 ASCII를 쓸 때. 칸은 재생 목록, 장르, 레이블, 키, 아트워크, My Tag 이름이다 |
| `pdbFarOffsetRows` | 확인 안 됨. 아티스트·앨범은 이름 끝 248 이상이 먼 모양으로 확인. 앨범 이름 끝 247만 못 봄(2026-10-08 실험 X1) | 앨범 이름 끝이 247일 때(긴 ASCII 219자, 쓰고 알림). My Tag 행이 가까운 모양에 안 들어갈 때(막음) |
| `carriedDeviceRows` | 확인 안 됨(디스크 이미지에도 막음) | USB에 기기가 남긴 기록 행이 있을 때 |
| `settingFiles` | 확인 안 됨 | 기기 설정 파일을 쓸 때 |
| `pdbRegeneratedEdit` | 확인 안 됨 | USB를 고치며 Device Library를 다시 만들 때 |
| `trackRemovalFiles` | 확인 안 됨 | USB에서 곡을 빼며 그 곡의 파일을 지울 때 |
| `editRefreshTracks` | 확인 안 됨 | USB 안 곡 정보를 갱신할 때 |
| `editRemoveTracks` | 확인 안 됨 | USB에서 곡을 뺄 때 |
| `editAddTracks` | 확인 안 됨 | 이미 내보낸 USB에 곡을 더할 때 |
| `editPlaylists` | 확인 안 됨 | 이미 내보낸 USB의 재생 목록을 고칠 때 |
| `deviceLibraryMigration` | 확인 안 됨 | Device Library만 있는 USB에 OneLibrary를 더할 때(§8.4) |
| `audioChangedSinceAnalysis` | 칸 모양은 rekordbox와 같음(2026-10-08 빈 USB 실험 196곡, §5). CDJ 재생은 확인 안 됨 | 로컬 음원 크기가 rekordbox `FileSize`와 다른 곡을 내보내거나 더할 때. 분석 뒤 파일이 바뀐 곡이다 |
| `pdbStringNFC` | 확인 안 됨. rekordbox와 다르게 쓰는 규칙이다 | Device Library에 쓰는 이름·제목이 NFC로 바뀔 때(§3.4) |

`cueVariant`가 붙는 큐 모양:

- 색 핫큐
- 색 메모리 큐
- 메모리 루프
- 활성 루프
- 박 루프가 아닌 루프
- 8박이나 16박이 아닌 박 루프
- 핫큐 D, F, G, H

`pdbStringNFC`는 CDJ-2000NXS가 NFD 한글 목록 이름을 "~"로 보이고 NFC는 바르게 보인 관찰에서 정했다(2026-10-09).

확인 안 된 규칙은 쓰기를 막지 않는다(사용자 결정, 2026-10). `carriedDeviceRows`만 늘 막는다(`alwaysBlocks`).

흐름 규칙(`UsbProvisionalRule.flowRules`)은 아래 아홉 개다.

- `analysisFolderNaming`
- `playlistSiblingBase`
- `playlistFolderRow`
- `editAddTracks`
- `editRemoveTracks`
- `editPlaylists`
- `trackRemovalFiles`
- `pdbRegeneratedEdit`
- `deviceLibraryMigration`

흐름 규칙은 내보내기·수정·옮기기 흐름 자체의 바탕 규칙이다. 이 흐름은 디스크 이미지에서 전 과정을 확인했다(#41·#46). 전 과정은 쓰기, 다시 읽기 검증, `usb-rebuild`·`usb-diff --ignore-ids` 차이 0, 되돌리기다. 흐름 규칙은 모든 쓰기에 붙으므로 화면에 알리지 않는다.

나머지 규칙은 앱 미리 보기와 확인 창에 알리고 쓴다. 나머지는 곡 내용에 따라 붙는 규칙, `editRefreshTracks`, `settingFiles` 등, `needsDeviceCheck`다. 알리는 문구는 둘이다.

- 내보내기: "CDJ에서 확인하지 않은 항목이 있는 곡 N개:"와 규칙 목록
- 수정·옮기기: "CDJ에서 확인하지 않은 항목 N개:"와 규칙 목록

CLI는 요약의 "확인 안 된 규칙" 줄에 모든 규칙 이름을 적는다. 어느 것도 rekordbox 실험으로 확인한 것이 아니므로 `confirmed`에는 넣지 않는다.

## 10. 막아 둔 것

첫 판에서 코드가 막는 것과 쓰지 않는 것이다. 막힘은 이유와 할 일을 한 문장으로 알린다.

| 무엇 | 지금 | 규칙·code |
|---|---|---|
| 실물 USB에 쓰기 | 사용자가 동의한 쓰기에만 쓴다. 앱은 내보내기 시트·쓰기 확인 창, CLI는 `--allow-physical --confirm <볼륨 이름>`이다(§12) | `physicalVolume`, `physicalDisabled`, `confirmMismatch`, `noVolumeUUID` |
| Device Library 먼 오프셋 행 | 아티스트·앨범은 rekordbox 모양대로 쓴다(§3.8). My Tag 행이 가까운 모양에 안 들어가면 내보내기 전체를 막는다. 아티스트·앨범·트랙 행이 빈 쪽에도 안 들어가면 그 곡을 막는다 | `pdbFarOffsetRows`, `nameTooLongForDeviceLibrary`, `myTagNameTooLongForDeviceLibrary`, `trackRowTooLarge` |
| 긴 ASCII(127자 이상 순수 ASCII) | 모든 칸에 rekordbox의 0x40 모양으로 쓴다. 본 적 없는 칸이면 CDJ 확인 항목으로 알린다 | `pdbLongAscii` |
| 재생 기록 표 | 쓰지 않는다. 기기 기록 행이 있는 USB를 다시 만드는 쓰기는 디스크 이미지에서도 막는다 | `carriedDeviceRows` |
| My Tag 연결 | 두 형식 모두 쓰지 않는다. Device Library에 연결이 있는 USB는 다시 쓸 수 없는 모양으로 본다(왕복 검사 실패) | `myTagLinks`, `pdbRoundTripFailed` |
| 기기 설정 파일 | 기본 끔. `--settings <로컬 설정 폴더>`로 켤 때만 셋을 옮긴다. `DEVSETTING.DAT`·`djprofile.nxs`는 만들지 않는다 | `settingFiles` |
| 스마트(인텔리전트) 재생 목록 | 내보내지 않는다(그 곡은 다른 선택대로 간다) | `smartPlaylist` |
| 이미 라이브러리가 있는 USB에 내보내기 | 막고 USB 수정으로 안내한다. DB가 없어도 `PIONEER/`에 무엇이 남아 있으면 막는다 | `libraryExists`, `leftoverPioneer` |
| 확인하지 않은 로컬 rekordbox 버전 | 내보내기를 막는다(확인: 7.2.x) | `localVersionUnverified` |
| 스냅샷 뒤에 바뀐 곡 | 스냅샷 뒤 분석 파일이 바뀐 곡은 그 곡만 막는다(§5 막힘). 음원 크기가 `FileSize`와 다른 곡은 2026-10-09부터 rekordbox처럼 내보내고 알린다(§5 분석 뒤 바뀐 음원) | `analysisNewerThanSnapshot`, `audioChangedSinceAnalysis` |
| 볼륨 모양 | 아래 목록을 본다 | `UsbVolumePolicy`, `unsupportedFileSystem`, `partitionScheme` |

볼륨 모양 규칙:

- 허용하는 것은 FAT32·exFAT, MBR·GPT뿐이다.
- 파티션 번호와 섹터 크기는 보지 않는다.
- 막는 것은 HFS+, APFS(Time Machine 포함), FAT16, APM, 파티션 표 없음, 내장, 네트워크, 읽기 전용, 시동 디스크다.
- exFAT와 GPT는 확인 창에 한 줄로 알린다.

## 11. 새 USB 쓰기 경로를 여는 방법

아래 순서로 연다. 마지막에 `UsbProvisionalRule.confirmed`에 더하고, 더한 뒤 §9 표의 지금 값을 고친다.

1. **rekordbox 실험**: 사용자에게 rekordbox 7.2.x에서 그 동작을 직접 해 달라고 부탁한다. 예는 빈 USB에 내보내기, USB 수정이다. 곡 이름을 받고, 끝나면 rekordbox를 종료한다. 결과 USB는 폴더 사본이나 디스크 이미지로 떠서 본다. `PIONEER/extracted`·`CDP`·`djprofile.nxs`는 빼고, 실물은 읽기만 한다.
2. **사본 재현**: 같은 입력을 DJCrate로 디스크 이미지에 쓴다(`djc usb-export`).
3. **칸 단위 일치**: `djc lab usb-diff <rekordbox 결과> <재현> --files --anlz [--mtime]`로 본다. 표, 칸, 태그, 파일 단위 차이가 0이어야 한다. 남은 차이마다 이유를 설명할 수 있어야 한다. 이유는 쓴 시각, 난수 ID 등이다. 쪽 바이트는 `djc lab pdb-verify`로 본다. 분석 파일은 `djc lab usb-anlz-check`로 본다.
4. **골든 테스트**: 합성 재료로 그 규칙을 고정하는 시험을 남긴다. 근거 주석은 `// rekordbox 7.2.18 골든 관찰(<날짜> 내보내기)` 한 줄이다. 골든 바이트를 통째로 넣지 않는다.
5. **확인 목록**: `UsbProvisionalRule.confirmed`에 더하고 §9 표를 고친다. 한 번에 한 규칙씩 연다.
6. rekordbox가 업데이트되면 `djc compat`·`djc usb-info`로 먼저 본다. 실험으로 다시 확인하기 전에는 확인한 버전·규칙 목록을 넓히지 않는다. 흐름 규칙(`flowRules`, §9)을 넓히는 것도 같다. 디스크 이미지 전 과정을 확인한 뒤에만 넓힌다.

## 12. 실물 USB 쓰기

사용자 결정(#41, 2026-10)으로 실물 USB 쓰기를 열었다. 이어 "정책이 너무 보수적"이라는 결정으로 쓰기 금지 목록, 볼륨별 쓰기 허용, 실험실 스위치를 없앴다.

쓰는 절차는 디스크 이미지와 같은 `UsbWriter.write` 하나다. 절차는 §7과 같다.

- 백업, 저널, 파일, DB 교체, 다시 읽기 검증을 지난다. 실패하면 되돌린다.
- 볼륨 잠금을 쓴다. 단계마다 마운트와 볼륨 정체를 확인한다(§7.5 `volumeChanged`).
- 용량을 확인한다.
- `._*` 0개를 확인한다.
- rekordbox가 실행 중이면 거부한다.

다른 것은 쓰기 전에 지나야 하는 관문뿐이다.

**볼륨 모양**(`UsbVolumePolicy`): 디스크 이미지와 같다.

- 바깥 저장장치면 연결 방식을 가리지 않는다. USB 메모리, 외장 SSD, SD 카드 리더, Thunderbolt가 모두 된다.
- 파일 시스템은 FAT32·exFAT다. DiskArbitration `DAVolumeType`이 알린 형식을 쓴다. 파티션 형식 식별자는 MBR 0x0B·0x0C와 GPT 기본 데이터마다 달라 보지 않는다.
- 파티션은 MBR·GPT다. GPT의 데이터 파티션은 보통 두 번째라 파티션 번호는 보지 않는다.
- 섹터 크기는 보지 않는다.
- 막는 것은 시동 디스크, 내장, 네트워크, 읽기 전용이다.
- APFS, HFS+, FAT16 등 그 밖의 파일 시스템은 `unsupportedFileSystem`으로 막는다. Time Machine 디스크는 이 형식이라 여기서 막힌다.
- APM, 파티션 표 없음, 모름은 `partitionScheme`으로 막는다.

**기기 호환 경고**(`UsbVolumePolicy.warnings`): 막지 않고 확인 창에 한 줄로 알린다.

- exFAT: 제조사 사양에서 CDJ-3000은 FAT, FAT32, exFAT, HFS+를 읽는다. CDJ-2000NXS2는 FAT, FAT32, HFS+만 읽는다. 경고 문구는 "exFAT USB는 CDJ-2000NXS2 등 이전 기기가 읽지 못할 수 있습니다"다.
- GPT: GUID 파티션 맵 USB를 기기와 rekordbox가 읽지 못했고, MBR로 다시 포맷해 풀렸다는 사용자 보고가 있다. 제조사 문서로는 확인하지 못했다. 경고 문구는 "GPT로 포맷한 USB는 일부 기기가 읽지 못할 수 있습니다. 기기에서 읽히지 않으면 MBR로 포맷하세요"다.

**관문**(`UsbPhysicalWriteGate`): 순수 함수이고 처음 걸린 막힘 하나만 알린다. 실물이거나 루트가 임시 폴더 밖이면 본다. 디스크 이미지는 통과한다.

1. 코드 관문(`buildEnabled`, 지금 `true`)과 사용자 동의가 둘 다 열려 있지 않으면 `physicalDisabled`로 막는다.
   - 동의는 앱에서는 볼륨 줄을 보인 내보내기 시트나 쓰기 확인 창의 쓰기 버튼이다. 앱의 쓰기 창구는 그 버튼을 거친 뒤에만 부르므로 동의한 관문으로 만든다. CLI에서는 `--allow-physical`이다.
   - 코드 관문은 실기기에서 문제가 나오면 한 줄로 모든 실물 쓰기를 닫는 비상 스위치다.
   - 디스크 이미지만 읽는 실행은 동의가 늘 없다. 자가 테스트와 `DJC_HOME` 시험 실행(`UsbReadPolicy.diskImagesOnly`)이 여기에 든다.
2. 볼륨 UUID가 없으면 `noVolumeUUID`로 막는다. 잠금, 저널, 백업을 볼륨별로 두기 때문이다.
3. 볼륨 이름 확인이 다르면 `confirmMismatch`로 막는다. CLI는 `--confirm`을 쓰고, 앱은 확인 창에 보인 볼륨 이름을 쓴다.

옛 판의 목록 파일(`~/Library/Application Support/DJCrate/usb-physical-allow.json`·`usb-physical-deny.json`)은 읽지 않고 지우지도 않는다.

**앱**:

- 사이드바는 꽂힌 USB를 등록 없이 읽어 보인다.
- 쓰기 확인 창(수정·옮기기)과 내보내기 시트의 볼륨 줄이 `실물 USB입니다: <이름> · <용량> · <파일 시스템> · <MBR|GPT>`이다.
- 이어서 "쓰기 전 바꿀 파일을 Mac에 백업합니다. 기기에 꽂기 전에 결과를 확인하세요"와 기기 호환 경고를 보인다.
- CDJ에서 확인하지 않은 항목(§9)은 확인 창과 시트의 미리 보기에 보인다.
- 확인 창의 확인 버튼이 곧 동의다. 내보내기는 시트에서 미리 본 뒤 누른 [USB에 쓰기]가 곧 동의다. 확인 창을 두 번 띄우지 않는다(#212).
- 쓰기, 회복, 되돌리기에는 그 볼륨 이름과 UUID를 넘긴다. 그 사이 같은 자리에 다른 USB가 붙었으면 `volumeChanged`다(§7.5).
- 편집 메뉴와 옮기기 메뉴의 막힘 미리 판정도 같은 관문을 쓴다(`UsbStore.physicalGate`).

**CLI**: 쓰기 명령 다섯 개에 `--allow-physical --confirm <볼륨 이름>`을 준다. 명령은 `usb-export`, `usb-edit`, `usb-migrate`, `usb-restore`, `usb-recover`다. 대화형 확인은 없다. 자세한 것은 `docs/cli.md`에 있다.

**시험**: 실물 경로는 가짜 볼륨 정보를 임시 폴더 루트에 주입해 시험한다. 관문을 연 쓰기, 되돌리기, 세션 내보내기, 수정을 시험한다. 가짜 볼륨 정보는 아래와 같다.

- `FakeUsbVolume.physicalFAT32`
- `FakeUsbVolume`의 `exfat`
- `FakeUsbVolume`의 `gpt`
- `FakeUsbVolume`의 `externalSSD`
- `FakeUsbVolume`의 `sdCardReader`
- `FakeUsbVolume`의 `thunderboltDisk`

이 Mac에 꽂힌 실제 볼륨에는 어떤 시험도 쓰지 않는다. 시험 프로세스는 관문이 열려도 임시 폴더 밖 루트를 쓰기 절차 첫 확인에서 거부한다.

**실기기 확인 절차**(사용자):

1. rekordbox와 rekordboxAgent를 종료한다.
2. 시험용 USB를 꽂는다.
3. 빈 USB면 사이드바의 "USB로 내보내기…"를 누른다. 쓰던 USB면 쓰기 대기를 본다.
4. 확인 창에서 볼륨 이름, 용량, "실물 USB입니다", 경고를 확인하고 쓴다.
5. 토스트의 꺼내기를 누른다.
6. 기기에서 곡, 목록, 큐, 파형, 앨범아트를 확인한다.

문제가 있으면 기기에 다시 꽂기 전에 되돌린다(`djc usb-restore --volume <마운트> --allow-physical --confirm <이름>`).
