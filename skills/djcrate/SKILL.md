---
name: djcrate
description: DJCrate의 명령줄 도구 djc로 rekordbox 라이브러리(스냅샷 사본)를 조회하고 정리할 것을 제안하며, 사용자가 고른 제안만 djc draft로 큐·태그 초안을 만든다. 사용자가 rekordbox·DJCrate 라이브러리에서 곡을 찾거나(BPM·키·재생 목록·코멘트 조건), 큐 없는 곡·빈 코멘트·규칙 밖 코멘트를 찾거나, 코멘트·태그 정리안이나 큐 초안, DJ 세트용 곡 후보·순서를 원할 때 쓴다. rekordbox에는 쓰지 않는다(반영은 사람이 앱에서 한다).
---

# DJCrate 라이브러리 조회·제안·초안 (djc)

`djc` 읽기 명령으로 rekordbox 라이브러리의 **스냅샷 사본**을 읽고, 고칠 것을 표로 제안한다. 사용자가 고른 것만 `djc draft`로 DJCrate의 **초안**(큐·태그)을 만든다. rekordbox에 쓰는 반영은 사람이 DJCrate 앱에서 한다. AI 연동은 CLI와 이 스킬로 한다. MCP 서버나 별도 플러그인 설치는 필요 없다.

## 안전 규칙 (먼저 지킨다)

1. **라이브 DB를 열지 않는다.** 아래 파일을 sqlite·셸 등으로 직접 열거나 복사하지 않는다.
   - `~/Library/Pioneer/rekordbox/master.db`
   - `share/PIONEER/USBANLZ`
   - 음원 파일

   읽기는 아래 djc 읽기 명령으로만 한다. `--db`에 라이브 DB(링크 포함)를 주면 djc가 `live_database`로 거절한다. 우회하지 않는다.
2. **rekordbox에 쓰지 않는다.** 아래 명령은 실행하지 않는다.
   - `cue-write`, `track-add`, `track-delete`, `playlist-write`, `rekordbox-restore`
   - `--live`가 붙은 명령
   - `djc lab …`

   사람이 시켜도 이 스킬로는 하지 않는다. DJCrate 앱에서 하라고 안내한다.
3. **초안은 `djc draft`로만, 사용자가 고른 것만 만든다.** 아래 초안 폴더의 파일을 직접 만들거나 고치지 않는다.
   - `cue-drafts/`, `grid-drafts/`, `tag-drafts/`
   - `gain-drafts.json`, `playlist-drafts.json`

   순서는 이렇다.
   1. 제안을 표로 보여 준다.
   2. 사용자가 고른 곡·값만 대상으로 한다. 동의하지 않은 초안은 만들지 않는다. 사용자가 "전부"라고 하면 표 전체가 대상이다.
   3. 같은 명령을 `--dry-run --json`으로 먼저 돌려 결과(`hasChanges`, 바뀐 값)를 보여 준다. 오류가 나면 거기서 멈춘다.
   4. `--dry-run`을 빼고 실제 초안을 만든다.
   5. 앱에서 확인하라고 안내한다. 큐 초안은 대기 목록과 곡 덱에서, 태그 초안은 태그 편집(⌘I)·태그 시트와 대기 목록에서 본다. 앱이 켜져 있으면 약 1초 뒤 다시 읽는다.
   - `djc draft rm`은 사용자가 그 곡의 초안을 버리라고 할 때만 쓴다. 앱에서 한 편집까지 그 종류의 초안 **전체**가 사라진다.
   - 같은 곡을 앱에서 편집하는 중이면 마지막 저장이 앞선 저장을 덮는다. 앱에서 그 곡 편집을 마친 뒤 만든다.
