import DJCDomain
import Foundation
import Testing

/// USB 시점 스냅샷(#226)의 순수 규칙: 담는 범위, 보존 정리(볼륨마다 최근 5개 + 고정), 기기가 바꾼 USB 판정(D13과 같은 기준)
@Suite("USB 시점 스냅샷 규칙")
struct UsbPointSnapshotRulesTests {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func entry(_ index: Int, pinned: Bool = false) -> UsbPointSnapshotEntry {
        let metadata = UsbPointSnapshotMetadata(name: "", kind: .manual, createdAt: date.addingTimeInterval(Double(-index) * 60), pinned: pinned,
                                                volumeUUID: "UUID", volumeName: "DJCTEST", files: [:])
        return UsbPointSnapshotEntry(url: URL(filePath: "/tmp/usb-point-snapshots/UUID/s\(index)"), metadata: metadata)
    }

    static func fingerprint(_ files: [String: String]) -> UsbFingerprint {
        UsbFingerprint(files: files.mapValues { UsbFingerprint.Stamp(size: 1, mtime: date, sha256: $0) })
    }

    @Test("담는 범위: DB 셋·사이드카, 분석 파일·아트워크 폴더 아래, 설정 파일 넷. 음원·동기화 선택·열지 않는 곳·._·임시 파일은 아니다")
    func scope() {
        for path in [UsbLayout.oneLibrary, UsbLayout.oneLibrary + "-wal", UsbLayout.oneLibrary + "-shm", UsbLayout.oneLibrary + "-journal",
                     UsbLayout.exportPdb, UsbLayout.exportExtPdb, "PIONEER/USBANLZ/P001/0000ABCD/ANLZ0000.DAT",
                     "PIONEER/Artwork/00001/a1.jpg", "PIONEER/MYSETTING.DAT", "PIONEER/MYSETTING2.DAT", "PIONEER/DJMMYSETTING.DAT",
                     "PIONEER/DEVSETTING.DAT", "pioneer/usbanlz/p001/0000abcd/anlz0000.ext"] {
            #expect(UsbPointSnapshotRules.isInScope(path), "\(path)")
        }
        for path in ["Contents/a.mp3", "PIONEER/rekordbox/playlists3.sync", "PIONEER/rekordbox/ImportedHistory.xml",
                     "PIONEER/rekordbox/export.pdb.bak", "PIONEER/extracted/a", "PIONEER/CDP/a", "PIONEER/djprofile.nxs",
                     "PIONEER/USBANLZ/P001/._ANLZ0000.DAT", "PIONEER/Artwork/00001/.djc-part-abc-000001", "PIONEER/USBANLZ",
                     "PIONEER/USBANLZ/../extracted/a", "/PIONEER/MYSETTING.DAT", "PIONEER/USBANLZ//a", "PIONEER/OTHER.DAT", ""] {
            #expect(!UsbPointSnapshotRules.isInScope(path), "\(path)")
        }
    }

    @Test("보존: 최근 5개 밖의 고정하지 않은 스냅샷만 지운다(USB 백업 정리와 같은 수)")
    func retention() {
        let entries = (0..<8).map { Self.entry($0, pinned: $0 == 6) }
        #expect(UsbPointSnapshotRules.keep == 5)
        #expect(UsbPointSnapshotRules.expired(entries, keep: 5).map(\.id) == ["s5", "s7"])
        #expect(UsbPointSnapshotRules.expired(Array(entries.prefix(5)), keep: 5).isEmpty)
        // 순서가 섞여 들어와도 만든 시각(최근 것부터)으로 센다
        #expect(UsbPointSnapshotRules.expired(entries.reversed(), keep: 5).map(\.id) == ["s5", "s7"])
    }

    static func at(_ sha: String) -> [String: String] { [UsbLayout.exportPdb: sha] }

