---
paths:
  - "Sources/RekordboxKit/**"
  - "Sources/DJCDomain/Cue/**"
  - "Sources/DJCDomain/Grid/**"
  - "Sources/DJCDomain/Reflection/**"
  - "Sources/DJCDomain/Rekordbox/**"
  - "Sources/DJCApplication/Reflection/**"
  - "Sources/DJCAdapters/Reflection/**"
  - "Sources/DJCApplication/Library/LibraryLocation.swift"
  - "Sources/DJCAdapters/Library/LibraryLocation+Resolve.swift"
  - "Sources/DJCrate/App/AppComposition.swift"
  - "Sources/DJCrate/Library/LibraryStore+ReflectionState.swift"
  - "Sources/DJCrate/Library/LibraryStore+ITunesSync.swift"
  - "Sources/DJCrate/Reflection/**"
  - "Sources/djc/CLIComposition.swift"
  - "Sources/djc/Commands/CLIWriteTarget.swift"
  - "Sources/djc/Commands/MainCommands.swift"
  - "Sources/djc/Commands/PointSnapshotCommand.swift"
  - "Sources/djc/Lab/LabWorkFolder.swift"
  - "Tests/RekordboxKitTests/**"
  - "Tests/Support/Ports/**"
---

# rekordbox 쓰기 코드를 고칠 때

AGENTS.md "안전 불변식"의 rekordbox 줄을 자세히 적은 규칙이다. 리뷰는 규칙을 ID로 가리킨다.

- **RBW-1** 먼저 `docs/rekordbox-internals.md`를 읽는다.
- **RBW-2** 그 문서의 칸·순서·usn 규칙은 rekordbox 실험으로 확인한 것이다. 다시 확인하지 않고는 바꾸지 않는다.

## 쓰기 입구와 관문

- **RBW-3** 쓰기 입구는 RekordboxKit 최상위에 그대로 둔다. 입구 파일은 쓰기 커버리지 그룹이다.
- **RBW-4** 초안 쓰기 `RekordboxWriter.write`와 곡 넣기·빼기 `RekordboxTrackWriter.add`·`delete`는 아래 순서를 지킨다.
  1. 사전 확인
  2. 전체 백업
  3. 한 트랜잭션으로 쓰기
  4. 다시 읽어 검증
  5. 무결성 검사
  6. 실패하면 복원