4. **반영은 사람이 한다.** 사람이 rekordbox를 완전히 끈 뒤 DJCrate 앱에서 초안과 쓰기 미리 보기(⇧⌘E)를 확인하고 rekordbox에 쓴다.
   - 반영할 수 있는 초안은 두 가지다. 컬렉션 곡의 큐, 그리드, 게인, 태그 초안과 앱에서 만든 재생 목록 초안이다.
   - 태그는 rekordbox 곡 정보에만 쓴다. 음원 파일의 태그는 바꾸지 않는다. 이 스킬이 만드는 초안은 큐·태그뿐이다.
5. **라이브러리 정보를 밖으로 내보내지 않는다.** 스냅샷·DB 사본·백업에는 rekordbox 클라우드 토큰이 들어 있다. 복사·업로드·출력하지 않는다. 곡 목록, 파일 경로, 곡 수는 이슈나 PR, 웹 서비스에 올리지 않는다.

## 준비

- 언어는 macOS 언어 설정을 따른다. `DJC_LANG=ko|en|ja`가 우선한다.
  - 예: `DJC_LANG=en djc search '시험' --json`
  - 지원하지 않는 언어는 영어로 나온다.
  - JSON의 `code`·칸 이름·데이터는 그대로다. 오류 `message`만 번역한다.
- `djc` 찾기: PATH에 `djc`가 있으면 그것을 쓴다. 없으면 DJCrate 저장소에서 `swift build --product djc`를 돌린 뒤 `.build/debug/djc`를 쓴다.
- 읽기 명령과 `djc draft`는 최신 스냅샷을 읽는다. 스냅샷이 없으면 `read_failed`("스냅샷이 없습니다") 오류가 난다.
- `djc snapshot`은 라이브 DB를 읽기만 해서 사본을 뜬다. rekordbox에는 쓰지 않는다. 사람이 rekordbox에서 고친 뒤라면 새로 뜬다.
  - rekordbox가 켜져 있으면 막힌다. 막 끈 뒤 `master.db-wal`이 남아 있어도 막힌다.
  - 막히면 사람에게 rekordbox를 꺼 달라고 하거나 기존 스냅샷을 쓴다.
  - `--force`는 사람이 동의할 때만 쓴다. 최근 변경이 빠질 수 있다.
- `djc draft`는 `DJC_HOME`의 초안 폴더에 쓴다. `DJC_HOME` 기본값은 `~/Library/Application Support/DJCrate`다. 기본값이 곧 앱이 읽는 사용자 초안이다.
- 연습·시험에는 `DJC_HOME=$(mktemp -d)`와 `DJC_REKORDBOX_DIR=<합성 또는 사본 폴더>`를 함께 지정한다. DB를 읽는 명령마다 `--db <그 폴더/master.db>`를 붙인다.
  - `--db`만으로는 사용자 초안 폴더를 격리하지 못한다.
  - 명시한 DB의 그리드는 DB 옆 `share/PIONEER/USBANLZ`에서 읽는다.
  - 분석 파일이 없다고 라이브 파일로 대체하지 않는다.
- 이 CLI 조회·초안 명령의 DB 선택은 `--db` 또는 최신 스냅샷이다. 앱용 `DJC_DB`만 설정해서는 이 명령의 DB가 바뀌지 않는다.

## 명령

아래 조회·초안 명령에는 늘 `--json`을 붙여 기계가 읽는 출력을 받는다. `parse`를 제외한 표의 모든 명령에 `--db <사본.db>`를 붙일 수 있다. `jq`로 필요한 칸만 뽑는다.

### 읽기 (아무것도 바꾸지 않음)

