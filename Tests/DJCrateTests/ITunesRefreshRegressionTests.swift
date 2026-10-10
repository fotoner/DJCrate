import DJCAdapters
import DJCApplication
import DJCTestKit
@testable import DJCrate
import DJCStorage
import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

private final class ITunesCaptureGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
}

@Suite("iTunes 갱신 경합")
struct ITunesRefreshRegressionTests {
    @Test func 같은_폴더의_이전_정상_사본을_복구한다() throws {
        let fixture = try RekordboxFixture()
        let directory = fixture.root.appending(path: "snapshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = directory.appending(path: "master-2026-01-01T000001.db")
        let fresh = directory.appending(path: "master-2026-01-01T000002.db")
        for file in [previous, fresh] { try FileManager.default.copyItem(at: fixture.database, to: file) }
        let good = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "마지막 정상")])
        try good.save(for: previous)
        #expect(LibrarySnapshot.sameDirectory(fresh.deletingLastPathComponent(), directory))
        let loaded = try LoadedLibrary.load(snapshot: fresh, refreshITunes: true,
                                            previousITunesSnapshot: .init(source: previous, contents: good),
                                            fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                            drafts: .dataFolder(), source: .withoutDatabase,
                                            captureITunes: { ITunesLibrarySnapshot(status: .unavailable) })
        #expect(loaded.iTunesLibrary.status == .stale)
        #expect(loaded.iTunesLibrary.index["itunes:A"]?.name == "마지막 정상")
    }

    @Test func 직전_사본이_손상되면_같은_폴더에서_더_이전의_정상_사본을_찾는다() throws {
        let fixture = try RekordboxFixture()
        let directory = fixture.root.appending(path: "snapshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let goodURL = directory.appending(path: "master-2026-01-01T000001.db")
        let badURL = directory.appending(path: "master-2026-01-01T000002.db")
        let fresh = directory.appending(path: "master-2026-01-01T000003.db")
        for file in [goodURL, badURL, fresh] { try FileManager.default.copyItem(at: fixture.database, to: file) }
        try ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "더 이전 정상")]).save(for: goodURL)
        try Data("broken".utf8).write(to: ITunesLibrarySnapshot.url(for: badURL))
        let previous = LoadedLibrary.ITunesFallback(source: badURL, contents: ITunesLibrarySnapshot.load(for: badURL))
        let loaded = try LoadedLibrary.load(snapshot: fresh, refreshITunes: true, previousITunesSnapshot: previous,
                                            fallbackDirectory: directory,
                                            drafts: .dataFolder(), source: .withoutDatabase,
                                            captureITunes: { ITunesLibrarySnapshot(status: .unavailable) })
        #expect(loaded.iTunesLibrary.status == .stale)
        #expect(loaded.iTunesLibrary.index["itunes:A"]?.name == "더 이전 정상")
    }

    @Test(arguments: [false, true])
    func 늦은_이전_갱신은_최신_정상_사본을_덮지_못한다(firstFails: Bool) async throws {
        let fixture = try RekordboxFixture()
        let database = fixture.database
        let old = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "이전 정상")])
        let gate = ITunesCaptureGate()
        let previousURL = fixture.root.appending(path: "previous.db")
        let first = iTunesBlockingTask {
            try LoadedLibrary.load(snapshot: database, refreshITunes: true,
                                   previousITunesSnapshot: .init(source: previousURL, contents: old),
                                   fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                   drafts: .dataFolder(), source: .withoutDatabase,
                                   captureITunes: {
                                       gate.started.signal()
                                       // 최신 읽기가 끝날 때까지 자동으로 캡처를 재개하지 않는다.
                                       gate.resume.waitOffPool()
                                       return firstFails ? ITunesLibrarySnapshot(status: .unavailable) : old
                                   })
        }
        try await withTaskCancellationHandler {
            do {
                let started = await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        continuation.resume(returning: gate.started.wait(timeout: .now() + 10) == .success)
                    }
                }
                try #require(started)
                try Task.checkCancellation()
                let newer = ITunesLibrarySnapshot(playlists: [.init(id: "B", name: "새 정상")])
                let second = try LoadedLibrary.load(snapshot: database, refreshITunes: true, fallbackDirectory: LibrarySnapshot.defaultDirectory,
                                                    drafts: .dataFolder(), source: .withoutDatabase, captureITunes: { newer })
                try Task.checkCancellation()
                gate.resume.signal()
                let late = try await first.value
                try Task.checkCancellation()
                #expect(second.iTunesLibrary.index["itunes:B"] != nil)
                #expect(late.iTunesLibrary.index["itunes:B"] != nil)
                #expect(ITunesLibrarySnapshot.load(for: database).playlists.map(\.id) == ["B"])
            } catch {
                // 시작 실패·읽기 오류·취소에서도 작업을 회수한 뒤 사본 수명을 끝낸다.
                gate.resume.signal()
                _ = try? await first.value
                throw error
            }
        } onCancel: {
            gate.resume.signal()
        }
    }

    @Test func 작업_예약_순서가_실제_백그라운드_시작_순서와_달라도_최신_요청을_보존한다() throws {
        let fixture = try RekordboxFixture()
        let database = fixture.database
        let first = ITunesRefreshCoordinator.shared.begin(snapshot: database)
        let second = ITunesRefreshCoordinator.shared.begin(snapshot: database)
        let newer = ITunesLibrarySnapshot(playlists: [.init(id: "B", name: "새 정상")])
        _ = try LoadedLibrary.load(snapshot: database, refreshITunes: true,
                                   fallbackDirectory: LibrarySnapshot.defaultDirectory, refreshTicket: second,
                                    drafts: .dataFolder(), source: .withoutDatabase,
                                    captureITunes: { newer })
        let older = ITunesLibrarySnapshot(playlists: [.init(id: "A", name: "이전 정상")])
        let late = try LoadedLibrary.load(snapshot: database, refreshITunes: true,
                                          fallbackDirectory: LibrarySnapshot.defaultDirectory, refreshTicket: first,
                                          drafts: .dataFolder(), source: .withoutDatabase,
                                          captureITunes: { older })
        #expect(late.iTunesLibrary.index["itunes:B"] != nil)
        #expect(ITunesLibrarySnapshot.load(for: database).playlists.map(\.id) == ["B"])
    }
}
