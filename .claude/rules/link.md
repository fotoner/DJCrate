---
paths:
  - "Sources/DJCLink/**"
  - "Sources/DJCDomain/Link/**"
  - "Sources/DJCApplication/Link/**"
  - "Sources/DJCAdapters/Link/**"
  - "Sources/DJCrate/Link/**"
  - "Tests/DJCLinkTests/**"
---

# Pro DJ Link(LINK)를 고칠 때

CDJ·DJM 네트워크 코드를 고칠 때 지키는 규칙이다. 리뷰는 규칙을 ID로 가리킨다.

## 네트워크

- **LNK-1** 장치 찾기는 알림 포트(UDP 50000)를 받기만 한다. 아무 패킷도 보내지 않는다(#272).
- **LNK-2** 알림·상태·서버(Link Export)를 보내는 일은 사용자가 LINK 단추를 눌러 막대를 펼쳤을 때만 한다(#273). 접으면 서버를 내린다.
- **LNK-3** rekordbox·rekordboxAgent가 켜져 있으면 포트를 열지 않는다. 같은 포트(UDP 50000~50002 등)를 쓴다.
- **LNK-4** 시험과 에이전트는 실제 네트워크에 Pro DJ Link 패킷을 보내지 않는다. 공연·리허설 중인 네트워크에서는 듣지도 않는다.
- **LNK-5** 시험은 소켓을 열지 않는다. 가짜 포트를 쓴다. DJLinkKit `LiveSocketFactory`는 시험 프로세스에서 소켓을 만들지 않는다.
- **LNK-6** 화면 시험·자가 테스트·측정 실행의 조립은 장치 찾기를 붙이지 않는다(`AppComposition.link`가 nil). LINK 캡처(`--link-capture=`)만 포트 없는 가상 장치를 화면 모델에 넣는다(`LinkCapture`).

## 내어 주기

- **LNK-10** 내어 주는 라이브러리는 저장소가 읽은 rekordbox 컬렉션이다. 이 Mac에 파일이 없는 곡은 내어 주지 않는다(`LinkLibrary.isShareable`).
  - 서버는 승인한 일반 파일의 열린 디스크립터에서 세션 사본을 만든다. 음원은 사본의 파일 번호로만 등록한다. 코덱 확인과 WAV 변환도 그 사본을 읽는다. 복제와 볼륨 간 복사는 같은 디스크립터를 쓴다. 빠진 곡의 번호는 다른 곡에 다시 매기지 않는다.
  - 추가 대기 곡은 내어 주지 않는다. rekordbox 분석 파일과 곡 ID는 rekordbox에 쓰기 때 생긴다.
  - 재생 목록은 재생 목록 초안을 얹은 모양을 내어 준다(`playlistProjection`). 추가 대기 곡은 목록에서도 빠진다.
- **LNK-11** 음원·분석 파일은 읽기만 한다. Link Export의 NFS는 쓰기 요청을 거절한다. CDJ의 편집(`Source.edit`)은 큐 저장·삭제만 받는다(LNK-16). 태그·평점·그리드 편집은 받지 않는다.
- **LNK-14** [LINK의 WAV 변환](../../docs/architecture.md#link의-wav-변환)에 정한 기종·보류·캐시 규칙을 따른다.
- **LNK-15** CDJ가 실은 DJCrate 곡은 DJCrate 덱에서 내린다. CDJ에 실려 있는 곡은 재생 중이 아니어도 덱에 올리지 않는다(`DeckModel.applyCDJTracks`).
- **LNK-13** CDJ가 보낸 재생 기록(`add_to_history`)은 DJCrate에 "LINK HISTORY yyyy-MM-dd" 보존본으로만 남긴다(`LinkHistory`). LINK 동안 rekordbox 라이브러리에 쓰지 않는다. rekordbox에는 USB 기록과 같은 쓰기 대기로 올려 rekordbox에 쓰기 때 넣는다.
- **LNK-16** CDJ의 큐 저장·삭제(#280)는 내어 주는 큐 목록을 바꿔 답한다. 거절하면 서버가 빈 목록으로 답해 CDJ의 메모리 큐가 사라진다. 받은 편집은 그 곡의 큐 초안에만 얹는다(`LinkCueDrafts`). LINK 동안 rekordbox 라이브러리에 쓰지 않는다. 큐 초안이 있는 곡은 연결할 때 초안의 큐를 내어 준다.
  - 메모리 루프는 시작 ±30ms에서 끝의 정확한 밀리초를 먼저 비교한다. 구형 CDJ의 프레임 환산값은 후보가 하나일 때만 적용한다. 서버 응답과 초안이 같은 규칙을 쓴다.
- **LNK-17** 연결한 뒤 DJCrate에서 큐 초안이 바뀌면 그 곡의 큐만 서버에 보낸다(#281, `LinkBarModel.updateCues`). 재생 목록 초안이 바뀌면 재생 목록만 보낸다(`LinkBarModel.updatePlaylists`). 곡 정보(제목·태그 등)와 그리드는 보내지 않는다. 곡 정보는 CDJ가 목록을 다시 읽어야 보여 LINK를 다시 켤 때 반영한다.
- **LNK-18** CDJ가 보낸 큐 편집은 `LinkCueDrafts`가 초안 출처 LINK로 저장한다. 조립이 정한 출처와 상관없다. 구현은 `EditDraftFiles.with(origin: .link)`다. 사람 편집이 아니라서 앱은 자동으로 쓰지 않는다. 제안으로 남는다. ⌘S·저장 단추로 저장할 때 함께 쓴다.
- **LNK-12** 실기 확인은 시험용 네트워크에서 사용자가 한다. 에이전트는 LINK 단추를 누르지 않는다.

## 경계

- **LNK-7** DJLinkKit 패키지 타깃은 `DJCLink`만 import한다. 공개 API에 DJLinkKit 타입을 내지 않는다(`internal import`).
  - 패키지를 올릴 때 `scripts/check-imports.py`의 `DJLINK_MODULES`를 새 매니페스트와 맞춘다.
  - `LinkExportServer.swift`의 내부 타깃 import 세 개도 확인한다. `DJLinkExportDBServer`·`DJLinkExportModel`·`DJLinkExportProtocol`이다.
- **LNK-8** 앱·핵심부는 `DJCDomain.LinkDevice`만 쓴다. `DJCLink.LinkDevice`는 어댑터(`DJCAdapters/Link`)에서 바꾼다.

- DJLinkKit 0.1.6의 파일 범위 제한과 송신 장치 확인은 별개다. dbserver 큐·재생 기록의 송신자와 UDP 장치 알림 주소의 대조는 외부 의존성에서 확인할 사항이다(#282).

## 시험 재료

- **LNK-9** 패킷 재료는 실기 캡처 바이트에서 MAC을 가려 쓴다. IP는 링크 로컬 주소만 둔다. 장비 일련번호·개인 정보는 넣지 않는다.
