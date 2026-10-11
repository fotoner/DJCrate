---
paths:
  - "Sources/DJCDomain/Usb/**"
  - "Sources/RekordboxKit/Usb/**"
  - "Sources/DJCApplication/Usb/**"
  - "Sources/DJCAdapters/Usb/**"
  - "Sources/DJCStorage/Usb/**"
  - "Sources/DJCrate/App/AppComposition+Usb.swift"
  - "Sources/DJCrate/Usb/**"
  - "Sources/djc/CLIComposition+Usb.swift"
  - "Sources/djc/Commands/UsbCommands.swift"
  - "Sources/djc/Lab/Usb*.swift"
  - "Tests/**/Usb*"
  - "Tests/**/Pdb*"
  - "Tests/**/OneLibrary*"
---

# USB 라이브러리 코드를 고칠 때

AGENTS.md "안전 불변식"의 USB 줄을 자세히 적은 규칙이다. 리뷰는 규칙을 ID로 가리킨다.

- **USB-1** 먼저 `docs/usb-internals.md`를 읽는다.

## 쓰는 길

- **USB-2** 로컬 rekordbox 라이브러리는 RekordboxKit 쓰기 입구로만 쓴다(`.claude/rules/rekordbox-write.md`). `Sources/RekordboxKit/**`에는 두 규칙이 함께 걸린다.
- **USB-3** USB 쓰기는 `UsbWriter.write` 한 곳으로만 한다.
- **USB-4** 두 쓰기를 섞지 않는다. USB 코드는 로컬 DB에 쓰지 않는다.
- **USB-5** 유스케이스(`Sources/DJCApplication/Usb/`)는 RekordboxKit을 import하지 않는다.
- **USB-6** USB 쓰기·회복·되돌리기는 엔진 포트(`UsbLibraryEngine.writer`)로 부른다.
- **USB-7** `UsbWriter`를 부르는 곳은 실제 구현 `Sources/DJCAdapters/Usb/UsbLibraryEngine+Writer.swift` 하나뿐이다. 이 파일은 쓰기 커버리지 그룹이다.
- **USB-8** 가드(`UsbWriteGuard`)와 Mac 쪽 폴더는 조립 지점이 세션에 넘긴다. 세션에 기본값을 두지 않는다.
- **USB-9** 조립 지점은 앱 `AppComposition+Usb.swift`와 CLI `CLIComposition+Usb.swift`다.
- **USB-10** 세션은 받은 가드와 폴더를 그대로 엔진 쓰기에 넘긴다.
- **USB-11** 앱 쓰기의 순서와 확인 창 문구는 유스케이스 `UsbWriteFlow`가 정한다. 확인은 `UserConfirmation` 포트로 받는다.
- **USB-12** 실물 볼륨 줄은 `UsbWriteFlow.volumeLines`가 만든다. 동기화 창의 순서는 `UsbSync`가 정한다.
- **USB-13** 앱 화면 쪽(`Sources/DJCrate/Usb/`)은 포트를 붙여 부르기만 한다.
- **USB-14** 쓰기 파일은 `Sources/RekordboxKit/Usb/Write/`에 둔다. 이 폴더는 쓰기 커버리지 80%를 지킨다.
- **USB-15** USB 세션은 받은 로컬 사본이 라이브 master.db면 열지 않는다.
- **USB-16** 라이브 판정은 RekordboxKit `UsbLiveDatabase.isLive`가 한다. 판정 근거는 realpath, 링크를 따라간 inode, 표준 경로다.
- **USB-17** 이 Mac의 실제 master.db는 늘 라이브다. 이 실행의 rekordbox 폴더(`DJC_REKORDBOX_DIR`) master.db도 늘 라이브다.
- **USB-18** 세션은 포트 `UsbDevice.isLiveDatabase`로 판정을 부른다. 실제 구현은 `UsbDevice.live`다.
- **USB-19** 더 거부할 목록 `extraLiveDatabases`는 덧붙이기만 한다.
- **USB-20** 사본·준비 폴더 지우기 같은 이 Mac의 일도 같은 포트로 받는다.
- **USB-21** 라이브 판정은 더 엄격한 쪽으로만 바꾼다.

## 실물 USB

- **USB-22** 실물 쓰기는 볼륨 정책(`UsbVolumePolicy`)과 `UsbPhysicalWriteGate`를 지날 때만 한다. 관문은 아래 셋을 모두 본다.
  1. 코드 관문 `UsbPhysicalWriteGate.buildEnabled`(비상 스위치)
  2. 쓰기마다의 사용자 동의
  3. 볼륨 UUID와 이름 확인
