@testable import DJCrate
import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// #256 USB 목록 칸 캡처용 합성 로컬 라이브러리. 실데이터는 쓰지 않는다.
/// `UsbSelfTestLibrary`(곡 셋·재생 목록 하나·합성 아트워크·분석 파일)에 곡마다 다른 평점·곡 색을 더하고,
/// 분석 파일의 미리 보기 파형(PWAV·PWV4)을 그려지는 합성 파형으로 바꾼다.
/// `DJC_USB_COLUMNS_FIXTURE=<임시 폴더>`의 `local`에 만든다. 그 사본을 디스크 이미지에 `djc usb-export`로 내보낸 뒤
/// `--column-header-capture`로 컬렉션·USB 목록을 찍는다(스킬 `app-selftest` captures.md).
struct UsbColumnsFixtureCapture {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_USB_COLUMNS_FIXTURE"] != nil))
    func fixture() throws {
        let root = URL(filePath: try UsbScratchPath.check(ProcessInfo.processInfo.environment["DJC_USB_COLUMNS_FIXTURE"] ?? "",
                                                          as: .existingDirectory))
        let fixture = try RekordboxFixture()
        let made = try UsbSelfTestLibrary.make(in: root.appending(path: "local"), schemaFrom: fixture.database)
        let db = try CipherDatabase(path: made.database.path, key: .hex(try RekordboxKey.derive()), mode: .readWrite)
        defer { db.close() }
        // 평점 5·4·3, 곡 색 Aqua·Red·Purple(rekordbox 색 번호)
        for (index, id) in made.trackIDs.enumerated() {
            _ = try db.run("UPDATE djmdContent SET Rating = ?, ColorID = ? WHERE ID = ?",
                           [.int(5 - index), .text(["6", "2", "8"][index % 3]), .text(id)])
        }
        for (index, number) in (1...made.trackIDs.count).enumerated() {
            let dat = made.share.appending(path: "PIONEER/USBANLZ/s\(number)/t\(number)/ANLZ0000.DAT")
            let path = "?/djc-selftest-\(number).mp3"
            try Self.dat(path: path, phase: Double(index)).write(to: dat)
            try Self.ext(path: path, phase: Double(index)).write(to: dat.deletingPathExtension().appendingPathExtension("EXT"))
        }
        print("USB 목록 칸 캡처 합성 재료: 곡 \(made.trackIDs.count) · 재생 목록 1 · 앨범아트·미리 보기 파형·평점·곡 색")
    }

    /// 0…1 크기(곡마다 모양이 조금 다르다)
    static func level(_ t: Double, phase: Double) -> Double {
        0.25 + 0.75 * abs(sin(t * .pi * (5 + phase) + phase)) * (0.6 + 0.4 * abs(sin(t * .pi * 37)))
    }

    /// `.DAT`: `UsbSelfTestAnlz.dat`와 같은 태그에 그려지는 PWAV(400칸, 높이 하위 5비트)
    static func dat(path: String, phase: Double) -> Data {
        let pwav = (0..<400).map { UInt8(6 << 5) | UInt8(31 * level(Double($0) / 400, phase: phase)) }
        return UsbSelfTestAnlz.file([UsbSelfTestAnlz.ppth(path), UsbSelfTestAnlz.opaque("PVBR", bytes: 1_608),
                                     BeatGridTags.pqtz(UsbSelfTestAnlz.beats), AnlzBuilder.pwav(pwav), UsbSelfTestAnlz.opaque("PWV2", bytes: 108),
                                     UsbSelfTestAnlz.emptyPCOB(kind: 1), UsbSelfTestAnlz.emptyPCOB(kind: 0)])
    }

    /// `.EXT`: `UsbSelfTestAnlz.ext`와 같은 태그에 그려지는 PWV4(1200칸 × 6바이트: ·, 밝기 배율, 세기, 저·중·고음)
    static func ext(path: String, phase: Double) -> Data {
        let pwv4 = (0..<1_200).flatMap { index -> [UInt8] in
            let value = level(Double(index) / 1_200, phase: phase)
            return [0, 255, UInt8(127 * value), UInt8(120 * value), UInt8(80 * value), UInt8(45 * value)]
        }
        return UsbSelfTestAnlz.file([UsbSelfTestAnlz.ppth(path), UsbSelfTestAnlz.opaque("PWV3", bytes: 3_000),
                                     UsbSelfTestAnlz.emptyPCOB(kind: 1), UsbSelfTestAnlz.emptyPCOB(kind: 0),
                                     UsbSelfTestAnlz.emptyPCO2(kind: 1), UsbSelfTestAnlz.emptyPCO2(kind: 0),
                                     BeatGridTags.pqt2(UsbSelfTestAnlz.beats, unknown: 0x1234), UsbSelfTestAnlz.opaque("PWV5", bytes: 600),
                                     AnlzBuilder.waveform("PWV4", entryBytes: 6, samples: pwv4), UsbSelfTestAnlz.pssi()])
    }
}
