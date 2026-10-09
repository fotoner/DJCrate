---
name: app-selftest
description: 디버그 앱 자가 테스트(--write-selftest·--loop-selftest·--usb-selftest·--edit-selftest·--ui-perf 등)로 소리·실제 UI·rekordbox 쓰기 전 과정을 확인할 때 쓴다. 인자표, 합성 픽스처를 만드는 명령, 임시 폴더·잠금·timeout·로그 grep 요령이 있다.
---

# 디버그 앱 자가 테스트

단위 시험으로 못 잡는 소리·실제 UI·rekordbox 쓰기 전 과정을 디버그 빌드 앱(`.build/debug/DJCrate`)이 스스로 돌려 본다. 자가 테스트는 **디버그 빌드에만** 있다.

## 돌리기 전에

1. 같은 checkout의 Swift 빌드·시험이 끝났는지 본다. 동시에 돌리지 않는다.
2. `swift build`로 디버그 앱을 만든다.
3. 늘 임시 데이터 폴더를 준다: `DJC_HOME=$(mktemp -d)`. 그래야 초안이 사용자 것과 섞이지 않는다.
4. rekordbox 폴더가 필요하면 `DJC_REKORDBOX_DIR=<합성 또는 사본 폴더>`와 `--db <그 폴더/master.db>`를 함께 준다.
5. 사본의 `share/PIONEER/USBANLZ`는 링크로 두지 않는다. 실제 파일로 복사한다.
6. 실행에 맞는 잠금을 잡는다.
   - 무거운 실행: `lockf /tmp/djc-heavy.lock`. 성능 측정과 여러 앱 실행이 여기에 든다.
   - 소리를 내는 실행: 본인이 잡은 `/tmp/djc-audio.lock`(5분 이하)
   - 창을 앞에 두는 실행과 키를 넣는 실행: `/tmp/djc-gui.lock`
7. `timeout 60`~`300`을 걸어 포그라운드로 돌린다.
8. 출력은 파일로 받는다(`> <로그> 2>&1`). 그 뒤 필요한 줄만 grep한다.
9. 결과는 그 줄과 종료 코드로 보고한다.

```bash
DJC_HOME=$(mktemp -d) timeout 120 .build/debug/DJCrate --db <스냅샷 사본> --select 32395449 --loop-selftest > /tmp/djc-loop.log 2>&1; echo "exit=$?"
grep "루프 시험" /tmp/djc-loop.log
```

- 앱 개발용 실행 인자는 둘이다. 이 둘은 값을 띄어 쓴다.
  - `--db <스냅샷>`: 그 사본을 연다. 환경 변수 `DJC_DB`와 같다.
  - `--select <ContentID>`: 곡을 골라 둔다.
- `--db=<사본>`은 읽지 않는다. 이렇게 쓰면 앱이 기본 위치를 연다.
- 자가 테스트·측정의 값 받는 인자는 `--이름=값` 한 덩어리다(`.claude/rules/ui.md`). 새로 만드는 인자도 같다.
- 한 덩어리 인자의 예: `--jump-bpm=180`, `--resize-perf=…`, `--…-capture=<폴더>`.
- 설치한 DJCrate 앱을 끄지 않는다. 바꾸지도 않는다.

## 인자표

