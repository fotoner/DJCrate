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
  - 추가 대기 곡은 내어 주지 않는다. rekordbox 분석 파일과 곡 ID는 rekordbox에 쓰기 때 생긴다.
  - 재생 목록은 재생 목록 초안을 얹은 모양을 내어 준다(`playlistProjection`). 추가 대기 곡은 목록에서도 빠진다.
- **LNK-11** 음원·분석 파일은 읽기만 한다. Link Export의 NFS는 쓰기 요청을 거절한다. CDJ의 편집(`Source.edit`)은 큐 저장·삭제만 받는다(LNK-16). 태그·평점·그리드 편집은 받지 않는다.
- **LNK-14** FLAC·ALAC을 못 읽는 기종(`LinkPlayerFormats`)에 실을 때만 WAV로 바꾼다(`LinkAudioConverter`). 바꾸는 때는 아래 둘이다.
  - DJCrate에서 끌어 놓아 실을 때: 바꾼 뒤 싣는다.
  - CDJ에서 고를 때: 플레이어가 NFS로 원본을 찾으면 백그라운드에서 바꿔 끼운다(`LinkSession.fileRequested`).
  - 바꾸는 동안 그 요청에 답하지 않는다(`LinkFileHold`). CDJ가 1초쯤 뒤 다시 묻는 요청에 WAV로 답해 첫 싣기부터 실린다. 원본으로 답해 E-8305로 실패시키지 않는다.
  - 15초(`LinkFileHold.limit`) 안에 못 바꾸면 원본으로 답한다. 그 싣기는 실패하므로 다 바꾼 뒤 다시 실으라고 알린다. 바꿀 필요가 없는 곡은 곧바로 원본으로 답한다. 바꾸지 못한 곡도 그렇다.
  - 바꾸지 못한 원본은 그 연결에서 기억한다(#287). CDJ가 다시 찾아도 다시 바꾸지 않는다. 알림도 다시 띄우지 않는다. 끌어 놓으면 다시 바꿔 본다.
  - 같은 원본을 바꿔 끼우는 일은 연결마다 하나다(`LinkSession.prepare`). 끌어 놓기·CDJ 요청이 그 일을 함께 기다린다. 그래서 바꿔 끼운 뒤에 싣는다(#287).
  - 보류 풀기와 바꿔 끼우기는 그 변환을 시작한 연결 차례가 지금 차례일 때만 한다(#287). 앞 연결의 변환이 새 연결의 보류를 풀지 않는다.
  - 바꿔 끼울 때는 곡 정보의 경로와 NFS의 원본 이름을 함께 WAV로 바꾼다(`redirect_file`). CDJ는 곡 번호별로 처음 받은 경로를 기억해 원본 이름으로 다시 찾기 때문이다(2026-10-17 CDJ-2000nexus 실기). 이미 연 핸들은 원본을 이어 읽는다.
  - NFS는 서버를 띄울 때 곡 경로 앞 세 단계 폴더만 연다(`LinkExportServer.exportRoots`). 음악 폴더 밖 곡만 내어 주면 WAV가 그 밖에 놓일 수 있다. 그때는 곡 정보의 경로를 원본 그대로 둔다. 형식만 WAV로 바꾼다. 서버가 원본 이름으로 WAV를 내어 준다(#287). 2026-10-20 CDJ-2000nexus 실기로 확인했다.
  - 바꾼 파일은 `DJCCachePaths.linkAudio`에만 쓴다. 자리는 `~/Music/DJCrate/LINK`다. `DJC_HOME`이 있으면 그 안 `link-audio/`다. 원본은 읽기만 한다. 시험은 임시 폴더에서만 바꾼다.
  - 바꾼 파일은 캐시 종류 `link-audio`다(#287). 저장 공간 설정·`djc cache`가 용량을 보인다. 비우기도 거기서 한다. LINK로 내어 주는 동안 앱 화면은 이 종류를 비우지 않는다. 비우는 사이 LINK를 켜면 다 비운 뒤에 내어 준다(`LinkBarModel.beginCacheClear`).
- **LNK-15** CDJ가 실은 DJCrate 곡은 DJCrate 덱에서 내린다. CDJ에 실려 있는 곡은 재생 중이 아니어도 덱에 올리지 않는다(`DeckModel.applyCDJTracks`).
- **LNK-13** CDJ가 보낸 재생 기록(`add_to_history`)은 DJCrate에 "LINK HISTORY yyyy-MM-dd" 보존본으로만 남긴다(`LinkHistory`). LINK 동안 rekordbox 라이브러리에 쓰지 않는다. rekordbox에는 USB 기록과 같은 쓰기 대기로 올려 rekordbox에 쓰기 때 넣는다.
- **LNK-16** CDJ의 큐 저장·삭제(#280)는 내어 주는 큐 목록을 바꿔 답한다. 거절하면 서버가 빈 목록으로 답해 CDJ의 메모리 큐가 사라진다. 받은 편집은 그 곡의 큐 초안에만 얹는다(`LinkCueDrafts`). LINK 동안 rekordbox 라이브러리에 쓰지 않는다. 큐 초안이 있는 곡은 연결할 때 초안의 큐를 내어 준다.
- **LNK-17** 연결한 뒤 DJCrate에서 큐 초안이 바뀌면 그 곡의 큐만 서버에 보낸다(#281, `LinkBarModel.updateCues`). 재생 목록 초안이 바뀌면 재생 목록만 보낸다(`LinkBarModel.updatePlaylists`). 곡 정보(제목·태그 등)와 그리드는 보내지 않는다. 곡 정보는 CDJ가 목록을 다시 읽어야 보여 LINK를 다시 켤 때 반영한다.
- **LNK-12** 실기 확인은 시험용 네트워크에서 사용자가 한다. 에이전트는 LINK 단추를 누르지 않는다.

## 경계

- **LNK-7** DJLinkKit 제품은 `DJCLink`만 import한다. 공개 API에 DJLinkKit 타입을 내지 않는다(`internal import`).
- **LNK-8** 앱·핵심부는 `DJCDomain.LinkDevice`만 쓴다. `DJCLink.LinkDevice`는 어댑터(`DJCAdapters/Link`)에서 바꾼다.

## 시험 재료

- **LNK-9** 패킷 재료는 실기 캡처 바이트에서 MAC을 가려 쓴다. IP는 링크 로컬 주소만 둔다. 장비 일련번호·개인 정보는 넣지 않는다.
