# djc 읽기·초안 명령과 JSON

다음 명령은 기존 최신 `LibrarySnapshot`을 읽는다.

- `search`
- `track`
- `duplicates`
- `playlists`
- `playlist`
- `histories`
- `history`
- `drafts`

스냅샷이 없으면 오류다. 라이브 DB로 대체하지 않는다. 자동으로 스냅샷을 만들지도 않는다. 먼저 `djc snapshot`을 실행한다. 아니면 `--db <사본.db>`를 준다. 실제 라이브 `master.db` 경로와 그 심볼릭 링크·하드 링크는 거부한다.

읽기 명령은 초안·DB·음원을 변경하지 않는다.

에이전트(Claude Code·Codex)는 이 명령으로 조회·제안한다. 초안은 사용자가 고른 것만 만든다. 이 흐름을 안내하는 스킬은 `skills/djcrate/SKILL.md`다. `.claude/skills/djcrate`와 `.agents/skills/djcrate`는 그 폴더의 링크다. 명령·JSON 계약을 바꾸면 스킬도 함께 고친다.

AI 연동에는 CLI와 스킬을 사용한다. MCP 서버·별도 플러그인은 설치하지 않아도 된다.

`--db`는 이 문서의 DB 읽기 명령에서 쓸 수 있다. 이때 그리드 파일은 사본 DB 옆 `share/PIONEER/USBANLZ`에서 읽는다. 그곳에 그리드 파일이 없어도 라이브 분석 파일로 대체하지 않는다. 기본 스냅샷은 `DJC_REKORDBOX_DIR` 또는 기본 rekordbox 폴더의 `share`에서 분석 파일을 읽는다. 초안은 `DJC_HOME` 또는 기본 DJCrate 데이터 폴더에서 읽는다.

CLI 조회·초안 명령은 `DJC_DB`로 DB를 고르지 않으므로 사본은 `--db`로 지정한다. 시험할 때는 임시 `DJC_HOME`을 `--db`와 별개로 지정한다. 합성 폴더나 사본 폴더인 `DJC_REKORDBOX_DIR`도 함께 지정한다.

사람이 읽는 문구는 macOS 언어 설정(`Locale.preferredLanguages`)을 따른다. `DJC_LANG=ko|en|ja`로 먼저 지정할 수 있다. 예를 들어 `DJC_LANG=en djc search '시험' --json`을 쓴다. 지원하지 않는 언어는 영어로 나온다. JSON의 `code`·칸 이름·데이터는 그대로 둔다. 오류 `message`만 번역한다.

PATH로 옮길 때는 `djc`와 같은 빌드 폴더의 `DJCrate_djc.bundle`도 실행 파일 옆에 둔다. 기존 실행 의존성 `SQLCipher.framework`도 함께 유지한다. 번역 번들이 없으면 한국어 원문으로 실행한다. 개발자용 `djc lab …`은 한국어를 유지한다.

## 환경 변수

| 환경 변수 | 하는 일 |
|---|---|
| `DJC_HOME` | 초안·백업·캐시(`waveforms/`·`analysis/`·`loudness.json`)·오디오 기록(`logs/audio.log`) 폴더를 바꾼다. 스냅샷은 옮기지 않는다. 시험에서는 늘 임시 폴더 |
| `DJC_REKORDBOX_DIR` | rekordbox 폴더 대신 쓸 사본 폴더. 그 안 `share/PIONEER/USBANLZ`는 링크가 아닌 실제 사본. 이 실행의 "라이브"가 이 사본이 된다 |
| `DJC_DB` | 앱이 열 스냅샷(앱 인자 `--db <스냅샷>`과 같음). CLI 조회·초안 명령의 DB 선택에는 쓰지 않는다 |
| `DJC_IDLE_SECONDS` | 재생을 멈춘 뒤 오디오 엔진을 끄기까지의 초. 설정 › 일반보다 먼저 적용 |
| `DJC_LANG` | CLI 문구 언어 `ko`·`en`·`ja` |