- **RBW-5** 되돌리기 `RekordboxWriter.restore`는 쓰기 전 백업이나 시점 스냅샷으로 되돌린다. 되돌리기 직전 상태를 먼저 백업한다. 실패하면 원래 상태로 둔다.
- **RBW-6** `djmdProperty.DBID`가 다른 라이브러리의 백업은 거부한다.
- **RBW-7** 모든 입구는 먼저 관문 `RekordboxWriteGuard`를 지난다. 관문 함수는 `checkTargets`·`resolveShareRoot`다.
- **RBW-8** 새 쓰기 입구도 이 관문을 지나게 한다. 그래야 시험 프로세스의 실제 라이브러리 거부(#182)를 받는다.
- **RBW-9** 앱과 CLI는 같은 반영 세션 `ReflectionSession`(DJCApplication)으로 쓴다. 세션은 쓰기 관문 포트 `RekordboxWriteGate`로 입구를 부른다. 이 길로 가는 동작은 아래와 같다.
  - 앱: 반영, 곡 넣기·빼기, 복원, 시점 복원, iTunes 동기화
  - CLI: `cue-write`, `rekordbox-restore`, `track-add`, `track-delete`, `playlist-write`, `snapshot-point restore`
- **RBW-10** 새 쓰기 동작은 이 포트에 클로저로 더한다. 그 뒤 세션의 단계로 부른다. 앱과 CLI가 같은 세션을 쓴다.
- **RBW-11** 시점 스냅샷은 앱 창, CLI, 자동 실행 모두 유스케이스 `PointSnapshots`를 지난다. 복원만 반영 세션을 거쳐 관문으로 간다.
- **RBW-12** 실제 구현 `RekordboxWriteGate.live()`는 입구를 감싸기만 한다. RBW-4의 안전 단계를 다시 만들지 않는다.
- **RBW-13** 이 실제 구현은 `Sources/DJCAdapters/Reflection/RekordboxWriteGate+Live.swift`에 있다. 이 파일도 쓰기 커버리지 그룹이다. 조립 지점만 이 구현을 고른다.
- **RBW-14** 쓰기·복원 API에 라이브 DB 기본 인자를 두지 않는다. 대상은 부르는 쪽이 적는다.
- **RBW-15** 앱의 쓰기와 되돌리기 대상은 하나다. 조립 지점 `AppComposition.live()`가 위치 값 `LibraryLocation`으로 그 대상을 정한다. iTunes 동기화도 이 대상에 쓴다. 명시한 사본(`--db`)은 읽기 출처만 바꾼다.
- **RBW-16** 그 대상은 반영 세션의 `target`이다. `LibraryStore.rekordboxDatabase`와 같은 곳이다.
- **RBW-17** CLI의 대상은 `RekordboxWriteTarget.cli`가 `--live`·`--db`를 풀어 정한다.

## 사전 확인

`RekordboxCompatibility`와 `RekordboxWriteGuard`가 쓰기 전에 아래를 본다.

- **RBW-18** rekordbox 7.2.x에만 쓴다.
- **RBW-19** DB 구조가 확인한 모양일 때만 쓴다. 새 행을 넣는 표(예: `djmdCue`, `contentCue`)는 칸이 정확히 같아야 한다. 고치는 칸은 있어야 한다.
- **RBW-20** `DBVersion`이 6000일 때만 쓴다.
- **RBW-21** 로컬 변경 카운터 ≥ 클라우드 동기화 카운터일 때만 쓴다.
- **RBW-22** 막힐 조건은 백업을 뜨기 전에 본다.
- **RBW-23** rekordbox 버전이 바뀌면 `djc compat`으로 먼저 확인한다.
- **RBW-24** 허용 버전(`verifiedAppVersions`)과 `DBVersion`은 넓히지 않는다. 넓히려면 먼저 rekordbox 실험으로 쓰기 결과를 다시 확인한다.
- **RBW-25** 새 행을 넣는 표가 늘면 `RekordboxCompatibility.exactColumns`에 더한다. 고치는 칸이 늘면 `requiredColumns`에 더한다.

## 막아 둔 것

- **RBW-26** 아래 쓰기는 막아 둔다. rekordbox 실험과 사본 재현으로 칸 단위 일치를 확인하기 전에는 풀지 않는다.
  - 반쪽 분석 곡(`.DAT`만)의 그리드
  - 카운터가 있는 분석 전 곡의 분석 붙이기
  - 미확인 ALAC 형식의 분석 붙이기
  - MPEG-1(32·44.1·48kHz)이 아닌 ffmpeg VBR의 분석 붙이기
  - 그 밖의 비LAME VBR의 분석 붙이기
  - CRC가 맞지 않는 프레임이 있는 FLAC의 분석 붙이기
- **RBW-27** 전체 목록은 [`docs/rekordbox-internals.md` "막아 둔 것"](../../docs/rekordbox-internals.md#막아-둔-것-규칙-미확인)에 있다.
- **RBW-28** 그리드 쓰기는 파형 파일(`.EXT`)이 있는 곡에만 한다.
- **RBW-29** 분석 파일이 없는 곡은 분석 파일을 만들어 붙인다(`RekordboxWriter+Analysis`).

## 고칠 때

- **RBW-30** 새로 쓰는 칸이 생기면 검증 쪽(`RekordboxWriter+Verify`)도 같이 고친다. 검증이 그 칸을 다시 읽어 비교하게 한다. 큐 비교 열쇠는 `key(_:withSource:)`다.
- **RBW-31** `Tests/RekordboxKitTests`에 골든 시험을 먼저 쓴다. 실패를 본 뒤 코드를 고친다.
- **RBW-32** 골든 시험에는 실험 곡과 날짜를 주석으로 단다.
- **RBW-33** 시험 재료는 `RekordboxFixture`와 `AnlzBuilder`다. `RekordboxFixture`는 구조만 있는 7.2.18 DB다.
- **RBW-34** 새 규칙을 알아내면 `docs/rekordbox-internals.md`에 적는다. 날짜, 실험 곡, 확인 방법을 함께 적는다.
- **RBW-35** 작업 폴더를 비워 다시 만드는 lab 명령은 `LabWorkFolder.reset`을 지난다. 이 함수는 임시 폴더 아래만 받는다.
- **RBW-36** `LabWorkFolder.reset`은 rekordbox·DJCrate 데이터 폴더와 겹치는 폴더를 지우기 전에 거부한다(`docs/cli.md`).
- **RBW-37** 사용자가 준 폴더를 직접 `removeItem`하지 않는다.

## 바꾼 뒤 확인

- **RBW-38** 바꾼 뒤 아래 순서로 확인한다. 모두 사본으로 한다.
  1. `scripts/check.sh --changed`를 돌린다.
  2. 쓰기 그룹 파일을 바꿨으면 쓰기 그룹 커버리지(80%)도 이때 본다. 세 시험 타깃을 통째로 돌아 약 5분 걸린다.
  3. `djc compat`을 돌린다.
  4. `djc cue-write --db <스냅샷 사본> --dry-run`을 돌린다. 기존 초안의 쓰기/막힘 결과가 바꾸기 전과 같아야 한다.
  5. 그리드를 바꿨으면 `djc lab grid-write-test <사본.db> <사본 share> <UUID> <BPM>`을 돌린다. 이 명령은 라이브 DB와 분석 폴더를 거부한다.
  6. 흐름 전체는 `--write-selftest`로 본다(스킬 `app-selftest`). 환경 변수 `DJC_REKORDBOX_DIR=<사본> DJC_HOME=<임시>`를 준다.
- **RBW-39** 쓰기 그룹 커버리지(80%)는 쓰기 그룹 파일을 바꾼 `--changed`가 본다. PR·`dev` CI도 같다. 코어 커버리지(60%)는 릴리스 전체 검사가 본다.

## 더 보기

- 실험으로 확인한 형식과 쓰기 규칙: [`docs/rekordbox-internals.md`](../../docs/rekordbox-internals.md)
- 새 쓰기 경로를 여는 순서: [`docs/rekordbox-internals.md` "새 쓰기 경로를 여는 방법"](../../docs/rekordbox-internals.md#새-쓰기-경로를-여는-방법), 스킬 `rekordbox-experiment`
- 반영 흐름과 쓰기 관문의 자리: [`docs/architecture.md` "rekordbox 쓰기"](../../docs/architecture.md#rekordbox-쓰기)
