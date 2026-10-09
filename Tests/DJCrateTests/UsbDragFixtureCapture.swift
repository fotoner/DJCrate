@testable import DJCrate
import RekordboxFixtures
import Foundation
import Testing

/// #240 USB 끌어 놓기 화면 확인용 합성 라이브러리: 합성 곡 여덟('끌기 시험 N', 곡마다 다른 합성 음원·`--usb-selftest`와 같은 합성 분석 파일),
/// 재생 목록 '목록 가'(곡 1–4)·'목록 나'(곡 5–6)·'빈 목록'. 실데이터는 쓰지 않는다.
/// `DJC_USB_DRAG_FIXTURE=<없는 폴더> swift test --filter UsbDragFixtureCapture` → `DJC_REKORDBOX_DIR=<폴더>`로 앱을 띄우고,
/// '목록 가'·'목록 나'는 `djc usb-export --playlist 2401 --playlist 2402`로 합성 디스크 이미지에 내보낸다.
struct UsbDragFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_USB_DRAG_FIXTURE"] != nil))
    func fixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_USB_DRAG_FIXTURE"] else { return }
        let fixture = try RekordboxFixture()
        let root = URL(filePath: path)
        for index in 1...8 {
            let fileName = "drag-\(index).mp3"
            let bytes = Data((0..<(48_000 + 1_000 * index)).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ index) })
            try bytes.write(to: fixture.audio.appending(path: fileName))
            var track = TrackSpec(id: String(index))
            track.title = "끌기 시험 \(index)"
            track.folderPath = root.appending(path: "audio/\(fileName)").path
            track.analysisDataPath = "/PIONEER/USBANLZ/drag\(index)/ANLZ0000.DAT"
            try fixture.add(track)
            try fixture.setIdentity(track: track, masterSongID: "90\(index)", masterDBID: RekordboxFixture.masterDBID, fileNameL: fileName)
            try fixture.setFileSize(track: track, Int64(bytes.count))
            try fixture.writeLocalAnalysis(analysisPath: track.analysisDataPath ?? "", dat: UsbSelfTestAnlz.dat(path: "?/" + fileName),
                                           ext: UsbSelfTestAnlz.ext(path: "?/" + fileName), twoEx: UsbSelfTestAnlz.twoEx(path: "?/" + fileName))
        }
        try fixture.add(playlists: [
            PlaylistSpec(id: "2401", name: "목록 가", seq: 1, contentIDs: ["1", "2", "3", "4"]),
            PlaylistSpec(id: "2402", name: "목록 나", seq: 2, contentIDs: ["5", "6"]),
            PlaylistSpec(id: "2403", name: "빈 목록", seq: 3),
        ])
        try FileManager.default.copyItem(at: fixture.root, to: root)
    }
}
