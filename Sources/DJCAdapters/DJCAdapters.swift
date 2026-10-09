// 피동 어댑터: DJCApplication이 정의한 포트의 실제 구현(.live)을 한 벌로 모은다(#167 헥사고날 구조).
// 인프라(RekordboxKit·DJCStorage·DJCAnalysis·DJCEnvironment)를 부르기만 하고, 쓰기 관문(RekordboxWriter·RekordboxTrackWriter·UsbWriter)의
// 위치·동작은 그대로 둔다. 기능별 폴더(Library·Deck·Edit·Reflection·Usb)는 첫 어댑터가 들어올 때 만든다.
