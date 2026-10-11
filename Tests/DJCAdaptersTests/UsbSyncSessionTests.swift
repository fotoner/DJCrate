import DJCApplication
import DJCDomain
import DJCStorage
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

extension UsbEditSessionTests {
    @Test("목록 동기화만 있어도 로컬 사본을 뜨고, 막힌 새 목록 참조를 실제 USB 번호로 이어 받는다")
    func syncDraftRetryResolvesCreatedPlaylistAndUsesLocalCopy() throws {
        let env = try Env(), log = CopyLog(), key = env.usb.volumeKey
        // 아직 로컬 스냅샷에 없는 곡이라 목록 동기화가 막힌다(USB에 없는 곡만이면 그 곡을 빼고 쓴다)
        let session = env.session(localCopy: { try log.record($0, $1) })
        try session.addToDraft(.playlist(edit: .create(key: "retry-sync", name: "합성 동기화 목록", isFolder: false, parent: .root)))
        try session.addToDraft(.syncPlaylist(playlist: .new("retry-sync"), localContentIDs: ["104", "101", "104"]))
        let (first, report) = try session.writeDraft(options: .init(), snapshotTime: Self.time, progress: { _ in }, isCancelled: { false })
        #expect(report?.outcome == .written)
        #expect(first.outcome(1) == .written)
        guard case let .blocked(block) = first.outcome(2) else { Issue.record("동기화를 막지 않음"); return }
        #expect(block.code == "localTrackMissing")
        #expect(log.all.count == 1 && log.all.first?.database == env.fixture.local.database)
        let id = try #require(first.createdPlaylistIDs["retry-sync"])
        let kept = try #require(try env.drafts.load(volumeKey: key))
        #expect(kept.edits == [.syncPlaylist(playlist: .id(String(id)), localContentIDs: ["104", "101", "104"])])
        #expect(env.leftoverCopies.isEmpty)

        // 곡을 로컬에 넣고 USB에 더한 뒤 남은 동기화 초안을 그대로 다시 쓴다
        try env.fixture.addLocal(["104"])
        _ = try Self.write(env.session(), [.addTracks(localContentIDs: ["104"], playlist: nil)])
        let (retry, written) = try env.session().writeDraft(options: .init(), snapshotTime: Self.time, progress: { _ in }, isCancelled: { false })
        #expect(retry.outcome(1) == .written && written?.outcome == .written)
        #expect(try env.drafts.load(volumeKey: key) == nil)
        let after = try env.fixture.read()
        for format in UsbFormat.allCases { #expect(after.playlists.first { $0.id == id }?.entries[format] == [4, 1, 4]) }
    }

    @Test("로컬 사본 없이 동기화하지 않아 빈 목록으로 잘못 덮어쓰지 않는다")
    func syncRequiresLocalSnapshotEvenForEmptySelection() throws {
        let env = try Env(), before = env.usb.tree()
        let (result, report) = try Self.write(env.session(noDatabase: true), [.syncPlaylist(playlist: .id("1"), localContentIDs: [])])
        guard case let .blocked(block) = result.outcome(1) else { Issue.record("동기화를 막지 않음"); return }
        #expect(block.code == "localLibraryMissing")
        #expect(report == nil && result.changes == nil && env.usb.tree() == before)
        #expect(env.leftoverCopies.isEmpty && env.leftoverStaging.isEmpty)
    }
}
