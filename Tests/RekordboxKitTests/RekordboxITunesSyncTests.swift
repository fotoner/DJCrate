import DJCDomain
import Foundation
import RekordboxFixtures
@testable import RekordboxKit
import Testing

struct RekordboxITunesSyncTests {
    static let source: [ITunesSyncSelection.Node] = [
        .init(id: "F", parentID: nil, isFolder: true),
        .init(id: "A", parentID: "F", isFolder: false),
        .init(id: "B", parentID: "F", isFolder: false),
        .init(id: "C", parentID: nil, isFolder: false),
    ]
    static let original = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <SYNC_ITUNES_PLAYLIST Version="3.0.0">
          <PRODUCT Name="rekordbox" Version="7.2.18" Company="Pioneer DJ"/>
          <PLAYLISTS>
            <NODE Id="0" ParentId="0" Attribute="1" Timestamp="0" Lib_Type="1" CheckType="2"/>
            <NODE Id="F" ParentId="0" Attribute="1" Timestamp="100" Lib_Type="1" CheckType="1"/>
            <NODE Id="A" ParentId="F" Attribute="0" Timestamp="101" Lib_Type="1" CheckType="1"/>
            <NODE Id="B" ParentId="F" Attribute="0" Timestamp="102" Lib_Type="1" CheckType="1"/>
          </PLAYLISTS>
        </SYNC_ITUNES_PLAYLIST>
        """.utf8)

    func change() -> RekordboxITunesSyncChange {
        .init(base: Self.original, source: Self.source, selection: ITunesSyncSelection(selectedIDs: ["B"]))
    }

    /// 2026-09-27 rekordbox 7.2.14.0323: '2410슬 오프닝' 해제. 해당 NODE 제거·부모 1→2·남은 항목 시각 갱신, DB 불변.
    @Test func 해제_골든_2410슬_오프닝() throws {
        let data = try change().render(timestamp: { _ in 200 })
        let parsed = try RekordboxITunesSelection.parse(data)
        #expect(parsed.nodes.map(\.id) == ["0", "F", "B"])
        #expect(parsed.selectedIDs == ["B"])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("Id=\"F\" ParentId=\"0\" Attribute=\"1\" Timestamp=\"200\" Lib_Type=\"1\" CheckType=\"2\""))
        #expect(text.contains("Id=\"0\" ParentId=\"0\" Attribute=\"1\" Timestamp=\"0\""))
        #expect(text.contains("Company=\"Pioneer DJ\""))
    }

    /// 같은 실험에서 다시 체크해도 부모 2는 그대로이며, 되살아난 목록의 선택만 1이 된다.
    @Test func 재선택_골든_2410슬_오프닝() throws {
        let deselected = try change().render(timestamp: { _ in 200 })
        let restored = try RekordboxITunesSyncChange(base: deselected, source: Self.source,
                                                    selection: .init(selectedIDs: ["A", "B"])).render(timestamp: { _ in 300 })
        let parsed = try RekordboxITunesSelection.parse(restored)
        #expect(parsed.nodes.map(\.id) == ["0", "F", "A", "B"])
        #expect(parsed.selectedIDs == ["A", "B"])
        #expect(!parsed.nodes.first(where: { $0.id == "F" })!.isSelected)
    }

    @Test func 전체_선택과_해제는_루트와_하위에_같이_반영된다() throws {
        let all = try RekordboxITunesSyncChange(base: Self.original, source: Self.source,
                                               selection: .init(selectedIDs: ["0"])).render()
        let parsed = try RekordboxITunesSelection.parse(all)
        #expect(parsed.nodes.allSatisfy { $0.isSelected })
        #expect(parsed.selectedIDs == ["F", "A", "B", "C"])
        let none = try RekordboxITunesSyncChange(base: all, source: Self.source, selection: .init()).render()
        let cleared = try RekordboxITunesSelection.parse(none)
        #expect(cleared.nodes.map(\.id) == ["0"])
        #expect(cleared.selectedIDs.isEmpty && !cleared.nodes[0].isSelected)
    }

    @Test func 사본에_쓰고_다시_읽으며_DB와_변경_카운터는_그대로다() throws {
        let fixture = try RekordboxFixture()
        let target = fixture.root.appending(path: "playlists3.sync")
        try Self.original.write(to: target)
        let before = try Data(contentsOf: fixture.database), counter = try fixture.localUpdateCount()
        let report = try RekordboxWriter.write(drafts: [], iTunesSync: change(), to: fixture.database,
                                               dryRun: false, backups: fixture.backups)
        #expect(report.iTunesSyncWritten == true)
        #expect(try RekordboxITunesSelection.parse(Data(contentsOf: target)).selectedIDs == ["B"])
        #expect(try Data(contentsOf: fixture.database) == before)
        #expect(try fixture.localUpdateCount() == counter)
        let backup = URL(filePath: try #require(report.backup))
        #expect(try Data(contentsOf: backup.appending(path: "itunes-sync-before.xml")) == Self.original)
        _ = try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups)
        #expect(try Data(contentsOf: target) == Self.original)
    }

    @Test func 외부_변경과_실행_중이면_백업_전에_거부한다() throws {
        let fixture = try RekordboxFixture()
        let target = fixture.root.appending(path: "playlists3.sync")
        try Self.original.write(to: target)
        let running = RekordboxWriteGuard(isLive: { _ in true }, isRekordboxRunning: { true }, appVersion: { "7.2.18" })
        #expect(throws: (any Error).self) {
            try RekordboxWriter.write(drafts: [], iTunesSync: change(), to: fixture.database,
                                      dryRun: false, backups: fixture.backups, guard: running)
        }
        try (Self.original + Data("\n".utf8)).write(to: target)
        #expect(throws: (any Error).self) {
            try RekordboxWriter.write(drafts: [], iTunesSync: change(), to: fixture.database,
                                      dryRun: false, backups: fixture.backups)
        }
        #expect(RekordboxWriter.backups(in: fixture.backups).isEmpty)
    }

    @Test func 재검증_실패는_원본을_복원한다() throws {
        let fixture = try RekordboxFixture()
        let target = fixture.root.appending(path: "playlists3.sync")
        try Self.original.write(to: target)
        #expect(throws: (any Error).self) {
            try RekordboxWriter.writeITunesSync(change(), to: fixture.database, dryRun: false, now: .now,
                                                backups: fixture.backups, guard: .system,
                                                writeFile: { _, url in try Data("broken".utf8).write(to: url, options: .atomic) })
        }
        #expect(try Data(contentsOf: target) == Self.original)
    }

    @Test func 미리보기는_파일과_백업을_만들지_않는다() throws {
        let fixture = try RekordboxFixture()
        let target = fixture.root.appending(path: "playlists3.sync")
        try Self.original.write(to: target)
        _ = try RekordboxWriter.write(drafts: [], iTunesSync: change(), to: fixture.database, dryRun: true, backups: fixture.backups)
        #expect(try Data(contentsOf: target) == Self.original)
        #expect(RekordboxWriter.backups(in: fixture.backups).isEmpty)
    }

    @Test func 같은_선택은_시각도_다시_쓰지_않는다() throws {
        let fixture = try RekordboxFixture(), target = fixture.root.appending(path: "playlists3.sync")
        try Self.original.write(to: target)
        let unchanged = RekordboxITunesSyncChange(base: Self.original, source: Self.source, selection: .init(selectedIDs: ["F"]))
        let report = try RekordboxWriter.write(drafts: [], iTunesSync: unchanged, to: fixture.database, dryRun: false, backups: fixture.backups)
        #expect(report.iTunesSyncWritten == false && report.backup == nil)
        #expect(try Data(contentsOf: target) == Self.original)
    }

    @Test func 반영_후_외부에서_바꾼_선택은_되돌리기로_덮지_않는다() throws {
        let fixture = try RekordboxFixture(), target = fixture.root.appending(path: "playlists3.sync")
        try Self.original.write(to: target)
        let report = try RekordboxWriter.write(drafts: [], iTunesSync: change(), to: fixture.database, dryRun: false, backups: fixture.backups)
        try Self.original.write(to: target)
        let backup = URL(filePath: try #require(report.backup))
        #expect(throws: (any Error).self) { try RekordboxWriter.restore(backup, to: fixture.database, backups: fixture.backups) }
        #expect(try Data(contentsOf: target) == Self.original)
    }

    @Test(arguments: [false, true]) func 사본_옆_라이브_동기화_링크는_거부한다(symbolic: Bool) throws {
        let live = try RekordboxFixture(), copy = try RekordboxFixture()
        let original = live.root.appending(path: "playlists3.sync"), alias = copy.root.appending(path: "playlists3.sync")
        try Self.original.write(to: original)
        if symbolic { try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original) }
        else { try FileManager.default.linkItem(at: original, to: alias) }
        let guardCopy = RekordboxWriteGuard(isRekordboxRunning: { false }, appVersion: { "7.2.18" }, liveDirectories: [live.root])
        #expect(throws: (any Error).self) {
            try RekordboxWriter.write(drafts: [], iTunesSync: change(), to: copy.database, dryRun: false, backups: copy.backups, guard: guardCopy)
        }
        #expect(try Data(contentsOf: original) == Self.original)
        #expect(RekordboxWriter.backups(in: copy.backups).isEmpty)
    }

    @Test func 모르는_칸과_순환_폴더는_추측해서_쓰지_않는다() {
        let unknown = Data(String(decoding: Self.original, as: UTF8.self).replacingOccurrences(of: "Timestamp=\"100\"", with: "Timestamp=\"100\" Unknown=\"x\"").utf8)
        #expect(throws: (any Error).self) {
            try RekordboxITunesSyncChange(base: unknown, source: Self.source, selection: .init()).render()
        }
        #expect(throws: (any Error).self) {
            try RekordboxITunesSyncChange(base: Self.original, source: [.init(id: "A", parentID: "A", isFolder: true)], selection: .init()).render()
        }
    }

    @Test func 쓰기_중_rekordbox가_켜지면_복원을_보류하고_종료_후_백업으로_되돌린다() throws {
        let fixture = try RekordboxFixture(), target = fixture.root.appending(path: "playlists3.sync")
        try Self.original.write(to: target)
        let state = SyncRunningState()
        let guardCopy = RekordboxWriteGuard(isRekordboxRunning: { state.running }, appVersion: { "7.2.14.0323" },
                                            liveDirectories: [fixture.root])
        do {
            _ = try RekordboxWriter.writeITunesSync(change(), to: fixture.database, dryRun: false, now: .now,
                                                    backups: fixture.backups, guard: guardCopy, writeFile: { data, url in
                try data.write(to: url, options: .atomic)
                state.running = true
                throw CocoaError(.fileWriteUnknown)
            })
            Issue.record("재실행한 동안에는 복원이 보류되어야 함")
        } catch let error as DJCError {
            if case .restoreFailed = error {} else { Issue.record("복원 보류 대신 다른 오류: \(error)") }
        }
        #expect(try Data(contentsOf: target) != Self.original)
        state.running = false
        let backup = try #require(RekordboxWriter.backups(in: fixture.backups).first)
        _ = try RekordboxWriter.restore(backup.url, to: fixture.database, backups: fixture.backups, guard: guardCopy)
        #expect(try Data(contentsOf: target) == Self.original)
    }
}

/// 실행 여부 콜백은 Sendable이므로 시험 중 변경도 잠금 안에서 한다.
private final class SyncRunningState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var running: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}