| 명령 | 하는 것 | `data` |
|---|---|---|
| `djc search <검색어> [--bpm 최소-최대] [--key 키] [--playlist ID] [--filter 필터] [--comment-preset none\|anisong] --json` | 곡 찾기. 검색어는 제목·아티스트·코멘트·장르 부분 일치, `''`는 전체. 조건은 모두 함께 적용 | `{tracks}` |
| `djc track <ContentID> --json` | 곡 하나의 태그·큐·그리드·게인·소속 재생 목록·초안 여부 | `{track, cues, grid, gain?, playlists, drafts}` |
| `djc playlists [--tree] --json` | 재생 목록·폴더 | `{playlists}` |
| `djc playlist <ID> --json` | 재생 목록 곡을 순서대로(폴더면 하위 목록을 합침) | `{playlist, tracks}` |
| `djc histories --json` | 재생 기록을 날짜순으로 | `{histories}` |
| `djc history <ID> --json` | 기록 안의 곡을 재생 순서대로(반복 곡 유지) | `{history, entries}` |
| `djc duplicates --json` | 중복 후보 묶음·큐 수·직접 소속 목록 수·재생 수·형식·비트레이트 비교(읽기 전용) | `{lengthToleranceSeconds, groups}` |
| `djc drafts --json` | 초안이 있는 곡과 종류(cue·grid·gain·tag·artwork, 그림 초안은 앱에서만 만든다) | `{drafts}` |
| `djc report [--files] [--comment-preset none\|anisong] --json` | 라이브러리 현황 집계(코멘트 분류·큐 유무·확장자 등, `--files`면 없는 파일 수) | 집계 칸 |
| `djc parse "<코멘트>" --json` | 코멘트가 규칙(`TVA 작품명 OP 1` 꼴)에 맞는지 판정 | `{classification, parsed?}` |
| `djc path <제목> --json` | 제목으로 파일 경로 찾기(대소문자 구분) | `{paths}` |
| `djc compat --json` | rekordbox 버전·DB 구조가 쓰기를 확인한 모양인지 | 버전·카운터 |

`duplicates`는 제목과 아티스트를 정규화한다. NFC, 대소문자, 공백을 맞춘다. 길이 차이는 2초까지 비교한다. 괄호 속 버전은 구분한다.

제목, 아티스트, 길이 중 빈 것이 있는 곡은 제외한다. 삭제·스트리밍 곡도 제외한다. 한 곡이 여러 후보 묶음에 나올 수 있다.

`groups[].tracks[]`는 `track`, `cueCount`, `manualCueCount`, `playlistCount`, `playCount`, `format`을 담는다. 선택 칸으로 `bitrateKbps`와 `imagePath`(아트워크 경로)도 담는다. 같은 녹음이라는 확정이 아니다. 비교할 후보로만 제안하고 합치기·삭제는 하지 않는다.

`search`·`report`의 코멘트 프리셋 기본값은 `none`이다. 규칙 밖 코멘트를 찾으려면 사용자가 이 규칙을 원할 때 `--comment-preset anisong`을 함께 준다. `report`의 `commentClasses`·`prefixes`·`usages`도 이때만 나온다. `parse`는 프리셋 옵션 없이 애니송 코멘트 규칙을 검사한다.

`--filter` 이름:

| 이름 | 조건 |
|---|---|
| `no-cues` | 자동 큐를 포함해 큐가 하나도 없음 |
| `empty-comment` | 빈 코멘트 |
| `off-convention` | 규칙 밖 코멘트(구형·잔재·크레딧·기타), `--comment-preset anisong` 필수 |
| `no-bpm` | BPM이 없는 로컬 곡 |
| `missing-file` | 음원 파일을 찾지 못한 로컬 곡(스트리밍 곡 제외) |
| `tempo-change` | 그리드에 변속이 있음 |
| `played` · `streaming` · `all` | 재생 이력 있음 · 스트리밍 곡 · 전체(기본) |

### 초안 (DJCrate 초안 폴더에만 씀, 안전 규칙 3의 순서로)

