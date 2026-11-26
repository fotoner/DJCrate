---
paths:
  - "Sources/DJCAdapters/Audio/**"
  - "Sources/DJCrate/Deck/Audio/**"
  - "Sources/DJCApplication/Deck/DeckAudioEngine.swift"
  - "Sources/DJCApplication/Edit/EditAudio.swift"
  - "Sources/DJCrate/Deck/DeckModel+Transport.swift"
  - "Sources/DJCrate/Deck/DeckModel+Loops.swift"
  - "Sources/DJCrate/Deck/DeckModel+Flip.swift"
  - "Sources/DJCrate/Edit/TrackEditModel+Playback.swift"
  - "Sources/DJCDomain/Playback/**"
---

# 오디오·재생 코드를 고칠 때

덱과 곡 편집 창의 재생 코드를 고칠 때 지키는 규칙이다. 리뷰는 규칙을 ID로 가리킨다.

## 엔진의 자리

- **AUD-1** 오디오 엔진 포트는 DJCApplication에 둔다. 덱은 `DeckAudioEngine`, 곡 편집 창은 `EditAudio`다.
- **AUD-2** 실제 구현은 `Sources/DJCAdapters/Audio/`에 둔다. 여기에 있는 타입은 아래와 같다.
  - `DeckAudio`
  - `EditAudioPlayer`
  - `DecodedAudio`
  - `AudioEngineQueue`
- **AUD-3** 실제 구현은 조립 지점이 고른다. 곡 편집 창은 `EditWindowLinks.makeAudio`로 받는다.
- **AUD-4** 덱 조작 기록은 포트의 `recordEvent`로 남긴다. 음원 열기 실패 판정은 포트의 `failureState(for:)`가 한다.
- **AUD-5** 오디오 엔진은 메인 액터 동기로 둔다. async나 actor로 바꾸지 않는다.
- **AUD-6** 덱 재생 경로에서는 화면 모델이 엔진 포트를 직접 부른다. 이것은 경계 규칙에 적어 둔 예외다.

## 엔진 다루기

- **AUD-7** `AVAudioEngine.pause()`를 쓰지 않는다. 멈출 때는 `stop()`을 쓴다.
- **AUD-8** 출력 장치를 여는 엔진 호출(`mainMixerNode`·`outputNode`)은 메인 스레드에서 하지 않는다(#142).
- **AUD-9** 엔진 그래프는 `AudioEngineQueue`에서 만들어 넘겨받는다.
- **AUD-10** 오디오 탭과 렌더 콜백은 메인 액터 밖(`nonisolated static`)에서 만든다. 메인 액터 격리를 물려받으면 오디오 스레드에서 죽는다.

## 루프와 점프

- **AUD-11** 루프와 퀀타이즈 점프는 재생 노드에 버퍼를 예약해 샘플 단위로 잇는다.
- **AUD-12** 무엇을 언제 예약할지는 `LoopPlanner`·`JumpPlanner`가 정한다. 둘은 순수 규칙이라 `DJCDomainTests`에서 시험한다.
- **AUD-13** `DeckAudio`는 그 예약을 그대로 실행한다.
- **AUD-14** 예약은 렌더 블록보다 앞서야 한다.
- **AUD-15** ½은 CDJ처럼 바로 줄인다. 나가기는 이번 바퀴 끝에서 한다.

## 기록과 확인

- **AUD-16** 새로 알아낸 제약은 날짜와 함께 `docs/architecture.md` "덱 오디오" 절에 적는다. 예약 제약, 재생 퀀타이즈, 끄는 중 핫큐 규칙이 이미 거기 있다.
- **AUD-17** 순수 규칙은 `--quick`으로 확인한다.
- **AUD-18** 실제 소리는 스킬 `app-selftest`의 자가 테스트로 확인한다. 쓰는 인자는 아래와 같다.
  - `--loop-audio-selftest`
  - `--jump-audio-selftest`
  - `--flip-selftest`
  - `--metronome-selftest`
  - `--switch-selftest`는 곡 전환과 일시정지를 시험한다. 엔진 정지와 출력 변경 뒤에는 재생 위치와 새 미터 신호를 확인한다.
  - 템포 +8%의 출력 프레임 수와 키 고정 켬·끔의 음높이는 `DeckTempoRenderTests`에서 합성 램프 WAV를 오프라인 렌더해 확인한다.
- **AUD-19** 소리를 내는 실행은 [docs/ci.md의 실행 잠금](../../docs/ci.md#잠금과-동시-실행)을 따른다.

## 더 보기

- 규칙의 이유와 실험 기록: [`docs/architecture.md` "덱 오디오"](../../docs/architecture.md#덱-오디오-deckaudio)
- 덱 재생 경로 예외: [`docs/architecture.md` "경계 규칙"](../../docs/architecture.md#경계-규칙)