- **USB-23** 앱의 동의는 쓰기 확인 창이나 내보내기 시트의 쓰기 버튼이다. 이 창은 볼륨 이름·용량과 "실물 USB입니다"를 보인다.
- **USB-24** CLI의 동의는 `--allow-physical --confirm <볼륨 이름>`이다.
- **USB-25** 볼륨을 미리 등록하는 목록은 두지 않는다.
- **USB-26** 받는 볼륨은 바깥 저장장치의 FAT32·exFAT 볼륨뿐이다. 바깥 저장장치는 USB 메모리, 외장 SSD, SD 카드다.
- **USB-27** 파티션 방식은 MBR·GPT만 받는다.
- **USB-28** 아래 볼륨에는 쓰지 않는다.
  - 시동 볼륨, 내장 볼륨, 네트워크 볼륨
  - 읽기 전용 볼륨
  - APFS·HFS+ 볼륨(Time Machine 포함)
- **USB-29** rekordbox가 실행 중이면 쓰지 않는다.
- **USB-30** 실물 경로 시험은 가짜 볼륨 정보를 임시 폴더 루트에 주입해서 한다. `lab usb-image` 이미지로 해도 된다.
- **USB-31** 시험 프로세스는 관문이 열려도 임시 폴더 밖에 쓰지 않는다.
- **USB-32** 디스크 이미지 도구는 **장치 번호를 우리가 방금 붙인 attach 결과에서만** 받는다.
- **USB-33** 파티션·포맷 직전에 `hdiutil info`의 image-path가 그 이미지인지 다시 확인한다.
- **USB-34** 디스크 이미지 판정은 아래 셋이 모두 참일 때만 참이다. 모르면 실물로 본다.
  1. DiskArbitration `DADeviceModel == "Disk Image"`
  2. `hdiutil info`에 그 장치의 이미지가 있음
  3. 그 image-path가 일반 파일
- **USB-35** `DADeviceProtocol`은 "Virtual Interface"라 판정에 쓰지 않는다. BusProtocol "Disk Image"는 보조 조건일 뿐이다.
- **USB-36** 경로 비교는 `realpath(3)` 결과끼리만 한다(`UsbScratchRoots.realPath`).
- **USB-37** Foundation 경로 정규화(`resolvingSymlinksInPath`·`standardizedFileURL`)는 쓰지 않는다. 이 정규화는 `/private`를 떼어 경로가 어긋난다.
- **USB-38** lab 명령이 받는 아래 경로는 `UsbScratchPath.check`를 거친다. 이 함수는 임시 폴더 아래만 받는다.
  - 이미지
  - 마운트 지점
  - USB 폴더
  - 출력 폴더

## 규칙을 더할 때

- **USB-39** 골든 대조는 lab 명령에서만, 사본으로 한다. 시험은 합성 자료만 쓴다.
- **USB-40** 확인 안 된 규칙은 `UsbProvisionalRule`에 등록해 계획에 싣는다.
- **USB-41** 확인 안 된 규칙 가운데 늘 막는 규칙(`alwaysBlocks`)만 막는다. 그 밖의 확인 안 된 규칙은 막지 않는다.
- **USB-42** 확인 안 된 곡 내용 규칙은 미리 보기와 확인 창에 알린다(`needsDeviceCheck`). 문구는 "CDJ에서 확인하지 않은 항목"이다.
- **USB-43** `confirmed`에는 rekordbox 실험 → 사본 재현 → 칸 단위 일치 → 골든 시험을 거친 규칙만 넣는다.
- **USB-44** 모르는 칸·고정 표를 "골든 바이트 상수"로 채우지 않는다. 칸 단위 규칙이 우선한다.
- **USB-45** 관찰한 칸 하나의 고정값만 이름 붙은 상수로 둔다. 그 상수에 근거 주석을 단다.
- **USB-46** 새 칸을 쓰면 검증 쪽(다시 읽기 비교)도 함께 고친다.

## 바꾼 뒤 확인

- **USB-47** `scripts/check.sh --changed`를 돌린다.
- **USB-48** 쓰기 전 과정은 디스크 이미지로 확인한다(스킬 `usb-image-check`).
- **USB-49** 앱 흐름은 `--usb-selftest`로 확인한다(스킬 `app-selftest`).

## 더 보기

- USB 형식과 쓰기 규칙: [`docs/usb-internals.md`](../../docs/usb-internals.md)
- 실물 USB 쓰기 조건: [`docs/usb-internals.md` §12](../../docs/usb-internals.md#12-실물-usb-쓰기)