| 명령 | 하는 것 |
|---|---|
| `djc draft cue <ContentID> --time <초> [--name 이름] [--dry-run] --json` | 큐 초안에 메모리 큐를 더한다 |
| `djc draft cue <ContentID> --slot <A~H> --time <초> [--name 이름] [--dry-run] --json` | 그 핫큐를 놓는다. 이미 있으면 **교체**한다 |
| 위 두 명령 + `--loop-end <초> [--beats <박>] [--active]` | 루프로 만든다 |
| `djc draft tag <ContentID> [--title …] [--artist …] [--album …] [--album-artist …] [--genre …] [--composer …] [--year …] [--track-number …] [--comment …] [--musical-key …] [--rating …] [--color …] [--dry-run] --json` | 태그 초안의 칸을 바꾼다. 하나 이상 준다 |
| `djc draft rm cue\|tag <ContentID> [--dry-run] --json` | 그 종류의 초안 전체를 버린다 |

루프 옵션은 이렇다.

- `--beats`는 양의 정수 또는 `0.5`·`0.25` 같은 1/n이다.
- `--active`는 활성 루프다. 곡에 활성 루프는 하나만 남는다.

`draft tag` 값은 이렇다.

- `''`는 값을 비운다. 제목은 비울 수 없다.
- 연도와 트랙 번호는 숫자만 받는다.
- 키는 `1A`~`12B`만 받는다. `''`는 키 지우기다.
- 평점은 `1`~`5`다.
- 곡 색은 `1`~`8`이나 rekordbox 색 이름이다.

`draft rm`은 rekordbox 원본·그리드·게인 초안을 건드리지 않는다. 없는 초안을 지워도 성공한다.

- 시각은 **rekordbox 시간축의 초**다. 자동 퀀타이즈하지 않는다.
- 박에 맞추려면 `djc track <ID> --json`의 `grid.segments[0]`에서 계산한다.
  - 첫 박은 `start`다. n박 뒤는 `start + n × 60 / bpm`이다.
  - 한 마디는 4박이다. `bpm`은 박 간격으로 구한 값이라 끝자리가 붙는다. 반올림하지 않는다.
  - 마디 첫 박은 `firstBeatNumber`가 1이 아니면 `(5 − firstBeatNumber) mod 4`박 뒤다.
  - `grid.status`가 `unavailable`이면 시각을 계산하지 않는다. `tempoChanges`가 있어도 계산하지 않는다. 앱에서 찍으라고 제안만 한다.
- 메모리 큐는 자동 큐를 포함해 10개까지다. 넘으면 `invalid_draft`가 난다.
- 같은 자리 ±30ms에 메모리 큐가 이미 있으면 새로 만들지 않고 이름도 바꾸지 않는다. 루프를 더할 때는 기존 루프만 해당하며 길이도 유지한다. `--dry-run` 결과로 확인한다.
- `--slot`을 주기 전에 `djc track <ID> --json`의 `cues[].hotCueSlot`으로 그 자리가 비었는지 본다. 차 있으면 교체해도 되는지 사용자에게 묻는다.
- 곡에 이미 초안이 있으면 그 초안에 이어 쓴다. 처음 만들 때의 rekordbox 값 `base`와 앱에서 한 편집을 유지한다.

JSON 약속은 아래와 같다. 자세한 칸은 저장소의 `docs/cli.md`에 있다.

- 성공: 종료 코드 0, stdout에 `{"schemaVersion":1,"command":…,"data":{…}}` 한 문서.
- 실패: 종료 코드 1, stdout은 비고 stderr에 `{"schemaVersion":1,"command":…,"error":{"code":…,"message":…}}`가 나온다. `message`에 할 일이 적혀 있다. `code`:
  - 모든 명령: `invalid_arguments`, `not_found`, `live_database`, `read_failed`
  - `draft`만: `invalid_draft`, `draft_io_failed`, `unverified_field`
    - `invalid_draft`: 기존 초안이 손상됐거나 메모리 큐 한도를 넘었다.
    - `draft_io_failed`: 초안 저장·삭제에 실패했다.
    - `unverified_field`: 동기화 곡이나 재생 목록에 든 곡의 평점·곡 색은 아직 쓰기를 확인하지 않았다.
