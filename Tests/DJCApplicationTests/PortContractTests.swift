import DJCApplication
import DJCDomain
import DJCTestKit
import Foundation
import PortTestKit
import Testing

/// 유스케이스 시험이 쓰는 가짜(메모리 구현)가 포트 계약을 지키는지. 같은 계약 함수(PortTestKit)를 DJCAdaptersTests가 실제 구현에 돌린다.
@MainActor
@Suite("포트 계약 — 가짜")
struct PortContractTests {
    // MARK: - 반영

    @Test func 백업_폴더() throws {
        try backupsContract(MemoryBackups().port, folder: URL(filePath: "/backups"))
        let failing = MemoryBackups()
        failing.failing = ["staged", "cue"]
        backupsSaveFailureContract(failing.port, backup: URL(filePath: "/backups").appending(path: backupContractName))
    }

    @Test func 쓰기_관문() async throws {
        try await writeGateContract(.scripted(GateScript()), target: .copy(database: URL(filePath: "/copy/master.db"), shareRoot: nil),
                                    batch: DraftWriteBatch())
    }

    @Test func 반영_묶음_저장() throws { try reflectionBatchStoreContract(MemoryReflectionBatches().port) }

    @Test func 시점_스냅샷() throws {
        try pointSnapshotFilesContract(MemoryPointSnapshotFiles().port, database: URL(filePath: "/copy/master.db"), shareRoot: nil,
                                       directory: URL(filePath: "/points"), now: Date(timeIntervalSince1970: 1_790_337_600))
    }

    // MARK: - 라이브러리

    @Test func 초안_저장소() throws { try draftStoreContract(MemoryDrafts().store) }

    @Test func 추가_목록() throws { try stagingStoreContract(MemoryStaging().store) }

    @Test func USB_재생_기록_보존_파일() throws { try usbHistoryFilesContract(MemoryUsbHistoryFiles().files) }

    @Test func 초안_파일() throws { try draftFilesContract(MemoryDraftFiles().files) }

    @Test func 연결_기록_없음() throws { try playlistImportsContract(.none, remembers: false) }

    @Test func 라이브러리_읽기() throws {
        let tracks = ["1", "2"].map { id in
            Track(id: id, uuid: "u\(id)", title: "곡 \(id)", artist: nil, album: nil, albumArtist: nil, genre: nil, composer: nil, releaseYear: nil,
                  trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180, folderPath: "/music/\(id).mp3", comment: "", importedOn: nil,
                  analysisDataPath: nil, imagePath: nil, isDeleted: false)
        }
        let library = RekordboxLibrary(allTracks: tracks, cues: [], playCounts: [:])
        let folder = URL(filePath: "/memory/snapshots")
        let older = folder.appending(path: "master-2026-01-01T000000.db"), newest = folder.appending(path: "master-2026-01-02T000000.db")
        try librarySourceContract(.memory([older: library, newest: library], latest: newest), directory: folder, newest: newest, ids: ["1", "2"])
    }

    @Test func Music_목록_사본() throws {
        try musicLibrarySourceContract(MemoryMusicLibrary().source, database: URL(filePath: "/memory/master-1.db"),
                                       directory: URL(filePath: "/memory/rekordbox"))
    }

    @Test func XML_파일() throws {
        let xml = MemoryXMLFiles(), folder = URL(filePath: "/memory/xml")
        xml.addFolder(folder)
        try xmlFilesContract(xml.files, folder: folder)
    }

    // MARK: - 덱

    @Test func 분석_캐시() throws {
        let folder = try TemporaryFolder(prefix: "djc-analysis-store")
        analysisStoreContract(MemoryAnalysisStore().store, first: try AudioFixture.wav(seconds: 1, in: folder.url, name: "a.wav"),
                              second: try AudioFixture.wav(seconds: 2, in: folder.url, name: "b.wav"))
    }

    @Test func 덱_읽기() {
        let gridPath = "/PIONEER/USBANLZ/grid/ANLZ0000.DAT", halfPath = "/PIONEER/USBANLZ/half/ANLZ0000.DAT"
        let times = (0..<8).map { 0.5 + Double($0) * 0.5 }
        let grid = BeatGrid(beats: times.enumerated().map { BeatGrid.Beat(number: $0.offset % 4 + 1, bpm: 120, time: $0.element) })
        let audio = URL(filePath: "/music/a.wav")
        let assets = MemoryTrackAssets(audio: [audio.path: 0], analysis: [gridPath: .init(grid: .grid(grid)),
                                                                          halfPath: .init(grid: .grid(grid), hasWaveform: false)])
        trackAssetReaderContract(assets.reader(drafts: MemoryDrafts().store),
                                 TrackAssetContractFiles(share: URL(filePath: "/share"), gridPath: gridPath, halfPath: halfPath, beatTimes: times,
                                                         audio: audio, missingAudio: URL(filePath: "/music/없음.wav")))
    }

    // MARK: - USB

    @Test func USB_초안_파일() throws { try usbDraftFilesContract(.memory(now: { Date(timeIntervalSince1970: 1_800_000_000) })) }

    @Test func USB_동기화_설정() throws { try usbSyncPreferencesContract(MemoryUsbSyncPreferences().files) }
}