    static func write(_ id: String, at offset: Double, before: [String: String], after: [String: String], kind: UsbWriteEventKind = .carry,
                      outcome: UsbWriteReport.Outcome = .written) -> UsbVolumeEvent {
        .write(id: id, date: date.addingTimeInterval(offset), before: before, beforeSidecars: false, after: after, kind: kind, outcome: outcome)
    }

    /// 스냅샷 "s"(기본: export.pdb = "a")를 뜬 뒤의 사건과 지금 USB로 판정한다
    static func changed(_ events: [UsbVolumeEvent], current: [String: String],
                        files: [String: String] = [UsbLayout.exportPdb: "a"]) -> Bool {
        let metadata = UsbPointSnapshotMetadata(name: "", kind: .manual, createdAt: date, volumeUUID: "UUID", volumeName: "DJCTEST",
                                                files: files.mapValues { .init(size: 1, mtime: date, sha256: $0) })
        let snapshot = UsbPointSnapshotEntry(url: URL(filePath: "/tmp/usb-point-snapshots/UUID/s"), metadata: metadata)
        return UsbPointSnapshotRules.deviceChanged(since: snapshot, events: events, current: fingerprint(current))
    }

    @Test("기기 변경: 스냅샷 뒤 사건을 차례로 따라가 DJCrate가 모르는 변경이 지금 USB에 실려 있는지 본다(해시·사이드카는 D13 기준)")
    func deviceChanged() {
        // 사건 없음: 스냅샷 그대로면 아니고, 해시가 다르거나 OneLibrary 사이드카가 있으면 바뀜
        #expect(!Self.changed([], current: Self.at("a")))
        #expect(Self.changed([], current: Self.at("x")))
        #expect(Self.changed([], current: [UsbLayout.exportPdb: "a", UsbLayout.oneLibrary + "-journal": "j"]))
        // 스냅샷 상태에서 시작한 DJCrate 쓰기의 결과는 아는 상태다
        #expect(!Self.changed([Self.write("w1", at: 60, before: Self.at("a"), after: Self.at("b"))], current: Self.at("b")))
        // 기기가 바꾼 뒤 DJCrate가 수정했으면(수정은 기기 행을 잇는다) 지금이 그 쓰기 결과여도 바뀜
        #expect(Self.changed([Self.write("w1", at: 60, before: Self.at("x"), after: Self.at("c"))], current: Self.at("c")))
        // 바뀐 채 되돌려진 쓰기, 다시 계획으로 닫힌 쓰기도 바뀜
        #expect(Self.changed([Self.write("w1", at: 60, before: Self.at("x"), after: Self.at("x"), outcome: .rolledBack)], current: Self.at("x")))
        #expect(Self.changed([Self.write("w1", at: 60, before: Self.at("a"), after: Self.at("y"), outcome: .needsReplan)], current: Self.at("y")))
        // 이 스냅샷 그대로 되돌렸으면 그 앞의 기기 변경은 이미 버렸다. 그 되돌리기를 usb-restore로 되돌리면 다시 바뀜
        let exact = Self.write("w2", at: 120, before: Self.at("x"), after: Self.at("a"), kind: .exact(snapshot: "s"))
        #expect(!Self.changed([exact], current: Self.at("a")))
        #expect(!Self.changed([exact, Self.write("w3", at: 180, before: Self.at("a"), after: Self.at("d"))], current: Self.at("d")))
        #expect(Self.changed([exact, .restore(writeID: "w2", date: Self.date.addingTimeInterval(180), after: Self.at("x"))], current: Self.at("x")))
        // 다른 스냅샷으로 되돌린 시점 되돌리기는 같은 DB가 아니면 모른다고 본다
        #expect(Self.changed([Self.write("w2", at: 120, before: Self.at("a"), after: Self.at("o"), kind: .exact(snapshot: "t"))], current: Self.at("o")))
        #expect(!Self.changed([Self.write("w2", at: 120, before: Self.at("x"), after: Self.at("a"), kind: .exact(snapshot: "t"))], current: Self.at("a")))
        // 사이드카를 담은 스냅샷은 되돌리면 사본 안에서 합친 DB(해시가 다름)가 된다. 이 스냅샷으로 되돌린 쓰기면 그 결과는 아는 상태다
        let sidecarFiles = [UsbLayout.oneLibrary: "r", UsbLayout.oneLibrary + "-wal": "w"]
        let merged = [UsbLayout.oneLibrary: "m"]
        let restored = UsbVolumeEvent.write(id: "w5", date: Self.date.addingTimeInterval(60), before: [UsbLayout.oneLibrary: "x"], beforeSidecars: true,
                                            after: merged, kind: .exact(snapshot: "s"), outcome: .written)
        #expect(!Self.changed([restored], current: merged, files: sidecarFiles))
        #expect(Self.changed([], current: merged, files: sidecarFiles))
        // 빈 USB 내보내기의 결과에는 기기 행이 없다
        #expect(!Self.changed([Self.write("w4", at: 60, before: [:], after: Self.at("e"), kind: .fresh)], current: Self.at("e")))
        // 뒤의 스냅샷이 따라온 상태와 다르면 그 사이 바뀌었다
        #expect(Self.changed([.snapshot(date: Self.date.addingTimeInterval(60), databases: Self.at("x"), sidecars: false)], current: Self.at("x")))
        #expect(!Self.changed([.snapshot(date: Self.date.addingTimeInterval(60), databases: Self.at("a"), sidecars: false)], current: Self.at("a")))
        // 스냅샷 전의 사건은 보지 않는다(그 쓰기 결과로는 지금 상태를 설명하지 않는다)
        #expect(Self.changed([Self.write("old", at: -60, before: Self.at("a"), after: Self.at("z"))], current: Self.at("z")))
        // 지금이 스냅샷과 같으면 잃을 것이 없다
        #expect(!Self.changed([Self.write("w1", at: 60, before: Self.at("x"), after: Self.at("c"))], current: Self.at("a")))
    }