- ID는 모두 문자열이다. 값이 없는 선택 칸은 키가 빠진다. 모르는 키는 무시한다.
- `Track`: `id`(ContentID), `title`, `artist`, `genre`, `comment`, `bpm`, `key`, `lengthSeconds`, `path`, `importedOn` 등. 값은 스냅샷 기준이다. 초안을 반영하지 않는다.
- `Cue`: `kind`, `hotCueSlot`, `inMsec`, `isLoop`, `isAutoGenerated`.
  - `kind`가 0이면 메모리 큐다. 그 밖의 값은 핫큐 슬롯이다.
  - `hotCueSlot`은 A~H다.
- `Grid`: `status`, `beatCount`, `segments`, `tempoChanges`. `segments`는 `{start, bpm, firstBeatNumber}`이고 `start`는 초다.
- `history`의 `entries[]`: `{id, trackNumber, track}`. `histories[].trackCount`는 반복 재생을 포함한 조회 가능한 항목 수다. `dateCreated`는 없으면 생략한다.
- `draft`의 `data`: `{kind: "cue"|"tag", action: "save"|"remove", contentID, trackUUID, dryRun, hasChanges, cue?, tag?}`.
  - `hasChanges`: 명령 뒤 남을 초안이 rekordbox 값과 다른지 나타낸다. `false`면 원본과 같아 초안을 저장하지 않는다. 삭제는 늘 `false`다.
  - `cue`: `{trackUUID, base, cues}`. `cues[]`는 `{id, kind, time, name, loop?}`이고 시각은 초다.
    - `kind`는 `{"memory":{}}` 또는 `{"hot":{"_0":슬롯}}`이다. 슬롯은 0=A … 7=H다.
    - `loop`는 `{end, beats?, active}`다.
  - `tag`: `{trackUUID, base, fields}`. `base`와 `fields`는 모두 아래 칸을 문자열로 담는다. `base`가 rekordbox 값이고 `fields`가 초안 값이다.
    - 칸: `title`, `artist`, `album`, `albumArtist`, `genre`, `composer`, `year`, `trackNumber`, `comment`, `musicalKey`
    - `musicalKey`는 rekordbox 키 이름이다. 예: `8A`. 키가 없으면 빈 문자열이다.
    - 키 칸이 없는 옛 초안 파일은 빈 문자열로 읽는다.

## 예시 흐름

아래 ID·제목·값은 모두 합성 예다. 실제 라이브러리의 곡을 예시로 옮겨 적지 않는다. 예시를 시험할 때는 위 준비 절차로 임시 `DJC_HOME`·합성 `DJC_REKORDBOX_DIR`을 지정한다. `parse`를 제외한 모든 명령에 `--db <합성 폴더/master.db>`를 추가한다. 이 예시 자체는 합성 DB를 만들지 않는다.

### 1. 조건으로 곡 찾기

"125~130 BPM, 8A 곡" 같은 요청:

```sh
djc search '' --bpm 125-130 --key 8A --json \
  | jq -r '.data.tracks[] | [.id, .title, .artist // "", .bpm, .key] | @tsv'
# 101	시험 Alpha	합성 아티스트	128	8A
```

- 키 표기는 라이브러리 값 그대로 비교한다. 대소문자만 무시한다. 먼저 결과의 `key` 값이 `8A`(Camelot)인지 `Am`인지 보고 같은 표기로 준다.
- 범위를 좁히려면 `--playlist <ID>`를 준다. ID는 `djc playlists --tree --json`에서 찾는다. 말로 찾으려면 검색어를 준다.

### 2. 큐 없는 곡 찾기와 큐 초안

```sh
djc search '' --filter no-cues --json | jq -r '.data.tracks[] | [.id, .title] | @tsv'
djc search '' --filter no-cues --playlist p1 --json   # 한 재생 목록 안에서만
djc drafts --json                                      # 이미 초안이 있는 곡은 빼고 제안
```

