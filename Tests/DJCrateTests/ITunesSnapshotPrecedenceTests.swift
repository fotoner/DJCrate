import DJCAdapters
import DJCApplication
@testable import DJCrate
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxKit
import Testing

@Suite("iTunes 사본 선택 우선순위")
struct ITunesSnapshotPrecedenceTests {
    private func selectedSnapshots() throws -> (old: ITunesLibrarySnapshot, current: ITunesLibrarySnapshot,
                                                 sync: Data) {
        let oldSync = Data("""
            <SYNC_ITUNES_PLAYLIST Version="3.0.0"><PLAYLISTS>
            <NODE Id="0" ParentId="0" Attribute="1" Timestamp="0" Lib_Type="1" CheckType="2"/>
            <NODE Id="A" ParentId="0" Attribute="0" Timestamp="100" Lib_Type="1" CheckType="1"/>
            </PLAYLISTS></SYNC_ITUNES_PLAYLIST>
            """.utf8)
        let catalog = ITunesLibrarySnapshot(sourcePlaylists: [
            .init(id: "A", name: "이전 선택"), .init(id: "B", name: "현재 선택")
        ])
        var previous = try catalog.applyingRekordboxSelection(oldSync)
        previous.status = .stale
        let currentSync = try RekordboxITunesSyncChange(base: oldSync, source: previous.selectionNodes,
                                                       selection: .init(selectedIDs: ["B"])).render()
        return (previous, try catalog.applyingRekordboxSelection(currentSync), currentSync)
    }

    @Test(arguments: [false, true])
    func 현재_sync와_일치하는_정상_사본을_낡은_이전_선택으로_덮지_않는다(preferPrevious: Bool) throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        let values = try selectedSnapshots()
        try values.sync.write(to: folder.url.appending(path: "playlists3.sync"))
        try values.current.save(for: folder.database)

        let loaded = try LoadedLibrary.load(snapshot: folder.database, previousITunesSnapshot:
            .init(source: folder.url.appending(path: "previous.db"), contents: values.old,
                  preferOverCurrent: preferPrevious), fallbackDirectory: LibrarySnapshot.defaultDirectory, drafts: .dataFolder(), source: .withoutDatabase)

        #expect(loaded.iTunesSnapshot.status == .ready)
        #expect(loaded.iTunesSnapshot.selectedIDs == ["B"])
        #expect(loaded.iTunesSnapshot.syncData == values.sync)
        #expect(ITunesLibrarySnapshot.load(for: folder.database).status == .ready)
        #expect(ITunesLibrarySnapshot.load(for: folder.database).selectedIDs == ["B"])
    }

    @Test func Music_캡처가_실패해도_현재_정상_사본을_낡은_이전_선택으로_덮지_않는다() throws {
        let folder = try TemporaryFolder.withEmptyDatabase()
        let values = try selectedSnapshots()
        try values.sync.write(to: folder.url.appending(path: "playlists3.sync"))
        try values.current.save(for: folder.database)

        let loaded = try LoadedLibrary.load(snapshot: folder.database, refreshITunes: true,
            previousITunesSnapshot: .init(source: folder.url.appending(path: "previous.db"),
                                          contents: values.old, preferOverCurrent: true),
            fallbackDirectory: LibrarySnapshot.defaultDirectory,
            drafts: .dataFolder(), source: .withoutDatabase,
            captureITunes: { ITunesLibrarySnapshot(status: .unavailable) })

        #expect(loaded.iTunesSnapshot.status == .stale)
        #expect(loaded.iTunesSnapshot.selectedIDs == ["B"])
        #expect(loaded.iTunesSnapshot.syncData == values.sync)
        #expect(ITunesLibrarySnapshot.load(for: folder.database) == values.current)
    }
}