    @Test("스냅샷 정보: DB 해시·형식·사이드카·파일 수를 담은 파일에서 센다")
    func metadataSummary() {
        func stamp(_ size: Int64, _ sha: String) -> UsbFingerprint.Stamp { .init(size: size, mtime: Self.date, sha256: sha) }
        let files: [String: UsbFingerprint.Stamp] = [
            UsbLayout.oneLibrary: stamp(10, "a"), UsbLayout.oneLibrary + "-wal": stamp(3, "w"), UsbLayout.exportPdb: stamp(20, "b"),
            "PIONEER/USBANLZ/P001/0000ABCD/ANLZ0000.DAT": stamp(5, "d"), "PIONEER/Artwork/00001/a1.jpg": stamp(7, "i"),
            "PIONEER/MYSETTING.DAT": stamp(148, "s"),
        ]
        let metadata = UsbPointSnapshotMetadata(name: " 공연 전 ", kind: .manual, createdAt: Self.date, volumeUUID: "UUID", volumeName: "DJCTEST",
                                                files: files)
        #expect(metadata.databases == [UsbLayout.oneLibrary: "a", UsbLayout.exportPdb: "b"])
        #expect(metadata.formats == [.oneLibrary, .deviceLibrary])
        #expect(metadata.hasSidecars)
        #expect(metadata.analysisFiles == 1 && metadata.artworkFiles == 1 && metadata.settingFiles == 1)
        #expect(metadata.totalSize == 193)
        let entry = UsbPointSnapshotEntry(url: URL(filePath: "/tmp/x/2026-10-16T120000Z-manual"), metadata: metadata)
        #expect(entry.id == "2026-10-16T120000Z-manual" && entry.displayName == " 공연 전 ")
        var unnamed = metadata
        unnamed.name = ""
        #expect(UsbPointSnapshotEntry(url: entry.url, metadata: unnamed).displayName == entry.id)
    }
}