- 곡이 많으면 우선순위를 매겨 보여 준다. 순서는 재생 목록, 최근 추가(`importedOn`), 재생 이력이다. 재생 이력은 `--filter played` 결과와 겹치는 곡이다.
- 기본 제안은 이렇다: "DJCrate 앱에서 곡을 열어 메모리 큐 후보(곡 구조 분석)를 확인하고 찍으세요." 곡 구조는 djc로 읽을 수 없다.
- 사용자가 "첫 박에 메모리 큐를 찍어 줘"처럼 박 기준 큐를 고르면 그리드로 시각을 구해 초안을 만든다:

```sh
djc track 101 --json | jq -c '.data.grid | {status, tempoChanges, first: .segments[0]}'
# {"status":"available","tempoChanges":[],"first":{"bpm":128.00053753506577,"firstBeatNumber":1,"start":0.5}}
# 첫 박 0.5초, 32박(8마디) 뒤는 0.5 + 32 × 60 / 128.000538… ≈ 15.4999초
djc draft cue 101 --time 0.5 --name '첫 박' --dry-run --json \
  | jq -c '.data | {hasChanges, cues: [.cue.cues[] | {time, name}]}'
# {"hasChanges":true,"cues":[{"time":0.5,"name":"첫 박"}]}
djc draft cue 101 --time 0.5 --name '첫 박' --json | jq '.data.hasChanges'
djc drafts --json | jq -r '.data.drafts[] | [.contentID, .title, (.kinds | join(","))] | @tsv'
# 101	시험 Alpha	cue
```

- 끝나면 이렇게 안내한다: "DJCrate 앱에서 101 시험 Alpha의 큐 초안을 확인한 뒤, rekordbox를 끄고 rekordbox에 쓰세요(⇧⌘E)."

### 3. 코멘트·태그 정리 제안과 태그 초안

```sh
djc report --comment-preset anisong --json | jq '.data.commentClasses'          # convention·legacy·residue·credit·empty·other 개수
djc search '' --filter off-convention --comment-preset anisong --json | jq -r '.data.tracks[] | [.id, .title, .comment] | @tsv'
djc parse "TVA 시험 OP 1" --json | jq -r '.data.classification'   # 제안한 코멘트가 규칙에 맞는지 → convention
```

- 코멘트 규칙은 이 라이브러리 주인의 규칙이다. 사람이 원할 때만 규칙에 맞추는 제안을 한다. 제안값은 `djc parse`로 `convention`이 나오는지 확인한 뒤 보여 준다.
- 태그는 `search` 결과에서 두 가지를 찾는다.
  - 같은 아티스트·장르의 표기 흔들림: 대소문자, 띄어쓰기, 전각
  - 빈 장르와 빈 앨범
- 곡 하나의 전체 태그는 `djc track <ID> --json`으로 본다.
- 제안 표 칸: `ContentID | 제목 | 칸 | 지금 값 → 제안 값 | 이유`.
- 칸 이름은 앱과 같게 쓴다. 제목, 아티스트, 앨범, 앨범 아티스트, 장르, 작곡가, 연도, 트랙 번호, 코멘트, 키를 쓴다.
- 키는 사용자가 확인한 값만 제안한다. DJCrate·에이전트의 추정을 그대로 넣지 않는다.
- 사용자가 고른 줄만 곡마다 태그 초안으로 만든다:

```sh
djc draft tag 102 --comment 'TVA 시험 ED 1' --dry-run --json \
  | jq -c '.data | {hasChanges, before: .tag.base.comment, after: .tag.fields.comment}'
# {"hasChanges":true,"before":"시험 엔딩","after":"TVA 시험 ED 1"}
djc draft tag 102 --comment 'TVA 시험 ED 1' --json | jq '.data.hasChanges'
djc drafts --json | jq -r '.data.drafts[] | select(.kinds | index("tag")) | [.contentID, .title] | @tsv'
```