| 인자 | 확인하는 것 | 추가 조건 |
|---|---|---|
| `--itunes-selftest` | iTunes 목록 순서·읽기 전용 제한·덱 핫큐·태그 초안·DB 불변 | `ITunesFixtureCapture` 합성 사본을 `DJC_REKORDBOX_DIR`·`--db`로 |
| `--write-selftest` | 반영(미리 보기·쓰기·조용한 다시 읽기·되돌리기) 전 과정. 재생 목록 초안(새 폴더·목록, 있던 목록에 곡)도 만들어 함께 쓰고 되돌린다 | `DJC_REKORDBOX_DIR` 사본 필수. 합성 사본은 `PlaylistWriteFixtureCapture` |
| `--history-selftest` | USB 보존 기록(#43)의 화면·쓰기 대기·미리 보기·쓰기·다시 읽기·복원 뒤 재대기("히스토리 시험 통과" 줄). `--history-capture=<임시 폴더>`로 대기·쓴 뒤·복원 뒤 창을 PNG로 남긴다 | `DJC_HISTORY_SELFTEST_FIXTURE=<없는 임시 폴더> swift test --filter HistorySelfTestFixtureCapture`로 만든 폴더를 `DJC_REKORDBOX_DIR`로, `--db <그 폴더>/history-snapshot.db`, 임시 `DJC_HOME`. 소리·실물 USB 없이 돈다 |
| `--loop-selftest` | 활성 루프·즉석 루프·½·핫큐 저장·나가기 | `--select`로 활성 루프 있는 곡 |
| `--loop-audio-selftest` | 루프 이음새가 샘플 단위로 맞는지(램프 WAV) | — |
| `--hotcue-click-selftest` | 2초 스크럽·관성이 실제 파형 모니터에 도착하는지(21·42개), 관성 누출과 핫큐 클릭·이동(물리 트랙패드의 OS 감속·클릭 억제는 별도 확인) | `EditLayoutFixtureCapture` 합성 라이브러리를 `DJC_REKORDBOX_DIR`·`--db`로 |
| `--scrub-hotcue-selftest` | 확대 파형을 끄는 중 핫큐 키: 진짜 키 이벤트가 KeyRouter에 오지 않는 것, 빈 칸 찍기·저장된 칸으로 옮겨 이어 끌기·놓은 뒤 재생(키는 합성 키보드 상태) | `EditLayoutFixtureCapture` 합성 라이브러리. 덱 창이 키 창이 돼야 한다(못 하면 exit 2) |
| `--jump-audio-selftest` | 재생 퀀타이즈 핫큐 점프가 박 경계에서 샘플 단위로 넘어가는지(램프 WAV, ¼·1박·루프 핫큐·다시 누름, `--jump-bpm=180`으로 빠른 곡도) | — |
| `--flip-selftest` | Flip 기록이 들린 소리와 샘플 단위로 같은지, 출력 장치 변경이 점프로 남지 않는지("Flip 시험 통과" 줄). 아래 자세히 | — |
| `--metronome-jump-selftest` | 핫큐 점프 직후 60→180 BPM 그리드의 클릭 간격·강박 전환(실제 오디오) | — |
| `--metronome-selftest` | 메트로놈 클릭이 빠지지 않는지(실제 엔진으로 12초 재생해 클릭 수를 셈) | — |
| `--switch-selftest` | 곡 전환·일시정지 뒤 소리 | — |
| `--scroll-perf` | 재생 중 목록 스크롤 때 프레임 간격 | `--perf-hide=zoom,label,…`로 A/B |
| `--resize-perf=all` | 활성화·입력·재생 없이 가로·세로 40단계씩 창 크기를 바꾸며 잰 값을 JSON으로. 첫 왕복은 준비 측정. 아래 자세히 | `UIPerfFixtureCapture` 합성 라이브러리와 `DJC_DB`·`DJC_REKORDBOX_DIR`·임시 `DJC_HOME`, `/tmp/djc-heavy.lock` 필수. 실제 가장자리 드래그·표시 FPS는 별도 확인 |
| `--ui-perf=all` | 조작마다 메인 스레드 일한 시간·프레임 간격·본문 다시 계산 횟수(`PerfProbe.body`)·메인 CPU. 아래 자세히 | `UIPerfFixtureCapture` 합성 라이브러리를 `DJC_REKORDBOX_DIR`·`--db`로 |
| `--edit-selftest` | 곡 편집 창의 재생·편집·렌더와 덱 연결. 아래 자세히 | `EditLayoutFixtureCapture` 합성 라이브러리를 `DJC_REKORDBOX_DIR`·`--db`로 |
| `--usb-selftest` | 합성 라이브러리로 USB 내보내기·편집·옮기기·되돌리기 전 과정("USB 시험 통과" 줄). 아래 자세히 | rekordbox 꺼짐, 임시 `DJC_HOME`, `--db <스냅샷 사본>`(`DJC_HOME`은 스냅샷을 옮기지 않는다). 앱 없이 같은 흐름: `DJC_USB_SELFTEST_SCRATCH=<임시 폴더>`로 `UsbSelfTestScenarioCapture` |
| `--xml-export-capture=<폴더>` | 라이브러리 XML 내보내기(#72) 캡처와 결과 확인("라이브러리 XML 시험 통과" 줄). `<폴더>`는 `DJC_HOME` 밖. 아래 자세히 | `XMLExportFixtureCapture` 합성 라이브러리를 `DJC_REKORDBOX_DIR`·`--db`로, 임시 `DJC_HOME` |
| `--xml-import-capture=<폴더>` | rekordbox XML 가져오기(#72) 캡처와 결과 확인("rekordbox XML 가져오기 시험 통과" 줄). `<폴더>`는 `DJC_HOME` 밖. 아래 자세히 | `XMLExportFixtureCapture` 합성 라이브러리를 `DJC_REKORDBOX_DIR`·`--db`로, 임시 `DJC_HOME` |
| `--key-routing-selftest` | 앱 안 키 전달(검색칸·곡 목록·태그 시트·부착 시트·모달·곡 편집 창) | [captures.md](captures.md) |

### 인자별 자세히

`--flip-selftest`

- 램프 WAV로 퀀타이즈 끔·켬 핫큐를 기록한다. 루프 핫큐·나가기도 기록한다.
- 그 기록을 섞지 않은 채 렌더한다. 렌더 결과를 곡 믹서 출력과 이음새·프레임 단위로 비교한다.

`--resize-perf=all`

- 단계별로 크기 요청, 레이아웃/표시 처리, 확대 파형 Canvas 시간, 본문 횟수를 잰다.
- 왕복별로 프레임 간격 중앙값/최댓값, 메인 CPU, 부하를 잰다.
- 축·반복·창 JPEG 캡처는 `--resize-perf=width,height`, `--resize-perf-repeats=3`, `--resize-perf-capture=<폴더>`로 정한다.

`--ui-perf=all`

- 재는 조작은 아래와 같다.
  - 사이드바·인스펙터 여닫기, 창 크기, 스크롤, 선택
  - 사이드바 항목, 정렬, 검색, 덱에 올리기
  - 확대·축소, 스크럽, 재생, 태그 시트
  - 곡 편집 창, 쓰기 미리 보기
- `--ui-perf=sidebar,sort`처럼 골라 잴 수 있다.
- 조작마다 관심 지점 구간을 남긴다. 이 구간을 `xctrace` Time Profiler로 나눠 본다.
- `--perf-trace-body`는 본문을 다시 계산한 이유를 찍는다.
- `grid`·`drafts`·`capture`는 `all`에 없다.
- `--ui-perf-delay=<초>`는 `xctrace record --attach <PID>`를 붙일 시간을 준다.
- 옛 빌드와 전후를 잴 때 앱 바이너리만 다른 폴더로 복사하면 `@rpath`의 SQLCipher를 못 찾는다. 그러면 종료 코드 70으로 바로 끝난다. `.build/out/Products/Debug/SQLCipher.framework`를 바이너리 옆에 함께 복사한다.

`--edit-selftest`

- 창 재생기: 스페이스바, 시킹, 이음새 듣기. 덱은 그대로다.
- 편집: 넣기, 자르기, 복제, 옮기기, 지우기
- 편집 메뉴 실행 취소, 확대 키
- 실제 마우스 끌기: 클립 끝 다듬기, 원곡 구간 끌어 넣기. 앱이 앞에 있을 때만 한다.
- 렌더, 추가한 곡으로 이동, 덱에 편집본

`--usb-selftest`

1. 합성 라이브러리를 디스크 이미지에 내보낸다.
2. 이미지를 꺼낸 뒤 다시 붙여 확인한다.
3. USB 편집을 한다: 곡 빼기·목록 만들기·이름 바꾸기 초안 → 미리 보기 → 쓰기 → 다시 읽기 → 되돌리기. "USB 시험 편집 통과" 줄을 본다.
4. 되돌린다.
5. 옮기기를 한다: Device Library만 내보내기 → OneLibrary 더하기 → 원래 파일 SHA-256 → 다시 붙여 읽기 → 되돌리기. "USB 시험 옮기기 통과" 줄을 본다.
6. 끝에 "USB 시험 통과" 줄을 본다.

`--xml-export-capture=<폴더>`

- 합성 라이브러리를 내보낸다. 이때 진행 줄과 완료 안내를 `<폴더>`에 캡처한다.
- 내보낸 파일의 곡·재생 목록 수와 사본 DB 불변을 확인한다.

`--xml-import-capture=<폴더>`

- 내보낸 XML을 고쳐 가져온다. 고치는 것은 제목, 핫큐, 그리드, 새 재생 목록이다.
- 미리 보기와 결과 시트를 캡처한다.
- 차이 수, 만든 초안 수, 사본 DB 불변을 확인한다.

화면 전·후 캡처 인자와 키 전달 시험의 활성 모드는 [captures.md](captures.md)에 있다. 캡처 인자는 `--async-guidance-capture=`, `--issue237-capture=`, `--column-header-capture=`다.

## 합성 픽스처 만들기

픽스처는 시험 타깃 안의 "캡처" 시험이 만든다. 이 시험은 환경 변수로 받은 폴더에 합성 자료를 쓴다(실데이터 없음). `scripts/check.sh --quick`이 임시 `DJC_HOME`·`DJC_REKORDBOX_DIR`을 함께 준다.

1. 폴더는 임시 폴더 아래에, 아직 없는 이름으로 준다.
2. 아래 블록에서 필요한 줄만 고른다.
3. 고른 줄을 **한 호출 안에서** 돌린다. 셸 변수는 다음 Bash 호출에 남지 않는다.
4. 명령이 출력한 절대 경로를 적어 둔다.
5. 다음 호출에서 그 경로를 그대로 쓴다(`--db`·`DJC_REKORDBOX_DIR`).

```bash
W=$(mktemp -d); echo "픽스처 폴더: $W"
DJC_EDIT_LAYOUT_FIXTURE=$W/edit scripts/check.sh --quick --filter EditLayoutFixtureCapture
DJC_UI_PERF_FIXTURE=$W/perf scripts/check.sh --quick --filter UIPerfFixtureCapture
DJC_PLAYLIST_FIXTURE=$W/playlist scripts/check.sh --quick --filter PlaylistWriteFixtureCapture
DJC_ITUNES_FIXTURE=$W/itunes scripts/check.sh --quick --filter ITunesFixtureCapture
DJC_XMLEXPORT_FIXTURE=$W/xml scripts/check.sh --quick --filter XMLExportFixtureCapture
DJC_TRACK_LIST_FIXTURE=$W/list scripts/check.sh --quick --filter TrackListFixtureCapture
DJC_LAYOUT_FIXTURE=$W/layout scripts/check.sh --quick --filter LayoutFixtureCapture
DJC_ASYNC_FIXTURE=$W/async scripts/check.sh --quick --filter AsyncGuidanceFixtureCapture
mkdir $W/usb && DJC_USB_SELFTEST_SCRATCH=$W/usb scripts/check.sh --quick --filter 'UsbSelfTestScenarioCapture|UsbMigrateAppFixtureCapture'
```

만든 폴더의 `master.db`를 `--db`로, 그 폴더를 `DJC_REKORDBOX_DIR`로 준다. 폴더마다 정확한 모양은 그 캡처 시험 파일(`Tests/DJCrateTests/*FixtureCapture.swift`) 맨 위 주석에 있다.

## 보고

- 돌린 명령(인자·환경 변수)과 종료 코드를 적는다.
- grep한 통과·실패 줄과 수치를 적는다.
- 통과 줄이 없으면 통과로 쓰지 않는다.
- 자가 테스트가 대신하지 못하는 것은 "확인하지 않음"으로 남긴다. 예: 물리 입력(트랙패드·키보드·IME), 실제 표시 FPS.