시험 전용 장치(`DJC_CIPHER_STRESS`·`DJC_LAYOUT_RECOMPUTE_TESTS` 등)는 [CI 문서의 선택 실행 장치](ci.md#선택-실행-장치)에 있다. 픽스처를 만드는 변수는 앱 자가 테스트 스킬(`.claude/skills/app-selftest/SKILL.md`)에 있다.

## 사용법

아래 ID·이름·경로는 모두 합성 데이터 예시다.

```sh
djc search '시험' --bpm 120-130 --key 8A --playlist p1 --filter all --db /tmp/djc-fixture/master.db --json
djc track 101 --db /tmp/djc-fixture/master.db --json
djc duplicates --db /tmp/djc-fixture/master.db --json
djc playlists --tree --db /tmp/djc-fixture/master.db --json
djc playlist p1 --db /tmp/djc-fixture/master.db --json
djc histories --db /tmp/djc-fixture/master.db --json
djc history h1 --db /tmp/djc-fixture/master.db --json
djc drafts --db /tmp/djc-fixture/master.db --json
djc report --db /tmp/djc-fixture/master.db --files --json
djc path '시험' --db /tmp/djc-fixture/master.db --json
djc parse 'TVA 시험 OP 1' --json
djc compat --db /tmp/djc-fixture/master.db --json
```

`--json`을 빼면 사람이 읽는 출력이다. 기존 `report`, `path`, `parse`, `compat`의 일반 출력은 유지한다. 다음 명령은 이 JSON 계약에 포함하지 않는다.

- 분석·파일 생성: `analyze`, `snapshot`, `cache`, `schema-dump`
- 실험: `lab`
- 쓰기: `reflection-dry-run`, `cue-write`, `track-add`, `track-delete`, `playlist-write`, `rekordbox-restore`, `snapshot-point`, `xml-export`

`xml-diff --json`은 같은 봉투를 쓴다. 다만 자기 모양을 가진다([아래](#rekordbox-xml과-비교하기xml-diff)).

**CLI 동의 규칙**: `djc`에는 대화형 질문이 없다. 플래그가 곧 동의다.

- 동의 플래그: `--live`, `--allow-physical --confirm <볼륨 이름>`, `--discard-device-changes`, `--overwrite`
- 파일을 만드는 명령(`xml-export`, `reflection-dry-run --out`, `schema-dump`)은 출력 파일이 이미 있으면 `--overwrite` 없이는 거부한다.
- lab 쓰기 실험은 라이브 DB·실제 분석 폴더를 거부한다. 대상은 `gain-write-test`, `tag-write-test`, `artwork-write-test`, `analysis-attach-test`, `cue-write-selftest`다.
- 거부하면 오류 메시지와 함께 종료 코드 1로 끝난다.

검색 규칙은 다음과 같다.

- 대상은 제목, 아티스트, 코멘트, 장르다. 대소문자를 무시한 부분 검색이다.
- 빈 검색어 `''`는 전체를 뜻한다. 삭제 표시가 있는 곡은 항상 뺀다.
- BPM은 양 끝을 포함하는 양수 범위다.
- 키는 대소문자를 무시한 정확한 일치다.
- 조건은 모두 함께 적용한다.
- Spotify 제목·아티스트가 암호화돼 있으면 검색 대상에서 뺀다.
- `path`는 기존과 같이 제목의 대소문자를 구분한다. 로컬 곡만 찾는다.
- 일반 출력은 라이브러리(DB) 순서다. `--json`은 문자열 ID 순서다.

`search`·`report`는 `--comment-preset none|anisong`을 받는다. 기본값은 `none`이다. `off-convention`은 `--comment-preset anisong`이 있어야 한다. 없으면 `invalid_arguments`로 거절한다. `report`의 `commentClasses`·`prefixes`·`usages`는 이 프리셋을 지정할 때만 나온다. `parse`는 프리셋 옵션 없이 애니송 코멘트 규칙을 검사한다.

`--filter`는 다음 이름 중 하나다. 앱과 같은 판정을 쓴다. 생략하면 `all`이다.

| 이름 | 조건 |
|---|---|
| `all` | 전체 컬렉션 |
| `empty-comment` | 빈 코멘트 |
| `off-convention` | 규칙 밖 코멘트(구형·잔재·크레딧·기타) |
| `no-cues` | 자동 큐를 포함해 큐가 하나도 없음 |
| `played` | 재생 이력 있음 |
| `streaming` | 스트리밍 곡 |
| `no-bpm` | BPM이 없는 로컬 곡 |
| `missing-file` | 음원 파일을 찾지 못한 로컬 곡. 연결되지 않은 외장 디스크도 포함. 스트리밍 곡은 제외 |
| `tempo-change` | 읽은 그리드에 변속 흐름 있음. 분석 파일을 읽지 못하면 제외 |

일반 재생 목록은 원래 곡 순서와 중복을 보존한다. 폴더를 `playlist` 또는 검색의 `--playlist`에 주면 하위 목록을 순서대로 합친다. 같은 곡은 첫 등장만 남긴다. 삭제한 곡 ID와 없는 곡 ID는 뺀다. 목록·폴더는 `sequence` 순서로 늘어놓는다. 같은 순번이면 ID 순서다.

검색 결과는 문자열 ID 순서다.

### 중복 후보

`duplicates`와 앱 사이드바의 **중복 후보**는 스냅샷의 제목·아티스트·길이만 비교한다. 음원을 열지 않는다. 음향 지문도 계산하지 않는다. 같은 녹음임을 보장하지 않는다. 다음 기능은 지원하지 않는다.

- 합치기
- 큐 이동
- 재생 목록 변경
- 곡 삭제

- 제목·아티스트는 다음 순서로 정규화한다.
  - NFC로 맞춘다. 소문자로 바꾼다.
  - 앞뒤 공백을 제거한다. 연속 공백은 한 칸으로 줄인다.
  - 괄호 속 버전(예: Live·Remix), 악센트, 문장부호, 전각·반각 차이는 보존한다.
- 제목·아티스트가 모두 있는 로컬 곡만 비교한다. 길이도 양수여야 한다. 삭제·스트리밍·암호화 제목은 제외한다. 파일 형식·경로가 달라도 후보다. 같은 경로의 서로 다른 ContentID도 후보가 될 수 있다.
- 묶음 안 최장·최단 길이 차이는 **2초 이내**다. 부분 묶음은 생략한다. 합성 예 180·182·184초는 `[180, 182]`, `[182, 184]`로 겹쳐 표시해 모든 후보 쌍을 보존한다. 한 곡이 여러 묶음에 나올 수 있다.
- 곡은 길이·문자열 ID 순서다. 묶음은 첫 곡 ID 순서다. 메타데이터별로 나눈 뒤 정렬·구간 탐색한다. 앱은 이 계산을 스냅샷 로드의 백그라운드 작업에서 한다.
- 비교 수치는 초안을 적용하지 않은 스냅샷 기준이다.
  - 큐 수는 자동 큐를 포함한다. 수동 큐 수도 별도로 제공한다.
  - 재생 목록 수는 곡을 직접 포함한 목록만 센다. 같은 목록의 반복 항목·상위 폴더는 중복 집계하지 않는다.
  - 재생 횟수는 삭제하지 않은 재생 기록 수다.
- 앱은 묶음별로 다음 항목을 보여 준다.
  - 큐
  - 재생 목록
  - 재생 횟수
  - 형식
  - 비트레이트
  - 길이
  - 경로
- 검색은 일치하는 곡의 비교 상대까지 남긴다.
- 곡을 한 번 누르면 고르기만 한다. 더블클릭·Return·오른쪽 클릭 "덱에 불러오기"로 덱에 올린다.
- 비트레이트가 0 이하이거나 없으면 `알 수 없음`으로 표시한다.

### 파일 없는 곡의 새 위치 후보

앱의 `파일 없음` 필터에서 **폴더에서 찾기…**를 누르면 고른 폴더 아래 음원을 훑는다. 파일이 없는 곡마다 새 위치 후보를 찾아 확실·애매·없음으로 미리 보여 준다(#62). 읽기만 한다. rekordbox·음원에는 쓰지 않는다. 고른 결과도 저장하지 않는다.

경로를 rekordbox에 쓰는 단추는 막아 두었다. 경로 바꾸기 쓰기 규칙을 rekordbox 실험으로 확인하기 전까지 열지 않는다.

`djc lab relocate-candidates --db <사본.db> --folder <폴더>`는 같은 판정으로 분류별 개수만 찍는다. 곡 제목·경로는 찍지 않는다.

- 훑기 규칙:
  - 심볼릭 링크(파일·폴더)는 따라가지 않는다.
  - 다음은 건너뛴다. 그 폴더는 후보 폴더로 고를 수 없다.
    - 숨은 파일
    - `._*`
    - USB의 `PIONEER` 폴더
    - 패키지
    - rekordbox/DJCrate 데이터 폴더
  - rekordbox가 읽는 확장자만 본다.
  - 이름(대소문자를 접음)이나 이름 줄기·크기가 어느 곡과 맞는 파일만 길이·태그를 읽는다.
  - 취소할 수 있다. 메인 스레드를 막지 않는다.
- 점수는 이름을 NFC로 맞춘 뒤 비교한다.
  - 이름이 글자까지 같음 40
  - 대소문자만 다름 36
  - 확장자만 다름 20
  - 크기가 바이트까지 같음 25
  - 길이가 ±2초 안 20
  - 제목 태그 같음 10
  - 아티스트 태그 같음 5
  - 모두 맞으면 100
  - 곡 행의 길이·크기가 0이거나 파일을 읽지 못해 모르는 값은 점수도 감점도 없다.
  - 양쪽 길이를 알 때 오차를 넘으면 후보에서 뺀다.
- 40점 이상이 후보다. 분류는 세 가지다.
  - **확실**: 아래 조건을 모두 만족한다.
    - 80점 이상
    - 확장자가 같음
    - 1위와 10점 안쪽인 다른 후보가 없음
    - 다른 곡이 같은 파일을 비슷하거나 더 잘 맞는 주 후보로 삼지 않음
  - **애매**: 그 밖에 후보가 있다. 사람이 고른다. 이유는 다음 중 하나다.
    - 후보 여럿
    - 같은 파일을 다른 곡도 후보로 삼음
    - 확장자 다름
    - 근거 부족
  - **없음**: 후보가 없다.
- 상수는 `RelocateRules`에 모여 있다. `RelocateMatcherTests`가 고정한다.
- 이름도 크기도 어느 곡과 맞지 않는 파일은 찾지 못한다. 이름과 크기가 모두 바뀐 파일이 그렇다. rekordbox의 Auto Relocate가 무엇으로 찾는지는 아직 실험으로 확인하지 않았다.
## JSON v1

성공하면 stdout에 JSON 문서 하나와 줄바꿈만 출력한다. 종료 코드는 0이다.

```json
{"schemaVersion":1,"command":"search","data":{"tracks":[]}}
```

실패하면 stdout은 비운다. stderr에 JSON 문서 하나를 출력하고 종료 코드는 1이다.

```json
{"schemaVersion":1,"command":"track","error":{"code":"not_found","message":"곡을 찾지 못했습니다. search로 ContentID를 확인하세요"}}
```

오류 코드는 네 가지다.

- `invalid_arguments`: 인자 오류.
- `not_found`: 곡이나 재생 목록 ID를 찾지 못함.
- `live_database`: 라이브 DB를 줌.
- `read_failed`: 그 밖의 읽기·호환성 오류.

JSON 키는 영문이고 ID·UUID는 문자열이다. 선택 값이 없으면 키를 생략한다. 빈 목록은 `[]`다. 필드 추가에 대비해 소비자는 모르는 키를 무시한다. 의미나 타입이 달라지는 변경은 `schemaVersion`을 올린다.

| 명령 | `data` |
|---|---|
| `search` | `{tracks: Track[]}` |
| `duplicates` | `{lengthToleranceSeconds: 2, groups: [{id: string, tracks: DuplicateMember[]}]}` |
| `track` | `{track: Track, cues: Cue[], grid: Grid, gain?: Gain, playlists: Playlist[], drafts: DraftState}` |
| `playlists` | `{playlists: Playlist[]}`; `--tree`면 루트부터 `children`으로 중첩 |
| `playlist` | `{playlist: Playlist, tracks: Track[]}` |
| `drafts` | `{drafts: Draft[]}`; UUID 순서, 컬렉션에 없는 초안도 포함 |
| `histories` | `{histories: History[]}` |
| `history` | `{history: History, entries: HistoryEntry[]}` |
| `report` | 아래 집계 필드 |
| `path` | `{paths: string[]}` |
| `parse` | `{classification: string, parsed?: ParsedComment}` |
| `compat` | `{appVersion?: string, verifiedAppVersions: string[], databaseVersion: string, localUpdateCount?: number, cloudUpdateCount?: number}` |
| `usb-info` | `UsbInfo`(아래 "USB 읽기") |

- `DuplicateMember`: 아래 필드를 가진다.
  - `track`(Track).
  - 정수 `cueCount`, `manualCueCount`, `playlistCount`, `playCount`.
  - 문자열 `format`.
  - 선택 정수 `bitrateKbps`(양수 kbps).
  - 선택 문자열 `imagePath`(rekordbox `ImagePath`, `/PIONEER/Artwork/…/artwork.jpg`).
  - 비트레이트를 모르거나 앨범아트가 없으면 그 키를 생략한다.
  - 묶음 `id`는 첫 곡의 ContentID다.
- `Track`: 아래 필드를 가진다.
  - 항상 있는 필드: `id`, `uuid`, `title`, `lengthSeconds`, `path`, `comment`, `isStreaming`.
  - 선택 필드: `artist`, `album`, `albumArtist`, `genre`, `composer`, `releaseYear`, `trackNumber`, `key`, `bpm`, `importedOn`.
  - 연도, 트랙 번호, 길이, BPM은 숫자다.
  - `importedOn`은 `YYYY-MM-DD`다.
  - 값은 사본 DB 기준이다. 초안으로 덮어쓰지 않는다.
- `Cue`: 아래 필드를 가진다.
  - 항상 있는 필드: `id`, `kind`, `inMsec`, `outMsec`, `name`, `isLoop`, `activeLoop`, `isAutoGenerated`.
  - `kind` 0은 메모리이고, 그 밖의 값은 rekordbox 슬롯 값이다.
  - 선택 필드: `hotCueSlot`(A~H), `loopBeats`, `color`, `colorTableIndex`.
  - 시각은 rekordbox 시간축의 밀리초다.
  - `outMsec`는 원본 값이다. 루프 판정은 `isLoop`를 쓴다.
  - 순서는 시작 시각, ID 순이다.
- `Grid`: 아래 필드를 가진다.
  - `status`(`available` 또는 `unavailable`), `beatCount`, `segments`, `tempoChanges`.
  - 각 구간은 `{start: number, bpm: number, firstBeatNumber: number}`이고 `start`는 rekordbox 시간축의 초다.
  - 분석 경로·파일·유효한 박이 없으면 `unavailable`, 개수 0, 빈 배열을 반환한다.
- `Gain`: `linear`, `decibels`, 선택 `peak`(선형 피크). 유효한 게인 행이 없으면 `gain`을 생략한다.
- `Playlist`: `id`, `name`, `parentID`, `sequence`, `isFolder`, `trackCount`.
  - `--tree`의 폴더에만 `children` 배열이 있다.
  - `trackCount`는 조회 가능한 곡 수다. 폴더는 중복을 제거한 수다.
  - 곡 상세의 소속에는 직접 포함한 재생 목록만 담는다.
- `History`: `id`, `name`, `trackCount`, 선택 문자열 `dateCreated`.
  - `histories`는 날짜순이다.
  - `trackCount`는 반복 재생을 포함한 조회 가능한 항목 수다.
- `HistoryEntry`: `id`, 정수 `trackNumber`, `track`(Track). 같은 곡을 여러 번 재생한 항목은 그대로 남긴다.
- `DraftState`: `cue`, `grid`, `gain`, `tag`, `artwork` 불리언 다섯 개다.
  - `artwork`는 앨범아트 초안이다.
  - 앨범아트 초안은 앱에서만 만든다.
- `Draft`: `trackUUID`, `kinds`, 선택 `contentID`, `title`.
  - `kinds`의 순서는 `cue`, `grid`, `gain`, `tag`, `artwork`다.
  - 컬렉션에 없으면 마지막 두 필드를 생략한다.
  - 큐·그리드·태그는 읽을 수 있고 실제 변경이 있는 초안만 센다.
  - 게인은 저장된 값이 있는 초안만 센다.
  - 앨범아트는 초안과 앨범아트 사본을 읽을 수 있는 초안만 센다. 앨범아트 초안은 앱에서만 만든다.
  - 손상된 초안의 진단과 반영 가능 여부 판정은 하지 않는다.
- `report`: 아래 필드를 가진다.
  - 정수 `totalRows`, `deletedRows`, `liveTracks`, `streamingTracks`, `tracksWithCues`, `tracksWithManualCues`, `tracksWithOnlyAutoCues`, `tracksWithoutCues`, `playedTracks`, `emptyCommentPlayed`.
  - 문자열→정수 사전 `extensions`, `emptyByImportYear`, `hotCueSlots`.
  - `--comment-preset anisong`일 때만 `commentClasses`, `prefixes`, `usages`.
  - `--files`를 주면 정수 `missingFiles`를 더한다.
- `ParsedComment`: 아래 필드를 가진다.
  - 항상 있는 필드: `prefix`, `workRef`, `workName`, `abbreviations`, `usages`(`{kind, numbers}` 배열), `episodes`, `isCharacterSong`, `isTVSize`, `variants`, `isFormerAffiliation`, `boomboxVolumes`.
  - 선택 필드: `season`, `seasonStyle`, `airingYear`, `airingQuarter`, `movieYear`.
  - `seasonStyle`은 `parenthesized`, `plain`, `season` 중 하나다.
  - `classification`은 `convention`, `legacy`, `residue`, `credit`, `empty`, `other` 중 하나다.

`compat` 성공은 기존 앱 버전·DB 구조·카운터 검사를 통과했다는 뜻이다. rekordbox 실행 여부 등 실제 쓰기 사전 확인을 대체하지 않는다.

## 큐·태그 초안 만들기

`djc draft`는 위 읽기 명령과 같은 스냅샷 경로를 쓴다. 이 경로는 유스케이스 `QueryLibrary`가 사본을 정하고 라이브 DB를 거부하는 길이다. 그래서 `djc draft`도 라이브 DB를 거절한다. 초안 파일은 유스케이스 `EditDraftFiles`가 고친다.

- DB·분석 파일·음원에는 쓰지 않는다.
- 앱과 같은 JSON을 `DJC_HOME`의 `cue-drafts/`·`tag-drafts/`에 저장한다.
- 처음 만들 때 스냅샷의 rekordbox 값을 `base`에 담는다.
- 기존 초안을 이어 고칠 때는 그 `base`와 다른 편집을 보존한다.
- rekordbox 반영은 앱에서 사람이 별도로 실행한다.

```sh
# 시험할 때는 반드시 임시 DJC_HOME을 쓴다.
export DJC_HOME="$(mktemp -d)"
djc draft cue 101 --time 12.5 --name '진입' --db /tmp/djc-fixture/master.db --dry-run --json
djc draft cue 101 --slot B --time 16 --loop-end 20 --beats 8 --active --db /tmp/djc-fixture/master.db
djc draft tag 101 --title '합성 제목' --artist '합성 가수' --comment '' --db /tmp/djc-fixture/master.db --json
djc draft rm cue 101 --db /tmp/djc-fixture/master.db --dry-run --json
djc draft rm tag 101 --db /tmp/djc-fixture/master.db
```

- `draft cue <ContentID> --time <초>`: 기본은 메모리 큐다.
  - `--slot A`~`H`를 주면 해당 핫큐를 놓거나 교체한다.
  - `--name`은 이름이다.
  - 시각은 **rekordbox 시간축의 초**이며 자동 퀀타이즈하지 않는다.
- `--loop-end <초>`는 시작보다 뒤인 루프 끝이다.
  - 선택 `--beats <박 수>`는 양의 정수 또는 1/n이다.
  - `--active`는 활성 루프 지정이다.
  - 두 옵션은 `--loop-end`와 함께 쓴다.
  - 활성 루프는 곡에 하나만 남는다.
- 메모리 큐는 rekordbox 자동 큐(`CUE(Auto)`·`1.1Bars`)를 포함해 10개까지다.
  - 자동 큐도 앱 덱처럼 초안에 메모리 큐로 들어간다.
  - 자동 큐 없이 만든 옛 초안을 이어 고치면 곡의 자동 큐를 `base`·`cues`에 채워 저장한다(#145).
  - 같은 자리 ±30ms의 기존 메모리 큐는 앱처럼 그대로 사용한다. 루프를 추가할 때는 기존 루프만 해당한다.
  - 새 이름이나 루프 길이로 그 큐를 덮어쓰지는 않는다.
- `draft tag <ContentID>`: 아래 옵션 중 하나 이상을 준다.
  - `--title`, `--artist`, `--album`, `--album-artist`, `--genre`, `--composer`.
  - `--year`, `--track-number`, `--comment`, `--musical-key`, `--rating`, `--color`.
  - 빈 문자열은 해당 값을 비운다.
  - 빈 제목과 숫자가 아닌 연도·트랙 번호는 거절한다.
- `--musical-key`는 rekordbox 키 목록의 Camelot 이름(`1A`~`12B`)만 받는다.
  - `8a`·` 08B `는 `8A`·`8B`로 다듬는다.
  - `''`는 키를 지운다.
  - `Am` 같은 다른 표기는 `invalid_arguments`로 거절한다.
  - 초안을 쓰는 rekordbox에 그 이름의 살아 있는 키 줄이 하나가 아니면, 미리 보기와 쓰기가 그 곡만 막고 이유를 알린다.
  - 추가한 곡(ContentID 없음)의 키는 앱에서 고르면 곡을 넣을 때 함께 쓴다.
  - `djc track-add`에는 키 옵션이 없다. 곡을 넣은 뒤 `draft tag`로 고친다.
- `--rating`은 평점 별 수 `1`~`5`다. `★★★`도 받는다. `0`·`''`는 평점을 지운다.
- `--color`는 곡 색 번호 `1`~`8`이나 rekordbox 색 이름이다.
  - 색 이름은 `Red`·`blue`처럼 대소문자를 구분하지 않는다.
  - `0`·`''`는 색을 지운다.
  - 그 밖의 값은 `invalid_arguments`다.
- 평점·곡 색은 쓰기를 확인한 곡에서만 초안을 만든다(#65).
  - 확인한 곡은 동기화 상태 0·256·257인 곡이다. 재생 목록에 든 곡도 포함한다.
  - 그 밖의 곡(상태 258 등)은 `unverified_field`로 거절한다. 다른 칸은 그대로 초안을 만든다.
  - 재생 목록에 든 곡의 평점·곡 색을 쓰면 다른 곡 정보 칸처럼 그 곡이 든 목록의 `masterPlaylists6.xml` Timestamp도 고친다.
- `draft rm cue|tag <ContentID>`는 해당 종류의 **초안 전체**를 버린다.
  - 개별 큐나 rekordbox 원본을 지우지 않는다.
  - 이미 없는 초안을 지우는 것은 성공이다.
  - 그리드·게인 초안은 그대로 둔다.
- `--dry-run`은 같은 검증을 거쳐 결과를 보여 준다. 폴더·파일을 만들거나 지우지 않는다. 기존 초안이 손상되었으면 덮어쓰지 않고 오류를 낸다.

앱은 실행 중 약 1초마다 큐·태그 초안 파일 변경을 확인한다. 변경이 있으면 목록의 편집 표시·큐 개수·태그 편집기와 현재 덱의 큐를 갱신하고 재생 위치를 유지한다. 큐·그리드를 드래그하는 동안에는 저장 후에 다시 읽는다. 태그가 외부에서 바뀌면 오래된 되돌리기 기록은 비운다. 태그 초안은 태그 편집기와 쓰기를 기다리는 초안 목록에 표시된다.

앱에서 사람이 초안을 미리 보고 rekordbox에 쓸 수 있다. 초안 종류는 큐, 그리드, 게인, 태그, 재생 목록이다. 태그는 rekordbox 곡 정보에만 쓴다. 음원 파일의 태그는 바꾸지 않는다. 같은 곡을 앱과 CLI에서 동시에 편집하면 마지막 저장이 앞선 저장을 덮을 수 있다. 그러므로 편집을 마친 뒤 다음 명령을 실행한다.

`--json`은 위 JSON v1 성공/오류 출력 규칙을 따른다. `command`는 `draft`다. `data`는 `{kind: "cue"|"tag", action: "save"|"remove", contentID, trackUUID, dryRun, hasChanges, cue?, tag?}`다.

- 저장·미리보기의 `cue` 또는 `tag`에는 앱 파일과 같은 초안 전체(`base` 포함)가 담긴다.
- `hasChanges`는 명령을 적용한 뒤 남을 초안의 변경 여부다. 삭제는 `false`다.
- 원본으로 되돌아간 초안은 저장소에서 제거된다.

추가 오류 코드는 세 가지다.

- `invalid_draft`: 기존 초안 손상, 큐 한도.
- `draft_io_failed`: 초안 저장·삭제 실패.
- `unverified_field`: 쓰기를 확인하지 않은 곡의 평점·곡 색.

기존 `invalid_arguments`, `not_found`, `live_database`, `read_failed`도 사용한다. 실패하면 종료 코드 1이다. JSON은 stderr에만 나온다.

앱은 재생 목록 초안을 지원하지만 `djc draft`의 대상은 큐·태그뿐이다. `playlist-write`는 JSON 편집을 DB에 쓰는 명령이다. DJCrate 재생 목록 초안 생성 명령이 아니다. 에이전트 스킬에서는 실행하지 않는다. 사람이 앱에서 재생 목록 초안을 만들도록 안내한다.
## 쓰기 명령(사본에만)

rekordbox 라이브러리에 쓰는 명령이다. 앱과 같은 반영 세션과 쓰기 관문을 지난다. 순서는 사전 확인, 전체 백업, 한 트랜잭션, 검증이다. 실패하면 복원한다. CLI는 쓴 뒤 초안 정리와 되살리기를 하지 않는다.

대상은 늘 명시한다.

- `--db <사본.db>`: 백업은 사본 옆 `backups/`에 둔다.
- `--live`: rekordbox 폴더를 가리킨다. `DJC_REKORDBOX_DIR`이 있으면 그 사본을 가리킨다.

둘 다 없으면 사용법 오류다. 시험과 실험은 사본에만 한다. 임시 `DJC_HOME`을 함께 준다. 사본을 쓸 때도 `--db <사본 폴더>/master.db`로 적는다.

에이전트는 `--live`로 실행하지 않는다. 라이브 쓰기는 사람이 앱에서 하거나 터미널에서 직접 실행한다. Claude Code 훅도 에이전트의 `--live` 실행을 막는다.

```sh
djc cue-write --db <사본.db> [--dry-run]                                 # 초안을 사본에 써 보기
djc track-add --db <사본.db> --share <폴더> --analyze <음원…>            # 곡 넣기(분석까지)
djc track-delete --db <사본.db> --share <폴더> <ContentID…>              # 곡 빼기
djc playlist-write --db <사본.db> [--dry-run] <편집.json>                # 재생 목록 편집(JSON)
djc rekordbox-restore --backup <폴더> --db <사본.db>                     # 쓰기 전 백업으로 되돌리기
```

함께 쓰는 읽기 명령은 라이브러리에 쓰지 않는다.

```sh
djc snapshot [--force]                                                   # 라이브 DB를 읽어 DJCrate 스냅샷 폴더에 읽기용 사본(rekordbox가 켜져 있으면 --force일 때만)
djc lab                                                                  # 실험 명령 목록(sql·db-diff·loop-repro·seekinfo-check …)
djc lab sql <사본.db> "SELECT …"                                         # 사본에 읽기 전용 질의(agentRegistry는 막는다)
```

사본 재현 실험(`lab loop-repro`·`vbr-cue-repro`·`playlist-repro`)은 `--work` 폴더를 통째로 지우고 다시 만든다. 그래서 USB 실험 도구와 같이 임시 폴더(`mktemp -d`) 아래만 받는다. 다음 폴더는 지우기 전에 거부한다.

- 임시 폴더 뿌리 자체
- rekordbox 폴더나 DJCrate 데이터 폴더를 품은 폴더
- rekordbox 폴더나 DJCrate 데이터 폴더 안에 있는 폴더

## 캐시 보기·비우기(`cache`)

```sh
djc cache                                   # 종류별 용량(논리 크기 합)
djc cache --clear waveforms analysis --dry-run   # 지울 양만 보기
djc cache --clear all                       # 모든 종류 비우기
```

캐시는 앱이 다시 만든다. 그래서 따로 묻지 않는다. 플래그가 곧 동의다. 종류는 허용 목록 하나(`DJCCacheKind`)뿐이다. 지우는 규칙은 `DJCCache` 한 곳에 있다.

| 종류 | 자리 | 비우는 것 | 다시 만들어지는 때 |
|---|---|---|---|
| `waveforms` | `waveforms/` | 하위 파일(폴더는 남김) | 곡을 덱에 불러올 때 |
| `analysis` | `analysis/`(`grid-estimates/`·`chroma/` 포함) | 하위 파일(폴더는 남김) | 곡을 덱에 불러오거나 분석할 때 |
| `loudness` | `loudness.json` | 파일 | 곡을 덱에 불러올 때 |
| `preview-waveforms` | `preview-waveforms.plist` | 파일 | 곡 목록을 그릴 때 |
| `usb-snapshots` | `usb-snapshots/<볼륨키>/<시각>/` | 볼륨마다 가장 새 사본을 뺀 나머지 | USB를 열 때 |
| `snapshots` | 스냅샷 폴더(`DJC_REKORDBOX_DIR`이 있으면 그 안 `djc-snapshots/`) | 가장 새 사본을 뺀 나머지(곁 `-wal`·`-shm`·`.itunes.json` 포함) | rekordbox와 동기화할 때 |

- 다음 항목은 어떤 종류에도 없어 지우지 않는다.
  - 초안(`*-drafts/`·`*-drafts.json`)
  - `staged.json`
  - `playlist-imports.json`
  - `damaged-drafts/`
  - `usb-drafts/`
  - `usb-sessions/`
  - `usb-staging/`
  - `usb-physical-{allow,deny}.json`
  - `rekordbox-backups/`
  - `point-snapshots/`
  - `usb-backups/`
  - 편집본 음원
  - 연동 XML
- `usb-snapshots`는 다음 경우에 통째로 건너뛰고 이유를 적는다.
  - USB 쓰기·회복·되돌리기가 볼륨 잠금을 잡고 있다.
  - 닫히지 않은 저널(`usb-sessions/<볼륨키>.json`)이 있다.
- `usb-snapshots`는 쓰기 세션 사본(`local-`·`usb-`·`info-`)을 건드리지 않는다.
- `snapshots`는 뜨는 중인 `.part`를 건드리지 않는다. 앱 화면(설정 › 저장 공간)에서 비우면 앱이 연 사본도 남긴다.
- CLI는 앱이 연 사본을 모른다. 그래서 앱을 `--db`로 옛 사본에 연 채 비우지 않는다.
- 크기는 논리 크기 합이다. 같은 APFS 볼륨의 복사는 클론이라 실제로 비는 양은 더 작을 수 있다.
- 앱이 켜져 있으면 앱이 기억한 음량·목록 미리 보기 파형을 나중에 다시 저장할 수 있다. 앱에서는 설정 › 저장 공간에서 비운다.

## 시점 스냅샷(`snapshot-point`)

이 명령은 라이브러리 읽기 사본을 뜨는 `djc snapshot`과 다르다. rekordbox 라이브러리에서 DJCrate가 쓰는 파일을 한 시점으로 남긴다. 대상 파일은 다음과 같다.

- `master.db`
- `masterPlaylists6.xml`
- `playlists3.sync`
- 분석 파일
- 앨범아트 폴더

규칙은 [규칙](rekordbox-internals.md#시점-스냅샷-rekordboxpointsnapshot-220223224)에 있다.

```sh
djc snapshot-point create --name "큰 정리 전" --live   # rekordbox를 끈 뒤. DJCrate 데이터 폴더의 point-snapshots/에
djc snapshot-point list --live                       # 시점 스냅샷과 쓰기 전 백업을 함께(최근 것부터)
djc snapshot-point pin 2026-10-07T120000Z-manual --live   # 고정(자동 정리에서 뺀다). unpin으로 푼다
djc snapshot-point delete "큰 정리 전" --live         # 고정하지 않은 것만. ID 대신 겹치지 않는 이름도 받는다
djc snapshot-point diff "큰 정리 전" --live           # 그 시점으로 복원하면 바뀌는 것(곡·큐·그리드·곡 정보·재생 목록·파일 수, 읽기만)
djc snapshot-point restore "큰 정리 전" --live        # 그 시점으로 복원(rekordbox를 끈 뒤). 복원 직전 상태는 '복원 직전' 스냅샷으로 남는다
# 시험할 때는 합성 사본만: 스냅샷은 사본 옆 point-snapshots/에 둔다.
djc snapshot-point create --db <사본 폴더>/master.db [--share <사본 폴더>/share]
```

- rekordbox·rekordboxAgent가 켜져 있으면 스냅샷을 뜨지 않는다. WAL이 남아 있을 때도 뜨지 않는다. 뜨는 동안 라이브러리가 바뀌면 스냅샷을 버린다.
- 같은 APFS 볼륨이면 클론이라 처음엔 공간을 거의 쓰지 않는다. 다른 디스크면 전체 복사했다고 알린다.
- `restore`는 묻지 않는다. 플래그가 곧 동의다.
  - 다른 라이브러리나 망가진 스냅샷은 거부한다.
  - 끝나면 복원 전으로 돌리는 명령(`restore <복원 직전 ID>`)을 알린다.
  - 시점 복원 뒤에는 그보다 옛 쓰기 전 백업을 `rekordbox-restore`로 되돌리지 않는다.
- 자동 정리는 다음만 남긴다.
  - 수동·고정 스냅샷은 지우지 않는다.
  - 자동 스냅샷은 최근 7일과, 그보다 오래된 것 중 가장 최근 하나를 남긴다. 앱 설정 › 저장 공간에서 일수를 바꾼다.
  - 복원 직전 스냅샷은 최근 3개만 남긴다.
- CLI는 앱이 DJCrate 데이터 폴더의 `shared-settings.json`에 적어 둔 일수를 따른다. 파일이 없으면 기본값을 쓴다.
- 하루 한 번 자동 스냅샷(#228)은 앱이 남긴다. CLI에는 자동으로 뜨는 명령이 없다.

## 라이브러리 XML 내보내기(`xml-export`)

```sh
djc xml-export --db <스냅샷 사본.db> --out <파일.xml> [--share <분석 파일 폴더> | --no-analysis] [--overwrite] [--dry-run]

# djc snapshot 사본 옆에는 share가 없으니 rekordbox 폴더의 share를 준다(읽기만).
djc xml-export --db <스냅샷 사본.db> --out ~/Desktop/library.xml --share ~/Library/Pioneer/rekordbox/share

# 시험할 때는 합성 사본과 임시 폴더만 쓴다.
export DJC_HOME=$(mktemp -d)
djc xml-export --db /tmp/djc-fixture/master.db --out /tmp/djc-fixture/library.xml
```

이 명령은 라이브러리 전체를 rekordbox XML(`DJ_PLAYLISTS`) 한 파일로 내보낸다. 전체는 곡, 큐, 그리드, 재생 목록 트리다. 다른 DJ 소프트웨어나 도구로 옮길 때 쓴다. 백업 사본으로 둘 때도 쓴다.

기존 "XML 만들기"는 rekordbox로 되가져오는 연동 파일이다. 이 명령은 그것과 별개다. 그쪽 출력은 바뀌지 않는다.

- **분석 파일 폴더가 있어야 한다.** `--share`를 빼면 사본 DB 옆 `share`를 쓴다. `djc snapshot` 사본 옆에는 그 폴더가 없다.
  - 그대로 두면 모든 곡의 TEMPO가 조용히 빠진다. 그래서 폴더가 없으면 오류로 멈춘다. 폴더를 뺀 경우와, 준 `--share`가 없는 폴더인 경우 모두 같다.
  - 이때는 `--share <rekordbox 폴더>/share`를 준다.
  - 그리드 없이 내보내려면 `--no-analysis`를 명시한다. `--share`와 함께 줄 수 없다.
- **읽기만 한다.** 사본 DB와 분석 파일은 고치지 않는다. 라이브 분석 파일로 대신하지도 않는다.
  - 쓰는 곳은 `--out` 파일 하나뿐이다.
  - 같은 폴더의 임시 파일에 다 쓴 뒤 바꿔 끼운다. 도중에 실패해도 있던 파일은 그대로다.
  - 라이브 `master.db`는 입력으로도 거부한다.
- 출력은 `.xml` 파일만 받는다. 실수로 `master.db`를 덮지 않게 하기 위해서다. 다음 위치는 DB를 열기 전에 거부한다.
  - rekordbox 폴더 안: `~/Library/Pioneer`와, 개발 때의 `DJC_REKORDBOX_DIR`
  - USB의 `PIONEER/` 아래(`/Volumes/<볼륨>/PIONEER/…`, 대소문자 무시)
  - DJCrate 데이터 폴더(`~/Library/Application Support/DJCrate`·`DJC_HOME`). 특히 `rekordbox-backups`와 `usb-backups`를 조심한다. 백업의 `masterPlaylists6.xml`을 덮으면 "쓰기 전으로 복원"이 그것을 라이브로 옮긴다.
  - 위 위치들을 가리키는 링크
  - DJCrate 연동 XML 자리(`~/Documents/DJCrate/djcrate-rekordbox.xml`)
- 이미 있는 파일은 `--overwrite`를 줘야 바꾼다. `--dry-run`은 개수만 알린다.
- **쓰지 않은 초안은 넣지 않는다.** 초안은 무시한다. 초안 종류는 큐, 그리드, 태그, 게인, 앨범아트, 재생 목록이다. rekordbox 사본에 있는 그대로 내보낸다.
- 시각은 rekordbox 시간축(초)이다. DB의 큐와 분석 파일의 박이 이미 그 시간축이다. 단위는 둘 다 ms다. 인코더 지연은 더하지도 빼지도 않는다. 기존 XML 경로와 같은 규칙이다.

내보내는 칸은 다음과 같다.

| XML | 출처 |
|---|---|
| `TRACK` `TrackID` | `ContentID`(정수 표기가 아니면 겹치지 않는 번호) |
| `Name`·`Artist`·`Composer`·`Album`·`Genre`·`Comments`·`Tonality`(키 이름)·`Remixer`·`Label` | 곡 행과 연결 표 |
| `Kind`·`Location` | 파일 확장자·`FolderPath`(`file://localhost` + 퍼센트 인코딩) |
| `Size`·`TotalTime`·`DiscNumber`·`TrackNumber`·`Year`·`AverageBpm`·`BitRate`·`SampleRate`·`PlayCount` | `FileSize`·`Length`·`DiscNo`·`TrackNo`·`ReleaseYear`·`BPM`·`BitRate`·`SampleRate`·`DJPlayCount`(없으면 0, `Size`·`AverageBpm`·`BitRate`·`SampleRate`는 값이 없으면 칸을 뺀다) |
| `DateAdded` | `StockDate`(없으면 곡 행을 만든 날) |
| `TEMPO` | 분석 파일의 박 격자(`PQTZ`). 구간마다 첫 박 시각·rekordbox가 적은 BPM·박 번호. 분석 파일이 없으면 뺀다 |
| `POSITION_MARK` | 메모리 큐(`Num` -1)·핫큐 A~H(`Num` 0~7)·루프(`Type` 4, `End`). 자동 큐도 그대로 |
| `PLAYLISTS` `NODE` | 폴더(`Type` 0, `Count`)·재생 목록(`Type` 1, `KeyType` 0, `Entries`), Seq 순서, 같은 곡 중복·곡 순서 그대로 |

넣지 않는 것은 요약의 "뺀 것"에 센다.

- 인텔리전트 재생 목록
- 없는 폴더를 가리켜 ROOT에서 닿지 않는 재생 목록과 폴더. rekordbox 트리에 없으므로 루트에 지어 붙이지 않는다. 요약에서는 "상위 폴더가 없는 목록"이라 부른다.
- My Tag
- 핫큐 색(`Red`·`Green`·`Blue`). rekordbox 색 번호와 XML 색의 대응을 확인하기 전이다.
- 알 수 없는 큐 종류(Kind 4)
- 앨범 아티스트, Grouping, Mix, DateModified, LastPlayed. XML에 칸이 없거나 값의 출처를 확인하지 못했다.
- 스트리밍 곡. 파일 경로가 없다.
- 삭제한 곡
- 스트리밍 곡이나 삭제한 곡을 가리키던 재생 목록 항목

`Rating`·`Colour`는 곡 행에 칸이 생기면(#65) 같은 모양으로 더한다.

앱에서는 파일 메뉴의 "라이브러리 XML 내보내기…"가 같은 일을 한다.

### rekordbox가 직접 내보낸 XML과 견주기

칸 이름과 값의 출처는 rekordbox가 공개한 XML 형식 문서와 기존 XML 경로로 정했다. rekordbox가 만든 XML과의 칸 비교는 아직 하지 않았다(사용자 실험 몫). 비교하려면 다음 순서로 한다.

1. rekordbox 7.2.x에서 파일 › 라이브러리 › **Export Collection in xml format**으로 XML을 rekordbox 폴더 밖에 저장한다.
2. rekordbox를 완전히 종료한다. `djc snapshot`으로 사본을 뜨고 같은 시점의 XML을 만든다: `djc xml-export --db <그 사본.db> --out <파일.xml> --share ~/Library/Pioneer/rekordbox/share`
   - rekordbox 폴더의 분석 파일은 읽기만 한다.
   - `--share`를 빼면 사본 옆에 `share`가 없어 오류로 멈춘다.
3. `python3 -I scripts/xml-compare.py <rekordbox가 만든.xml> <djc가 만든.xml>`을 돌린다.
   - 곡은 `Location`으로 짝짓는다.
   - 칸마다 같음·다름·한쪽에만 있음의 개수를 센다.
   - TEMPO·POSITION_MARK의 곡 단위 일치를 센다.
   - 재생 목록 트리의 경로와 곡 순서를 센다.
   - 값은 찍지 않는다. `--examples N`은 이 Mac에서만 볼 값 예를 찍는다.

rekordbox가 만든 XML에는 곡 정보가 들어 있으니 저장소·이슈에 올리지 않는다. 결과에서 먼저 볼 가정은 다음과 같다.

- `TrackID` = `ContentID`
- `DateAdded` = `StockDate`
- `PlayCount` = `DJPlayCount`
- `Tonality` = 키 이름. rekordbox의 키 표시 설정과 같은지 본다.
- `Kind`와 `Location`의 퍼센트 인코딩. 특수 문자는 `&`, `#`, 괄호 등이다.
- 값이 0일 때 칸을 빼는 칸들: `BitRate`, `SampleRate`, `Size`, `AverageBpm`
- TEMPO의 BPM 반올림과 변속 곡 구간 수
- 자동 큐 포함 여부
- 루프와 핫큐 루프의 `Type`, `End`, `Num`
- rekordbox만 가진 `POSITION_MARK` 칸(색)
- 인텔리전트·My Tag 노드의 모양

## rekordbox XML과 비교하기(`xml-diff`)

```sh
djc xml-diff --db <스냅샷 사본.db> --xml <파일.xml> [--share <분석 파일 폴더> | --no-analysis] [--limit N] [--json | --draft [--only cue,grid,tag,playlist]]

# djc snapshot 사본 옆에는 share가 없으니 rekordbox 폴더의 share를 준다(읽기만).
djc xml-diff --db <스냅샷 사본.db> --xml ~/Desktop/other.xml --share ~/Library/Pioneer/rekordbox/share
```

이 명령은 다른 도구나 rekordbox가 만든 rekordbox XML(`DJ_PLAYLISTS`)을 읽는다. 읽은 XML과 지금 라이브러리의 차이를 보인다. 라이브러리는 스냅샷 사본이다(#72 가져오기). 사본·분석 파일·XML 파일 모두 읽기만 한다. 라이브 `master.db`는 입력으로 거부한다.

분석 파일 폴더 규칙은 `xml-export`와 같다. `--no-analysis`면 그리드를 비교하지 않는다.

- **곡 맞추기**: XML `Location`(`file://localhost/…` 퍼센트 인코딩)을 풀어 파일 경로로 맞춘다.
  - 경로는 NFC로 비교한다. 같은 경로가 없으면 대소문자만 다른 경로가 하나뿐일 때 맞춘다.
  - 라이브러리에 없는 곡은 비교하지 않는다. 개수만 센다. 파일이 아닌 위치도 같다.
  - 여러 곡에 맞는 곡도 비교하지 않는다. 개수만 센다. 라이브러리에 같은 경로가 여럿인 경우, XML이 같은 곡을 여러 번 적은 경우, `TrackID`가 겹친 경우다.
  - 그 곡을 가리키는 목록 항목은 맞추지 못한 항목이다.
- **큐**: 종류, 위치, 루프 끝, 이름으로 짝짓는다. 큐 종류는 메모리 큐, 핫큐 A~H, 루프다. `Num`은 메모리 큐가 -1이고 루프의 `Type`은 4다. 위치는 1ms 미만이면 같다.
  - 남은 것 중 같은 핫큐 슬롯이나 같은 위치의 메모리 큐는 고친 것(~)이다.
  - 나머지는 XML에만 있는 것과 라이브러리에만 있는 것으로 센다. 앞의 것은 +, 뒤의 것은 −로 적는다.
  - 핫큐 색은 보지 않는다.
  - 다음 곡은 큐를 비교하지 않는다. 개수만 센다. 큐·루프 `POSITION_MARK`가 하나도 없는 곡은 큐를 내보내지 않는 도구가 만든 것이다. 읽지 못한 큐가 있는 곡도 같다. 읽지 못한 큐는 깨진 값과 A~H 밖 핫큐다.
  - XML에 없는 rekordbox 자동 큐(`CUE(Auto)`·`1.1Bars`)는 −로 치지 않는다.
- **그리드**: XML에 `TEMPO`가 있는 곡만 비교한다. 분석 파일도 그 곡만 읽는다.
  - 두 쪽 구간으로 곡 길이까지 박을 만든다. 박 시각과 박 번호를 비교한다. 박 시각은 1ms 반올림 오차 안이면 같다.
  - 같은 박을 구간을 달리 나눠 적어도 같다.
  - 4/4가 아닌 `TEMPO`가 있는 곡은 그리드를 읽지 않는다. 읽지 못한 값이 있는 곡도 같다. 1~4 밖 `Battito`도 읽지 못한 값이다.
- **태그**: XML에 있는 칸만 비교한다. 글자는 NFC로 비교한다. 칸은 다음과 같다: `Name`, `Artist`, `Album`, `Genre`, `Composer`, `Comments`, `Year`, `TrackNumber`, `Tonality`, `Rating`.
  - 연도와 트랙 번호 0은 빈칸이다.
  - 키는 표기가 달라도(`Am`·`8A`) 같은 키면 같다.
  - `Rating` 값 0, 51, …, 255는 별 0~5개다.
  - `Colour`는 읽지 않는다. 개수만 센다. rekordbox XML 색 값과 곡 색 번호의 짝을 아직 확인하지 않았다.
- **재생 목록**: 폴더 이름 경로로 맞춘다. 다음 목록을 차이로 낸다.
  - 라이브러리에 없는 목록
  - 맞춘 곡의 구성이나 순서가 다른 목록
  - 맞추지 못한 항목 수를 함께 적는다.
  - 라이브러리에만 있는 목록은 차이로 치지 않는다.
  - 같은 경로가 여럿이면 비교하지 않는다. 개수만 센다.
  - `KeyType` 1(위치로 적은 항목)도 읽는다.
- 모르는 요소와 값은 막지 않는다. 건너뛴 것은 "읽지 않고 건너뛴 것"에 센다. 예는 다음과 같다.
  - 큐·루프가 아닌 위치 표시
  - A~H 밖 핫큐
  - 모르는 목록 종류
  - 컬렉션에 없는 곡을 가리킨 항목
- 문서가 깨졌으면 오류로 멈춘다. `DJ_PLAYLISTS`가 아닐 때도 멈춘다.
- 글 출력은 개수 줄 다음에 곡별 요약과 목록별 요약을 `--limit`(기본 50)개까지 적는다. 곡별 요약의 모양은 `경로 — 제목: 큐 +1 ~1 −0 · 그리드 · 태그 제목·아티스트`이다. 출력에 파일 경로와 곡 이름이 나오니 로그·이슈에 붙이지 않는다.
- `--json`은 `{"schemaVersion":1,"command":"xml-diff","data":{…}}`이다. `data`의 키는 다음과 같다.
  - `matching`(xmlTracks·matched·unmatched·ambiguous)
  - `counts`(cueTracks·gridTracks·tagTracks·missingPlaylists·changedPlaylists·ambiguousPlaylists·libraryOnlyPlaylists·xmlWithoutGrid·xmlWithoutCues·xmlUnreadableCues)
  - `gridsCompared`
  - `skipped`(종류별 개수)
  - `tracks`(xmlID·libraryID·path·title·cues{added,removed,modified[{library,xml}]}·grid{library,xml}·tags[{key,library,xml}])
  - `unmatched`·`ambiguous`(xmlID·path·title)
  - `playlists`(kind missing|changed·path·libraryID·xmlEntries·libraryEntries(ContentID)·unmatchedEntries)
- 오류도 같은 봉투(`error`)로 표준 오류에 낸다.

내보낸 XML을 그대로 비교하면 차이가 0이다. 시험으로 확인한다.

### 차이를 초안으로(`--draft`)

`--draft`를 주면 차이를 DJCrate 초안으로 만든다. 초안은 `DJC_HOME` 아래 초안 폴더에만 쓴다. `DJC_HOME`이 없으면 `~/Library/Application Support/DJCrate`를 쓴다. 초안 폴더는 `cue-drafts/`, `grid-drafts/`, `tag-drafts/`, `playlist-drafts.json`이다.

rekordbox에는 쓰지 않는다. 쓰기는 앱의 "rekordbox에 쓰기"(미리 보기 → 쓰기)가 다른 초안과 똑같이 한다. `--only`로 종류를 고른다(쉼표로 여럿). `--json`과는 함께 줄 수 없다.

- **base는 지금 라이브러리 상태**다.
  - 큐는 지금 큐(자동 큐 포함)다.
  - 그리드는 분석 파일의 박이다.
  - 태그는 지금 곡 정보다.
  - 재생 목록은 지금 목록이다.
  - 그 뒤 rekordbox에서 바뀐 곡과 목록은 기존 규칙대로 쓰기 미리 보기에서 막힌다.
- **기존 초안은 덮지 않는다.** 그 곡에 같은 종류의 초안 파일이 있으면 건너뛴다. 이유는 적는다. 읽지 못하는 파일도 같다.
  - 재생 목록은 기존 재생 목록 초안에 편집을 덧붙인다.
  - 이미 초안이 손댄 목록은 건너뛴다. 초안에 같은 이름으로 만든 목록도 건너뛴다.
  - 계획을 세운 뒤 저장하기 전에 생긴 초안도 덮지 않는다.
- **큐**: 차이 종류마다 다음과 같이 처리한다.
  - XML과 같은 큐는 지금 행을 그대로 둔다.
  - 고친 큐는 지금 행을 고쳐 남긴다. 고친 큐는 같은 핫큐 슬롯이나 같은 위치의 메모리 큐다. 핫큐 색과 활성 루프처럼 XML에 없는 칸을 잃지 않게 한다. 루프 길이가 바뀌면 박 루프 크기만 지운다.
  - XML에만 있는 큐를 더한다.
  - 라이브러리에만 있는 큐를 뺀다.
  - XML에 없는 rekordbox 자동 큐는 남긴다.
  - 새 루프는 활성 루프가 아니다. 박 크기도 없다.
- **그리드**: 분석 파일에 박이 있는 곡만 다룬다. 그 박은 구간으로 다룰 수 있어야 한다. 기준은 재생성 오차 2ms 이하다. 구간은 XML의 TEMPO 그대로다.
  - 변속 지점이 앞 구간과 반 박 안쪽이면 손실로 센다.
  - 이는 덱의 변속 지점 넣기와 같은 규칙이다. 쓰기에서 막힌다.
- **태그**: 바뀐 칸만 고친다. 키는 Camelot(1A~12B)으로 읽히는 값만 넣는다. 평점은 별 0~5개만 넣는다.
- **재생 목록**: 없는 목록은 폴더 경로를 따라 만들어 곡을 넣는다. 없는 폴더는 만든다.
  - 새 목록과 폴더는 부모 맨 위에 XML 순서로 생긴다.
  - 곡이 다른 목록은 곡을 모두 뺀다. 그다음 XML 순서로 다시 넣는다.
  - 라이브러리 목록 뒤에 곡만 더한 목록은 더한 곡만 넣는다.
  - 같은 자리에 인텔리전트 목록이 있으면 건너뛴다.
  - DJCrate 앱이 켜져 있으면 재생 목록 초안은 만들지 않는다. 앱이 그 파일을 다시 읽지 않는다. 앱은 자기 초안으로 덮는다.
  - 그리드 초안을 만들면 덱에 올린 곡의 그리드를 덱 편집이 덮을 수 있다고 알린다.
- **손실**: 초안이 담지 못하는 차이는 초안에서 뺀다. "초안에 담지 못한 차이"로 센다. 해당하는 경우는 다음과 같다.
  - 곡 길이 밖 큐
  - 메모리 큐 10개 초과
  - 같은 핫큐 슬롯의 두 번째 큐
  - 분석 파일이 없는 그리드
  - 구간으로 다룰 수 없는 그리드
  - 범위 밖 BPM·박 번호
  - Camelot이 아닌 키
  - 빈 제목
  - 쓰기 규칙을 확인하지 않은 칸. 상태가 0, 256, 257 밖인 곡의 평점과 곡 색이며, `TagWriteScope`가 정한다.
  - 비교하지 않은 곡(스트리밍·지운 곡)이 든 목록
  - 맞추지 못한 XML 항목이 있는 곡이 다른 목록. 통째로 바꾸지 않는다.
  - 없는 목록을 만들 때 맞추지 못해 빠진 항목
  - 반 박 안쪽 변속 지점
  - 이름이 겹친 폴더
## USB 내보내기(`usb-export`)

```sh
djc usb-export --volume <마운트> [--db <스냅샷 사본.db>] [--share <폴더>] [--playlist <ID>]… [--tracks <ContentID>,…]
               [--formats onelibrary,device] [--naming identifier] [--dry-run] [--allow-physical --confirm <볼륨 이름>]
               [--verify-audio] [--settings <로컬 설정 폴더>] [--snapshot-time <ISO 8601>]

# 디스크 이미지에 시험(임시 폴더 아래만, rekordbox는 꺼 둔다)
export DJC_HOME=$(mktemp -d)
djc lab usb-image create $DJC_HOME/e.img --size 4g --name DJCTEST
mkdir -p $DJC_HOME/mnt && djc lab usb-image attach $DJC_HOME/e.img --mount $DJC_HOME/mnt
djc usb-export --volume $DJC_HOME/mnt --db <스냅샷 사본.db> --playlist <ID> --dry-run
djc usb-export --volume $DJC_HOME/mnt --db <스냅샷 사본.db> --playlist <ID>
djc usb-info $DJC_HOME/mnt
djc lab usb-image detach $DJC_HOME/e.img
```

로컬 스냅샷 사본의 곡과 재생 목록을 빈 USB에 내보낸다. 빈 USB는 FAT32 또는 exFAT이고, 파티션은 MBR 또는 GPT다. 내보내는 형식은 두 가지다.

- OneLibrary: `exportLibrary.db`
- Device Library: `export.pdb`와 `exportExt.pdb`

음원, 분석 파일, 앨범아트도 함께 쓴다. 쓰기는 `UsbWriter.write` 한 곳으로 한다. 순서는 백업, 파일, DB 교체, 검증이다. 실패하면 쓰기 전으로 되돌린다. 흐름과 규칙은 `docs/usb-internals.md` §7.12에 있다.

- **실물 USB는 `--allow-physical --confirm <볼륨 이름>`이 있어야 쓴다.** 등록과 대화형 확인은 없다.
  - 조건은 [아래](#실물-usb에-쓰기--allow-physical)와 `docs/usb-internals.md` §12에 있다.
  - 옵션이 없으면 `physicalDisabled`로 막는다.
  - 이름이 다르면 `confirmMismatch`로 막는다.
- `--db`를 빼면 가장 최근 스냅샷을 읽기만 한다. 새로 뜨거나 정리하지 않는다.
- 라이브 master.db는 열지 않고 `liveDatabase`로 거부한다.
- 명령은 받은 사본을 세션 전용 폴더 `usb-snapshots/local-<세션>/`에 한 번 더 떠서 읽는다. 끝나면 그 폴더를 지운다.
- `--share`를 빼면 rekordbox 폴더의 `share`를 읽기만 한다.
- `--playlist`는 여러 번 줄 수 있다. 폴더를 주면 그 안의 목록까지 간다.
- `--tracks`는 ContentID를 쉼표로 이어 준다. `--playlist`와 함께 주면 목록 곡 다음에 이 곡을 더한다.
- `--snapshot-time`은 사본을 뜬 시각이다. 시간대를 넣은 ISO 8601로 준다.
  - 빼면 사본 이름 `master-YYYY-MM-DDTHHMMSS.db`(UTC)에서 먼저 푼다. 이름에서 못 풀면 파일 수정 시각으로 푼다.
  - 이 시각 뒤에 로컬 분석 파일이 바뀐 곡은 `analysisNewerThanSnapshot`으로 막는다.
  - 요약 첫 줄에 어디서 풀었는지 적는다. 값은 `explicit`, `fileName`, `modificationDate` 중 하나다.
- `--formats`의 기본은 둘 다다. `onelibrary`와 `device` 중 하나만 줄 수도 있다.
- `--naming`은 지금 `identifier`(DJCrate 고유 이름)만 있다.
- `--dry-run`은 계획, 준비, 쓰기 전 확인까지만 하고 USB에 쓰지 않는다. 저널은 `dryRun`으로 닫는다.
  - 같은 명령을 `--dry-run` 없이 다시 부르면 막히지 않고 쓴다.
  - 명령은 늘 지금 USB를 다시 읽어 새로 계획한다.
- 확인 안 된 규칙은 쓰기를 막지 않는다. 요약의 "확인 안 된 규칙" 줄에 나오는 규칙이다.
  - 디스크 이미지와 실물 모두 같다.
  - 예외는 `carriedDeviceRows`뿐이고, 이것은 늘 막는다. 근거는 `docs/usb-internals.md` §9에 있다.
  - 옛 `--allow-provisional`은 없어졌다. 주면 사용법 오류가 난다.
- `--settings <로컬 설정 폴더>`는 로컬 rekordbox 설정 파일을 내보내기 모양으로 `PIONEER/`에 옮긴다.
  - 옮기는 파일은 `MYSETTING.DAT`, `MYSETTING2.DAT`, `DJMMYSETTING.DAT`다.
  - 확인 안 된 규칙은 `settingFiles`다.
  - 빼면 설정 파일을 만들지 않는다.
  - `DEVSETTING.DAT`와 `djprofile.nxs`는 만들지 않는다.
- `--verify-audio`는 음원도 쓴 뒤 USB에서 다시 읽어 해시를 본다.
- 곡 단위 막힘은 그 곡만 빼고 쓴다. 예는 다음과 같다.
  - `audioMissing`
  - `analysisNewerThanSnapshot`
  - `trackRowTooLarge`
  - `nameTooLongForDeviceLibrary`
  - `fileTypeMismatchForDeviceLibrary`
  - `isrcNotASCIIForDeviceLibrary`
  - `valueOutOfRangeForDeviceLibrary`
  - 이 밖에도 곡 단위 막힘이 더 있다.
- 볼륨 단위 막힘이 하나라도 있으면 쓰지 않는다.
  - `localVersionUnverified`: 이 Mac의 rekordbox가 확인한 버전이 아니다.
  - `libraryExists`: 이미 rekordbox 라이브러리가 있는 USB다. USB 수정을 쓴다.
  - `leftoverPioneer`: `PIONEER/` 바로 아래에 다른 것이 남아 있다.
  - `myTagNameTooLongForDeviceLibrary`
  - `noTracks`
  - 볼륨 정책: `unsupportedFileSystem`, `partitionScheme` 등
  - 보호 폴더: `protectedPath`
  - 실물 관문: `physicalDisabled`, `confirmMismatch`
  - `insufficientSpace`
  - 쓰기 절차의 막힘: `rekordboxRunning`, `recoveryNeeded`, `destinationExists` 등
  - 볼륨 정책, 보호 폴더, 실물 관문에 막힌 볼륨은 이름도 열거하지 않는다.
- `Contents/`에 사용자가 넣어 둔 음원은 덮어쓰지 않는다.
  - 같은 이름에 같은 내용이면 그 파일을 가리키고 쓰지 않는다.
  - 내용이 다르면 ` (2)`처럼 번호를 붙인다.
- 출력에서 진행은 표준 오류에 단계마다 한 줄씩 나온다. 요약은 표준 출력에 나온다.
  - 요약 순서는 다음과 같다.
    1. 스냅샷 시각
    2. 곡 수, 재생 목록 수, 막힌 곡 수
    3. 막힘 code별 수와 ContentID
    4. 확인 안 된 규칙별 곡 수
    5. 경고 code별 수
    6. 필요 공간
    7. 결과, 백업 폴더, 파일 수
  - 곡 제목과 USB 경로는 찍지 않는다.
  - 쓴 뒤에는 "USB를 꺼낸 뒤 뽑으세요(Finder 또는 `diskutil eject`)"로 끝난다.
- 종료 코드는 성공 0, 막힘·실패 1이다. JSON 계약에는 포함하지 않는다.

## USB 수정(`usb-edit`)

```sh
djc usb-edit --volume <마운트> (<편집.json> | --draft) [--db <스냅샷 사본.db>] [--share <폴더>] [--dry-run]
             [--allow-physical --confirm <볼륨 이름>] [--snapshot-time <ISO 8601>]
```

이미 라이브러리가 있는 USB에 곡 더하기, 곡 빼기, 곡 갱신, 재생 목록 편집을 한 번에 쓴다. 대상 USB는 DJCrate가 만든 것도 되고 rekordbox가 만든 것도 된다. OneLibrary는 USB DB 사본에 편집마다 SQL로 고친다. Device Library는 고친 모델에서 새로 만든다.

쓰기는 `UsbWriter.write` 한 곳이다. 순서는 백업, 파일, DB 교체, 지우기, 검증이다. 실패하면 쓰기 전으로 되돌린다. 규칙은 `docs/usb-internals.md` §8.3에 있다.

- **실물 USB는 `--allow-physical --confirm <볼륨 이름>`이 있어야 쓴다.** `usb-export`와 같다.
  - 곡 정보 갱신(`refreshTracks`, `editRefreshTracks`)도 실물에서 막지 않는다.
- `<편집.json>`은 편집 배열이다. 적힌 순서대로 앞 편집을 적용한 결과 위에 다음 편집을 계획한다.
- `--draft`는 이 볼륨에 쌓인 초안 `usb-drafts/<볼륨 UUID>.json`을 쓴다.
  - 초안을 만든 뒤 USB가 바뀌었으면 지금 USB 상태로 다시 계획한다. 이때 "USB가 그 사이 바뀌어 다시 계획했습니다"가 나온다.
  - 쓴 뒤나 쓸 것이 없을 때, 초안에는 막힌 편집만 남긴다. 막힌 편집이 없으면 초안을 지운다.
  - 새 base는 그때 USB DB 지문이다. 새 스냅샷 등으로 막힘이 풀리면 다시 `--draft`로 쓴다.
  - `--dry-run`은 초안을 건드리지 않는다.
- `--db`는 로컬 스냅샷 사본이다. 곡 더하기, 갱신, 목록 동기화처럼 로컬을 읽는 편집에 필요하다.
  - 이 세 편집이 있을 때만 받은 사본을 세션 전용 폴더 `usb-snapshots/local-<세션>/`에 한 번 더 떠서 읽는다. 끝나면 지운다.
  - 곡 빼기에서 음원을 지워도 되는지는 로컬 원본과 같은지로 본다. 이것은 곡 더하기, 갱신, 목록 동기화와 함께 쓰는 묶음에서만 본다.
  - 곡 빼기와 일반 목록 편집만 있으면 `--db`를 주어도 로컬 사본을 뜨지 않는다. 이때 음원은 USB에 남기고 알린다. 분석 파일과 앨범아트는 지운다.
  - `--db`를 빼면 곡 더하기, 갱신, 목록 동기화가 있을 때만 가장 최근 스냅샷을 읽기만 한다. 곡 빼기와 일반 목록 편집만 있으면 스냅샷 폴더를 보지 않는다.
  - 라이브 master.db는 거부한다.
- `--snapshot-time`은 사본을 뜬 시각이다. `usb-export`와 같다.
  - 곡 더하기와 갱신에서 이 시각 뒤에 분석 파일이 바뀐 곡은 막는다.
- `--dry-run`은 계획, 준비, 쓰기 전 확인까지만 하고 USB에 쓰지 않는다.
  - 같은 명령을 `--dry-run` 없이 다시 부르면 막히지 않고 쓴다.
- 편집 하나가 막히면 그 편집만 빼고 나머지를 쓴다.
  - 여러 곡 갱신(`refreshTracks`)은 곡 더하기처럼 막힌 곡만 빼고 쓴다. 뺀 곡은 요약의 "빼고 쓴 곡"에 나온다.
  - 요청한 곡이 모두 막혔을 때만 그 편집을 막는다.
- USB 전체를 막는 경우는 다음과 같다.
  - 두 형식의 곡 번호나 경로가 다르다: `formatTrackMismatch`
  - 맨 위에서 닿지 않는 재생 목록이 있다: `formatPlaylistConflict`. 번호만 다른 같은 목록은 짝지어 읽으므로 막지 않는다.
  - 라이브러리가 손상됐다: `libraryCorrupt`
  - 새 rekordbox의 OneLibrary다: `oneLibraryUnsupported`
  - 볼륨 모양이 맞지 않는다: APFS, HFS+ 등
  - 실물 관문을 통과하지 못했다.
  - 끝나지 않은 쓰기가 있다: `recoveryNeeded`
- Device Library만 막는 경우도 있다. 이때 OneLibrary는 쓴다.
  - 머리 0x10이 5가 아니다: `pdbNotClosed`
  - 기기가 쓴 기록이나 모르는 표 행이 있다: `carriedDeviceRows`
  - 다시 쓸 수 없는 모양이다: `pdbRoundTripFailed`
- 한 형식이 막히면 파일 지우기를 미룬다(`deferred`).
- 두 형식에 함께 있는 재생 목록의 이름과 폴더 바꾸기는 막는다(`playlistInBlockedFormat`).
  - 한 형식만 바꾸면 두 형식 목록이 짝을 잃는다.
  - 그러면 다음부터 두 목록으로 보인다.
- 출력에서 진행은 표준 오류에 나온다. 요약은 표준 출력에 나온다.
  - 요약 순서는 다음과 같다.
    1. 스냅샷 시각
    2. 편집 번호별 결과: `written`, `unchanged`, `blocked <code>`, `deferred`
    3. 쓴 형식과 막힌 형식
    4. 빼고 쓴 곡 code별 수
    5. 알림. 경로가 붙은 알림은 이유별 수로 적는다.
    6. 확인 안 된 규칙
    7. 결과, 백업 폴더, 파일 수
  - 곡 제목과 USB 경로는 찍지 않는다.
- 종료 코드는 성공 0, 막힘·실패 1이다. 편집 일부만 막히고 나머지를 썼으면 0이다.

편집 파일은 `UsbLibraryEdit` 배열이다. 각 값은 다음 규칙으로 적는다.

- 곡은 USB `content_id`(수)로 가리킨다.
- 로컬 곡은 로컬 ContentID(글자)로 가리킨다.
- 재생 목록은 USB `playlist_id`(글자)로 가리킨다. 같은 파일에서 만든 목록은 `new:<key>`로 가리킨다.
- 맨 위는 `root`다.

```json
[ {"removeTracks": {"usbContentIDs": [5]}},
  {"refreshTracks": {"usbContentIDs": [2], "parts": ["info", "cues", "grid", "artwork"]}},
  {"addTracks": {"localContentIDs": ["123456"], "playlist": "1"}},
  {"playlist": {"edit": {"create": {"key": "p2", "name": "새 목록", "isFolder": false, "parent": "root"}}}},
  {"playlist": {"edit": {"rename": {"playlist": "1", "name": "새 이름"}}}},
  {"playlist": {"edit": {"move": {"playlist": "new:p2", "into": "root"}}}},
  {"playlist": {"edit": {"reorder": {"playlist": "new:p2", "index": 0}}}},
  {"playlist": {"edit": {"delete": {"playlist": "3"}}}},
  {"playlist": {"edit": {"addTracks": {"playlist": "new:p2", "contentIDs": ["1", "2", "3"]}}}},
  {"playlist": {"edit": {"removeTracks": {"playlist": "1", "entries": [{"trackNo": 2, "contentID": "7"}]}}}},
  {"playlist": {"edit": {"moveTracks": {"playlist": "new:p2", "entries": [{"trackNo": 3, "contentID": "3"}], "to": 1}}}} ]
```

- `refreshTracks.parts`는 다시 읽을 부분이다.
  - `info`: 곡 정보
  - `cues`: 큐
  - `grid`: 박자 그리드와 분석 파일
  - `artwork`: 앨범아트
- 로컬 곡은 이 곡을 내보낸 라이브러리의 같은 곡으로 찾는다.
  - 찾는 기준은 DB ID, 곡 ID, USB 경로 끝 성분이다.
  - USB 경로 끝 성분은 파일 이름 그대로이거나, 내보내기 이름 규칙과 번호를 붙인 이름이다.
  - 로컬과 같은 곡은 `unchanged`로 둔다.
  - 기기에서 고친 곡은 건너뛰고 알린다. 고친 곡은 hasModified가 켜졌거나 기기 큐 행이 있는 곡이다.
  - 음원이 바뀐 곡은 막는다. 음원은 다시 쓰지 않는다.
- `addTracks.playlist`를 주면 더한 곡을 그 목록 끝에 넣는다.
  - 이미 USB에 있는 곡(`alreadyOnUsb`)은 빼고 더한다.
  - 내보내기에서 막히는 곡도 빼고 더한다.
- `syncPlaylist`는 로컬 곡 ID로 USB 목록의 전체 항목을 맞춘다. 예는 `{"syncPlaylist":{"playlist":"new:p2","localContentIDs":["123456","123456","789012"]}}`다.
  - 같은 묶음에서 앞서 더한 곡도 여러 목록에서 가리킬 수 있다.
  - 순서와 중복은 보존한다.
  - `--db`가 필요하다. 로컬 사본은 세션 전용 폴더에 다시 뜬다.
  - 짝이 없거나 여러 개면 목록 편집 전체를 막아 기존 항목을 보존한다.
  - 빈 배열은 목록을 비운다.
  - USB 음원 삭제는 포함하지 않는다.
- `syncSelection`은 앱이 마지막 편집으로 더한다. 담는 내용은 다음과 같다.
  - 동기화 선택
  - 원본 노드
  - 최종 목록 참조
  - 두 sync 원문
- 선택 파일도 DB와 같은 쓰기 묶음으로 갱신한다.
  - 선택만 바뀐 요청도 쓸 수 있다.
  - 켜짐만 바꾸는 요청(`enabledOnly`)도 쓸 수 있다.
  - 원본 노드에는 `masterPlaylists6.xml`의 `timestamp`를 싣는다.
  - rekordbox가 만든 선택 파일이 있는 USB만 고쳐 쓴다. 새 파일 만들기는 막는다([규칙](usb-internals.md#83-수정usbeditsession-usbeditengine-djc-usb-edit)).
  - `djc lab usb-sync-diff <전 폴더> <후 폴더>`는 임시 폴더의 전후 선택 파일을 비교한다. 값 없이 칸, 노드, 순서로 비교한다.
- 재생 목록 항목 편집(`addTracks`, `removeTracks`, `moveTracks`)은 두 형식의 곡 목록이 같은 목록에만 한다.
  - 다르면 `playlistEntriesDiffer`로 막는다. 이름과 위치만 바꿀 수 있다.
  - `entries`의 `trackNo`는 1부터 세는 자리다.
  - `contentID`는 그 자리에 있어야 할 USB 곡이다.
  - 지금 그 자리의 곡과 다르면 `entryMismatch`로 막는다.

## Device Library만 있는 USB를 OneLibrary로 옮기기(`usb-migrate`)

```sh
djc usb-migrate --volume <마운트> [--dry-run] [--allow-physical --confirm <볼륨 이름>]
```

옛 Device Library만 있는 USB를 읽어 같은 USB에 OneLibrary를 더한다. Device Library는 `export.pdb`와 `exportExt.pdb`이고, OneLibrary는 `exportLibrary.db`다. 로컬 라이브러리는 읽지 않는다.

원래 파일은 바꾸지 않는다. 원래 파일은 pdb 둘, 분석 파일, 음원, `a` 앨범아트다. 새로 만드는 것은 두 가지뿐이다.

- 새 `exportLibrary.db`
- OneLibrary가 가리키는 `b` 앨범아트. 같은 폴더 `a` 앨범아트의 바이트 사본이다.

쓰기는 `UsbWriter.write` 한 곳이다. 순서는 백업, 파일, DB 만들기, 검증이다. 실패하면 쓰기 전으로 되돌린다. 되돌리기는 `usb-restore`로 한다. 규칙은 `docs/usb-internals.md` §8.4에 있다.

- **실물 USB는 `--allow-physical --confirm <볼륨 이름>`이 있어야 쓴다.** `usb-export`와 같다.
- 아래는 막힘이라 쓰지 않는다.
  - OneLibrary가 이미 있다: `oneLibraryExists`. 사이드카만 남아도 막고, 이때는 USB 수정을 쓴다.
  - `export.pdb`가 없다: `noDeviceLibrary`
  - 곡이 없다: `noTracks`
  - 머리 0x10이 5가 아니다: `pdbNotClosed`
  - 읽지 못한 행이나 먼 모양 행이 있다: `pdbUnreadableRows`
  - 기기가 쓴 기록이나 모르는 표 행이 있다: `carriedDeviceRows`
  - 표 19 버전이 "1000"이 아니다: `pdbVersionUnsupported`
  - `a` 앨범아트가 없거나 경로 모양이 다르다: `artworkMissingOnUsb`
  - `b` 자리에 다른 파일이 있다: `artworkExists`
  - OneLibrary를 더하면 USB 파일과 새로 어긋나는 곳이 있다: `libraryFilesMismatch`. 어긋나는 것은 음원 크기, PPTH, 파일 이름이다.
  - 끝나지 않은 쓰기가 있다: `recoveryNeeded`
  - 볼륨 모양이나 실물 관문에 걸린다.
- 확인 안 된 규칙은 막지 않고 요약에 적는다.
  - `deviceLibraryMigration`은 늘 적는다. rekordbox "Convert from Device Library" 결과와 아직 견주지 않았다.
  - 재생 목록이 있으면 `playlistSiblingBase`를 적는다. 폴더면 `playlistFolderRow`를 적는다.
  - My Tag 연결은 `myTagLinks`다.
  - 앨범아트 없는 곡은 `artworkMissing`이다.
  - 빈 값으로만 본 곡 정보 칸은 `metadataSeenEmptyOnly`다.
  - `exportExt.pdb`가 없으면 `myTagMasterDBID`를 적는다.
- `--dry-run`은 계획, 준비, 쓰기 전 확인까지만 하고 USB에 쓰지 않는다.
- 출력에서 진행은 표준 오류에 나온다. 요약은 표준 출력에 나온다.
  - 요약 순서는 다음과 같다.
    1. 막힘
    2. `옮길 것: 곡 N · 재생 목록 N · OneLibrary 앨범아트 N`
    3. 확인 안 된 규칙
    4. 결과, 백업 폴더, 파일 수
  - 곡 제목과 USB 경로는 찍지 않는다.
- 종료 코드는 성공 0, 막힘·실패 1이다.

## USB 쓰기 되돌리기·회복

USB 쓰기는 앱이나 USB 내보내기·수정 명령이 `UsbWriter.write` 한 곳으로 한다. 아래 두 명령은 그 쓰기를 되돌리거나 끊긴 쓰기를 마무리한다. 둘 다 쓰기와 같은 확인을 먼저 거친다.

- rekordbox와 rekordboxAgent가 켜져 있으면 막는다.
- 실물 USB는 `--allow-physical --confirm <볼륨 이름>`이 있어야 받는다. 없으면 임시 폴더 아래에 붙인 디스크 이미지만 받는다.
- `--volume`에 rekordbox 라이브러리나 DJCrate 데이터 폴더를 주면 거부한다.

백업과 저널은 `DJC_HOME`의 `usb-backups/`와 `usb-sessions/`에 있다. `DJC_HOME`이 없으면 기본 DJCrate 데이터 폴더를 쓴다. JSON 계약에는 포함하지 않는다.

```sh
djc usb-recover --volume <마운트> [--discard-temp] [--allow-physical --confirm <볼륨 이름>]
djc usb-restore --volume <마운트> [--backup <폴더>] [--discard-device-changes] [--allow-physical --confirm <볼륨 이름>] [--dry-run]
```

- `usb-recover`는 이 볼륨의 끝나지 않은 쓰기(닫히지 않은 저널)를 DB 해시로 판정해 마저 쓰거나 되돌린다.
  - 기기가 그 사이 DB를 바꿨으면 이어 쓰지 않고 "다시 계획"으로 닫는다. 이때는 지금 USB로 다시 미리 보기한 뒤 쓴다.
  - 끊긴 `usb-restore`는 되돌리기로 마저 한다.
  - 저널이 없으면 "회복할 쓰기가 없습니다"로 끝낸다.
  - USB에 `.djc-part-*` 임시 파일이 있으면 보고만 한다. `--discard-temp`를 주면 지운다.
  - 저널을 읽지 못하거나 저널의 경로가 USB 루트 밖을 가리키면 아무것도 하지 않는다. 대신 `usb-sessions`를 확인하라고 알린다.
- `usb-restore`는 끝난 쓰기를 그 쓰기 전 백업으로 되돌린다.
  - `--backup`을 빼면 이 볼륨의 가장 최근 백업을 쓴다.
  - `--backup`은 이 볼륨의 `usb-backups/<볼륨>/` 바로 아래 폴더만 받는다. 다른 곳에 복사한 백업과 링크는 거부한다.
  - 그 뒤 기기가 USB에 기록을 남겼으면 막는다. 기록을 남긴 경우는 DB 해시가 쓰기 결과와 다르거나 `-wal`·`-journal`이 있을 때다.
  - `--discard-device-changes`를 줘야 그 변경을 버리고 되돌린다.
  - 쓰기가 만든 파일, 폴더, DB는 지운다.
  - 덮어쓴 파일은 백업에서 되살린다.
  - 지웠던 음원은 로컬 원본이 그대로일 때만 다시 복사한다. 원본이 없거나 바뀌었으면 알리고 나머지를 되돌린다.
  - 되돌린 백업으로 다시 돌리면 "이미 되돌렸습니다"로 끝낸다.
  - `--dry-run`은 판정만 하고 USB를 바꾸지 않는다.
- `--allow-physical --confirm <볼륨 이름>`은 실물 USB를 되돌리거나 회복할 때 요구한다. 쓰기와 같은 관문이다.
- 출력은 결과, 백업 폴더, 파일 수다. USB 경로가 붙은 알림은 이유별 개수만 찍는다. 건너뛴 분석 파일 등이 그 예다.
- 종료 코드는 성공 0, 막힘·실패 1이다. 막힘 이유는 무엇을 하면 되는지까지 한 문장으로 나온다.

## 실물 USB에 쓰기(`--allow-physical`)

```sh
djc usb-export --volume /Volumes/<이름> --db <스냅샷 사본.db> --playlist <ID> --allow-physical --confirm <이름> --dry-run
```

실물 USB는 등록 없이 읽는다. 쓰기는 `--allow-physical --confirm <볼륨 이름>`을 준 명령만 한다. 대화형 확인은 없다.

앱에서는 쓰기 확인 창의 쓰기 버튼이 같은 동의다. 이 창은 볼륨 이름과 용량, "실물 USB입니다"를 보인다. 내보내기는 내보내기 시트가 그 창을 대신한다.

아래 조건이 하나라도 아니면 그 이유와 할 일을 한 문장으로 알리고 USB 파일을 건드리지 않는다.

- 코드 관문(`UsbPhysicalWriteGate.buildEnabled`, 비상 스위치)과 `--allow-physical`이 둘 다 열려 있다. 아니면 `physicalDisabled`다.
- 볼륨 UUID가 있다. 없으면 `noVolumeUUID`다.
- `--confirm`이 볼륨 이름과 정확히 같다. 다르면 `confirmMismatch`다.
- 볼륨 모양이 디스크 이미지와 같은 정책(`UsbVolumePolicy`)을 따른다.
  - 허용하는 볼륨은 바깥 저장장치의 FAT32 또는 exFAT이고, 파티션은 MBR 또는 GPT다. 바깥 저장장치는 USB 메모리, 외장 SSD, SD 카드 리더 등이다.
  - 시동, 내장, 네트워크, 읽기 전용 볼륨은 막는다.
  - APFS, HFS+, FAT16은 `unsupportedFileSystem`으로 막는다. HFS+에는 Time Machine 디스크도 들어간다.
  - APM이거나 파티션 표가 없으면 `partitionScheme`으로 막는다.
  - exFAT은 이전 CDJ가 읽지 못할 수 있다. GPT는 일부 기기가 읽지 못할 수 있다. 둘 다 막지 않고 앱 확인 창에 한 줄로 알린다.
- rekordbox와 rekordboxAgent가 꺼져 있다. 켜져 있으면 `rekordboxRunning`이다.

옛 판의 `usb-allow`와 `usb-deny`는 없어졌다. 목록 파일 `usb-physical-allow.json`과 `usb-physical-deny.json`도 없어졌다. 남은 파일은 읽지 않고 지우지도 않는다. 시험 프로세스는 이 관문이 열려도 임시 폴더 밖 볼륨에 쓰지 않는다.

## USB 읽기(`usb-info`)

```sh
djc usb-info <볼륨|폴더> [--json]
```

USB를 **읽기만** 해서 상태를 보여 준다. 대상은 마운트된 볼륨, 그 안 폴더, USB 모양 폴더다. 보여 주는 내용은 다음과 같다.

- 형식
- 곡 수
- 두 형식이 맞는지
- 음원 누락
- 분석 파일
- 설정 파일 상태
- 경고

앱 사이드바도 같은 판정(`UsbRead`)을 쓴다. USB에는 아무것도 쓰지 않는다.

DB는 `DJC_HOME`의 `usb-snapshots/` 아래에 사본으로 떠서 읽는다. `DJC_HOME`이 없으면 기본 DJCrate 데이터 폴더를 쓴다. 끝나면 지운다. `PIONEER/extracted`, `PIONEER/CDP`, `djprofile.nxs`는 열지 않고 "있음"도 알리지 않는다. 사람용 출력에는 곡 제목, 경로, 볼륨 이름을 찍지 않는다.

- **실물 USB도 등록 없이 읽는다.**
  - 대상 경로의 마운트 지점이 Mac 시동 볼륨이 아니면 그 볼륨으로 본다. 볼륨 안 하위 폴더여도 같다.
  - 이때 볼륨 정책 문제를 함께 적는다(`volume.problems`).
- rekordbox 라이브러리나 DJCrate 데이터 폴더를 주면 `liveLibrary`로 거부한다. 없는 경로는 `not_found`다.
- JSON은 위 v1 규칙을 따른다. 단, **`usb-info`는 키를 생략하지 않는다.**
  - 값이 없으면 `null`이다. 뒤 판이 값을 채워도 모양이 그대로이게 하려는 것이다.
  - 오류 코드는 위의 것과 `liveLibrary`다.
- **개인 식별값은 내지 않는다.**
  - masterDbId, myTagMasterDBID, 볼륨 UUID는 값 대신 "같은지"만 적는다.
  - 볼륨 이름은 `root`(받은 경로)에만 나올 수 있다. 다른 키에는 없다.

`data`(`UsbInfo`, `schemaVersion` 1)의 키는 다음과 같다.

| 키 | 타입 | 뜻 |
|---|---|---|
| `schemaVersion` | number | 1 |
| `root` | string | 받은 경로를 절대 경로로 바꾼 것(링크는 풀지 않는다). 볼륨이면 `/Volumes/<이름>`처럼 볼륨 이름이 들어갈 수 있다 |
| `formats` | string[] | `oneLibrary`·`deviceLibrary`. `PIONEER/rekordbox/`의 `exportLibrary.db`·`export.pdb` 이름으로 판정한다 |
| `volume` | object \| null | 폴더 대상이면 null. 하위 키는 아래 목록 |
| `oneLibrary` | object \| null | 하위 키는 아래 목록 |
| `deviceLibrary` | object \| null | 하위 키는 아래 목록. Device Library를 읽지 못하면 null |
| `consistency` | object | 하위 키는 아래 목록 |
| `analysis` | object | 하위 키는 아래 목록 |
| `media` | object | 하위 키는 아래 목록 |
| `settings` | object[] | `PIONEER/`의 알려진 네 이름(`MYSETTING.DAT`, `MYSETTING2.DAT`, `DJMMYSETTING.DAT`, `DEVSETTING.DAT`) 순서. 항목 키는 아래 목록 |
| `localCompatibility` | object | `rekordboxVersion`(string \| null, 이 Mac의 rekordbox), `verified`(bool, DJCrate가 확인한 버전인지) |
| `warnings` | `{code, message}[]` | 경고 code는 아래 목록. `message`만 번역한다 |

`volume`의 하위 키:

- `fileSystem`: string. 예는 `FAT32`
- `partitionScheme`: `mbr`, `gpt`, `apm`, `none`, `unknown` 중 하나
- `isDiskImage`
- `writableForExport`, `writableForEdit`: bool. 볼륨 정책 문제가 없는지를 뜻한다.
- `problems`: string[]. 정책 문제 code

`oneLibrary`의 하위 키:

- `schemaOK`: 확인한 모양인지
- `headerMode`: `wal` 또는 `rollback`. 사본이 온전하지 않으면 `unknown`
- `walPresent`, `journalPresent`
- `integrityOK`: bool
- `tracks`, `playlists`, `myTags`, `histories`: number

`deviceLibrary`의 하위 키:

- `exportFlag10`: number. 머리 0x10
- `extFlag10`: number \| null
- `roundTripChecked`: bool. 늘 true
- `roundTripOK`: bool. 읽기, 모델, 다시 쓰기, 다시 읽기가 같으면 true다. 다시 만들지 못하거나 다르면 false이고 경고 `pdbRoundTripFailed`가 붙는다.
- `tracks`, `playlists`
- `historyRows`: 기록 표 산 행
- `unknownTableRows`: 모르는 표 산 행
- `structureIssues`: number

`consistency`의 하위 키:

- `trackIDsMatch`, `pathsMatch`: bool
- `playlistMismatches`: number. 두 형식이 다른 재생 목록 수
- `masterDbIdConsistent`: 모든 곡이 한 값인지
- `myTagMasterDBIDConsistent`: 두 형식 값이 같은지
- `editBlocked`: 고치기를 막는 불일치가 있는지

`analysis`의 하위 키:

- `tracksChecked`
- `missingFiles`: DB가 가리키는 `.DAT`·`.EXT`·`.2EX` 중 없는 파일 수
- `ppthMismatches`: `.DAT` PPTH와 곡 경로가 다른 곡 수
- `slotCollisions`: 파일 번호가 0이 아닌 경로 수

`media`의 하위 키:

- `tracksChecked`: 읽은 DB의 서로 다른 곡 ID 수
- `filesChecked`: 서로 다른 NFC 음원 경로 수
- `missingFiles`: 그중 일반 파일로 없는 경로 수

`media`를 셀 때의 규칙은 다음과 같다.

- 두 형식의 같은 경로는 한 번만 센다.
- 빈 경로, 탈출 경로, 금지 경로, 링크, 폴더도 누락으로 센다.
- 음원 내용, 형식, 재생 가능 여부는 검사하지 않는다.

`settings`의 항목 키:

- `fileName`
- `status`: `missing`, `valid`, `invalid`, `unreadable` 중 하나
- `issue`: string \| null
- `crcOK`: bool \| null

`settings`는 DB가 없어도 검사한다. 설정 파일이 없는 것은 경고하지 않는다.

`warnings`의 code는 다음과 같다.

- `pdbOpenFlag`: 머리 0x10이 5가 아니다.
- `unknownTableRows`
- `pdbStructure`
- `deviceLibraryUnreadable`
- `oneLibrarySidecar`: `-wal` 또는 `-journal`이 있다.
- `oneLibraryUnsupported`
- `oneLibraryUnreadable`
- `formatMismatch`: 고치기가 막힌다.
- `analysisMissing`
- `analysisPathMismatch`
- `mediaMissing`
- `settingsInvalid`: 설정 파일이 손상됐거나 읽을 수 없다.
- `pdbRoundTripFailed`: DJCrate가 이 Device Library를 그대로 다시 쓸 수 없다. 문제 수만 적는다.

`settings.issue`는 두 갈래로 적는다.

- 기존 설정 파서의 첫 검증 실패는 `wrongSize`, `wrongStringsLength`, `wrongDataLength`, `crcMismatch`, `trailerNotZero` 중 하나로 적는다.
- 읽기 불가 이유는 `unsafePath`, `notRegularFile`, `readFailed` 중 하나로 적는다.

`crcOK`는 파일을 읽고 종류별 크기가 맞을 때만 계산한다. 그 밖은 null이다. 제조사, 버전, 설정 칸 값은 내지 않는다.

`media`와 `settings`는 v1에 추가한 키이며 기존 키와 타입은 유지한다. 소비자는 모르는 키를 무시한다.

종료 코드는 성공 0, 막힘·실패 1이다. 형식이 없는 USB도 성공이며 `formats`가 빈 배열이다.