- 끝나면 이렇게 안내한다: "DJCrate 앱에서 태그 초안을 확인한 뒤, rekordbox를 끄고 rekordbox에 쓰세요(⇧⌘E). 음원 파일의 태그는 바뀌지 않습니다."

### 4. 세트용 곡 후보 뽑기

"126 BPM에서 시작해 132까지 올리는 30분 세트" 같은 요청:

```sh
djc playlists --tree --json | jq -r '.. | objects | select(.id? and .name?) | [.id, .name, .trackCount] | @tsv'
djc search '' --playlist f1 --bpm 124-134 --json \
  | jq -r '.data.tracks[] | [.id, .title, .bpm, .key, .lengthSeconds] | @tsv'
djc track 101 --json | jq '{cues: (.data.cues | length), tempo: .data.grid.tempoChanges, gain: .data.gain.decibels}'
```

- 후보마다 `track`으로 세 가지를 본다.
  - 큐가 있는지. 큐가 없으면 믹스 지점을 잡기 어렵다.
  - 변속(`tempoChanges`)이 있는지
  - 게인이 튀는지
- 순서는 BPM을 조금씩 옮기며 잡는다. 키는 Camelot 이웃으로 잇는다. 이웃은 같은 숫자의 A↔B, 같은 글자의 숫자 ±1이다. `lengthSeconds`를 더해 목표 길이에 맞춘다.
- 제안 표 칸: `순번 | ContentID | 제목 | BPM | 키 | 이음 이유`.
- 재생 목록 초안은 사람이 앱에서 만든다. `djc draft`에는 재생 목록 초안 명령이 없다. `playlist-write`는 초안 생성이 아니라 DB 쓰기다. 이 스킬에서는 실행하지 않는다.

## 제안을 보여 줄 때

- 곡마다 ContentID와 제목을 함께 적는다. 사람이 앱에서 찾을 수 있어야 한다.
- 바꿀 값은 "지금 값 → 제안 값"과 이유 한 줄로 쓴다. 확실하지 않으면 그렇다고 적는다.
- 표 끝에 "고른 줄만 초안으로 만들까요?"라고 묻는다. 답을 받기 전에는 `djc draft`를 실행하지 않는다.
- 초안을 만든 뒤에는 만든 곡·종류와 앱에서 확인할 곳을 적는다. 그다음 "DJCrate 앱에서 초안을 확인한 뒤, rekordbox를 끄고 rekordbox에 쓰세요(⇧⌘E)"를 한 줄 붙인다.

## 문제 해결

| 오류 | 할 일 |
|---|---|
| `live_database` | `--db`에서 라이브 경로를 빼고 스냅샷을 읽는다 |
| `read_failed` "스냅샷이 없습니다" | `djc snapshot`(rekordbox가 켜져 있으면 사람에게 먼저 묻는다) |
| `not_found` | `djc search`로 ContentID, `djc playlists`로 재생 목록 ID, `djc histories`로 재생 기록 ID를 확인한다 |
| `invalid_arguments` | `message`대로 인자를 고친다(시각은 곡 길이 안, 루프 끝은 시작 뒤, 슬롯은 A~H). 사용법은 인자 없이 `djc` |
| `invalid_draft` 메모리 큐 한도 | 앱에서 기존 메모리 큐를 정리하라고 안내한다. 초안 파일을 고치지 않는다 |
| `invalid_draft` 초안 손상 | 사람에게 알리고 멈춘다. 초안 파일을 고치거나 `draft rm`으로 지우지 않는다 |
| `draft_io_failed` | `DJC_HOME` 초안 폴더의 접근 권한을 사람에게 확인해 달라고 한다 |
| `unverified_field` | 그 곡의 평점·곡 색은 rekordbox에서 직접 고치라고 안내한다. 다른 칸 초안은 그대로 만들 수 있다 |
