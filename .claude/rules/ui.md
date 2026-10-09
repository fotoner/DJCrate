---
paths:
  - "Sources/DJCrate/**"
  - "Sources/DJCDomain/Settings/**"
---

# 앱 화면·설정을 고칠 때

앱 화면과 설정 코드를 고칠 때 지키는 규칙이다. 리뷰는 규칙을 ID로 가리킨다.

## 재생 중 화면

- **UI-1** 재생 중 매 프레임 바뀌는 관찰 값은 큰 뷰가 읽지 않게 한다.
- **UI-2** 글자와 전체 파형 재생선은 `displayTime`(15Hz)으로 갱신한다. 레벨 미터는 재생 틱(`meterFrame`)으로 갱신한다.
- **UI-3** 관찰 범위를 좁혀 둔 곳을 고치면 그 묶음 전체를 다시 돌린다(#129, #137, #138). 좁혀 둔 곳은 아래와 같다.
  - `ContentView`에서 떼어 낸 하위 뷰
  - `TrackTable.updateNSView`
  - 사이드바 줄 뷰
- **UI-4** `.perfContract` 시험을 고쳐도 그 묶음 전체를 다시 돌린다. 명령은 `docs/ci.md` "선택 실행 장치"에 있다.

## 경계

- **UI-5** 화면 모델과 뷰는 `DJCApplication`·`DJCDomain`만 import한다.
- **UI-6** 화면 모델과 뷰는 실제 구현(`.live`)을 기본 인자로 고르지 않는다.
- **UI-7** UI-5·UI-6의 예외는 조립 지점(`App/AppComposition.swift`·`AppComposition+Usb.swift`)과 `Diagnostics/`뿐이다. `Diagnostics/`는 디버그 자가 테스트다.
- **UI-8** 화면 코드는 위치를 직접 정하지 않는다. 조립 지점이 준 값을 쓴다. 아래 API는 직접 부르지 않는다.
  - `DJCPaths`
  - `DJCCachePaths.current`
  - `LibrarySnapshot.latest`, `LibrarySnapshot.take`
- **UI-9** 목록 그림 캐시는 라이브러리 저장소가 하나씩 든다. `previewImages`는 `PreviewWaveformCache`, `thumbnails`는 `Thumbnails`다. 원자료는 포트로 읽는다.

## 설정

- **UI-10** 설정의 이름·기본값·범위는 `SettingKeys`에 모은다.
- **UI-11** 설정 이름은 옛 UserDefaults 키 그대로 둔다. 바꾸면 쓰던 값을 잃는다.
- **UI-12** 덱 단축키는 키 위치(키 코드)로 정한다. 기본과 다른 동작만 저장한다.
- **UI-13** ⌘·⌃·⌥ 조합은 지정할 수 없다. 목록 확정·이동 키(`DeckShortcuts.reservedKeys`)도 지정할 수 없다.

## 실행 인자와 캡처

- **UI-14** 새 앱 실행 인자는 `--이름=값` 한 덩어리로 만든다. 값을 띄어 쓴 `--perf-hide zoom`은 AppKit이 값을 열 파일로 봐서 앱이 멈췄다.
- **UI-15** UI가 바뀌는 수정은 실제 앱의 변경 전·후 화면을 캡처한다. 두 캡처는 같은 합성 데이터로 찍는다.
- **UI-16** 캡처 방법은 `docs/issues.md` "흐름"과 스킬 `app-selftest`에 있다.

## 더 보기

- 잰 값과 고친 내력: [`docs/architecture.md` "화면 성능"](../../docs/architecture.md#화면-성능)
- 화면 모델의 경계: [`docs/architecture.md` "경계 규칙"](../../docs/architecture.md#경계-규칙)
- 켜서 도는 묶음: [`docs/ci.md` "선택 실행 장치"](../../docs/ci.md#선택-실행-장치)
