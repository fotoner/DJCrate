import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import Testing

/// USB 큐·그리드 가져오기의 읽기 계획(`UsbCueGridImportPlan.read`, 가짜 포트). 사본을 떠서 곡마다 만들 초안과 건너뛸 이유를 정한다
@Suite("USB 큐·그리드 가져오기 읽기")
struct UsbCueGridImportReadTests {
    static let scratch = URL(filePath: "/private/tmp/djc-fixture/usb-snapshots/import-1")
    static let snapshot = URL(filePath: "/private/tmp/djc-fixture/master-copy.db")
    static let dat = "/PIONEER/USBANLZ/P001/0001/ANLZ0000.DAT"

    /// 로컬 곡 101(MasterSongID 11, 파일 a.mp3)과 짝이 맞는 USB 곡 1, 짝이 없는 USB 곡 2
    static func library() -> UsbLibrary {
        var library = UsbLibrary(formats: UsbFormat.defaultSet, property: UsbProperty(dbVersion: "1000"))
        library.tracks = [
            UsbTrack(id: 1, presentIn: UsbFormat.defaultSet, lengthSeconds: 180, path: "/Contents/a.mp3", fileName: "a.mp3",
                     masterDbId: 1, masterContentId: 11, analysisDataPath: dat),
            UsbTrack(id: 2, presentIn: UsbFormat.defaultSet, path: "/Contents/b.mp3", fileName: "b.mp3", masterDbId: 1, masterContentId: 99),
        ]
        return library
    }

    static let keys = LocalLibraryKeys(localDBID: 1, tracks: [UsbLocalTrackKey(contentID: "101", masterSongID: "11", fileNameL: "a.mp3",
                                                                                folderPath: "/music/a.mp3")], counters: [:])

    static func rows(streaming: Bool = false) -> [String: UsbCueGridImportTrack] {
        let track = Track(id: "101", uuid: "uuid-101", title: "합성 곡", artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil,
                          releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180,
                          folderPath: streaming ? "soundcloud:tracks:1" : "/music/a.mp3", comment: "", importedOn: nil,
                          analysisDataPath: "/PIONEER/USBANLZ/P001/0001/ANLZ0000.DAT", imagePath: nil, isDeleted: false)
        return ["101": UsbCueGridImportTrack(track: track, cues: [])]
    }

    static let grid = BeatGrid(beats: [.init(number: 1, bpm: 120, time: 0.5), .init(number: 2, bpm: 120, time: 1.0)])

    func ports(_ configure: (inout FakeUsbPorts.State) -> Void = { _ in }) -> FakeUsbPorts {
        FakeUsbPorts {
            $0.oneLibrary = .success(Self.library())
            $0.databaseCopy = .success(FakeUsbPorts.copy(pdb: false))
            $0.localKeys = Self.keys
            $0.trackReads = [1: .success(UsbCueGridRead(cues: [EditableCue(kind: .hot(0), time: 2)], grid: Self.grid,
                                                       usesLegacyCues: false, cueIssue: nil, gridIssue: nil))]
            configure(&$0)
        }
    }

    func read(_ ports: FakeUsbPorts, rows: [String: UsbCueGridImportTrack] = Self.rows(),
              currentVolume: @escaping (UsbVolumeInfo) throws -> UsbVolumeInfo = { $0 }) throws -> UsbCueGridImportPlan {
        try UsbCueGridImportPlan.read(volume: FakeUsbVolume.diskImageFAT32(), snapshot: Self.snapshot, share: FakeUsbPorts.share,
                                      scratch: Self.scratch, rows: rows, engine: ports.engine, device: ports.device, currentVolume: currentVolume)
    }

    @Test("읽기 전후로 그 자리 볼륨을 다시 보고, 짝이 하나로 맞는 곡만 계획하며, 사본 폴더는 끝나면 지운다")
    func plansMatchedTrackAndRechecksVolume() throws {
        let ports = ports()
        var rechecks = 0
        let plan = try read(ports) { volume in
            rechecks += 1
            return volume
        }
        #expect(rechecks == 2)
        #expect(plan.unmatchedCount == 1)
        let row = try #require(plan.rows.first)
        #expect(row.row.track.id == "101" && row.cues?.hasChanges == true)
        // 로컬 분석 파일이 없으면 그리드는 건너뛴다(이유를 남긴다)
        #expect(row.grid == nil && row.reasons.count == 1)
        #expect(ports.current.removed == [Self.scratch])
    }

    @Test("로컬 분석 파일이 스냅샷 뒤에 바뀌지 않았으면 그리드 초안을 만들고, 바뀌었으면 그리드만 건너뛴다")
    func gridNeedsUnchangedLocalAnalysis() throws {
        let dat = FakeUsbPorts.share.appending(path: String(Self.dat.dropFirst()))
        let ext = dat.deletingPathExtension().appendingPathExtension("EXT")
        let old = UsbLocalFileStamp(size: 10, modificationDate: FakeUsbPorts.snapshotDate.addingTimeInterval(-60), isRegularFile: true)
        let ports = ports {
            $0.existing = [dat, ext]
            $0.stamps = [dat: old, ext: old]
            $0.localGrid = Self.grid
        }
        let plan = try read(ports)
        #expect(plan.rows.first?.grid != nil && plan.rows.first?.reasons == [])

        let newer = UsbLocalFileStamp(size: 10, modificationDate: FakeUsbPorts.snapshotDate.addingTimeInterval(60), isRegularFile: true)
        ports.update { $0.stamps[dat] = newer }
        let changed = try read(ports)
        #expect(changed.rows.first?.grid == nil && changed.rows.first?.cues != nil)
        #expect(changed.rows.first?.reasons == [String(ui: "로컬 분석 파일이 스냅샷 뒤에 바뀌었으니 새 스냅샷을 뜬 뒤 그리드를 가져오세요.")])
    }

    @Test("OneLibrary 기기 큐 행이 있는 곡은 큐를 가져오지 않는다")
    func deviceCueRowsSkipCues() throws {
        let ports = ports { $0.deviceCueContentIDs = [1] }
        let plan = try read(ports)
        #expect(plan.rows.first?.cues == nil)
        #expect(plan.rows.first?.reasons.first == String(ui: "OneLibrary 기기 큐 행의 해석을 확인하지 못했으니 큐는 rekordbox에서 직접 가져오세요."))
    }

    @Test("스트리밍 곡은 짝이 맞아도 가져오지 않는다")
    func streamingTrackSkipped() throws {
        let plan = try read(ports(), rows: Self.rows(streaming: true))
        #expect(plan.rows.isEmpty && plan.unmatchedCount == 2)
    }

    @Test("Device Library 구조 문제, 읽는 동안 USB DB가 바뀐 것은 계획 전체를 멈춘다")
    func structureAndConcurrentChangeStop() {
        let broken = ports {
            $0.databaseCopy = .success(FakeUsbPorts.copy())
            $0.deviceLibrary = .success(FakeUsbPorts.deviceLibrary(Self.library(), issues: ["page 3"]))
        }
        #expect(throws: UsbCueGridReadFailure.self) { _ = try read(broken) }
        #expect(!broken.calls.contains("localKeys"))
        let moved = ports { $0.databasesUnchanged = false }
        #expect(throws: UsbCueGridReadFailure(message: String(ui: "읽는 동안 USB 라이브러리가 바뀌었으니 기기 사용을 마친 뒤 다시 가져오세요."))) {
            _ = try read(moved)
        }
        // 멈춰도 사본 폴더는 지운다
        for ports in [broken, moved] { #expect(ports.current.removed == [Self.scratch]) }
    }
}
