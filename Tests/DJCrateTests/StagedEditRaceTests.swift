@testable import DJCrate
import DJCAdapters
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import Testing

/// 편집본 넣기와 화면 모델의 추가 목록 저장이 겹칠 때(adv2 N8): 편집본 줄이 `staged.json`에서 사라지면 안 된다.
/// 옛 넣기(`EditStaging.stage`)는 디스크의 목록에 덧붙이고 화면 모델은 메모리 목록으로 덮어, 첫 시험의 순서에서 편집본 줄을 잃었다
/// (빨간색 기록: 167-work/logs/h2d-race-red.log). 이제 넣기는 앱 조립 지점의 `StagingStore`로 저장소가 든 목록과 디스크를 한 길로 고친다.
@MainActor
@Suite("편집본 넣기와 추가 목록 저장")
struct StagedEditRaceTests {
    let home = FileManager.default.temporaryDirectory.appending(path: "djc-staged-race-\(UUID().uuidString)")

    func store() throws -> (LibraryStore, StagedTrack) {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = LibraryStore.test(resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                      saveTagDrafts: { _ in }, backupDirectory: home.appending(path: "backups"), playlistDraftSaver: { _ in },
                                      mergeDraftSaver: { _ in }, playlistImportURL: nil, draftHome: home)
        // 이미 추가한 곡 하나(그리드 추정·키 찾기가 끝나 목록 저장이 일어날 곡). 시험이 그 저장을 직접 일으키므로 BPM·키를 미리 채워
        // 다시 읽을 때 진짜 추정이 돌지 않게 한다: 돌면 추정이 시험이 넣은 키를 늦게 덮어 간헐 실패한다(`loadStaged`가 이어서 하는 추정).
        var earlier = StagedTrack(uuid: "earlier", path: try AudioFixture.wav(seconds: 1, in: home, name: "앞 곡.wav").path, title: "앞 곡",
                                  duration: 1, addedOn: "2026-10-09")
        earlier.bpm = 120
        earlier.key = "1A"
        earlier.keySource = .tag
        try store.testPorts.staging.save([earlier])
        store.loadStaged()
        return (store, earlier)
    }

    func request() throws -> EditStagingRequest {
        EditStagingRequest(file: try AudioFixture.wav(seconds: 2, in: home, name: "원곡 (Edit).wav"),
                           grid: [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)], cues: [], source: nil, title: "원곡 (Edit)")
    }

    @Test func 편집본을_넣은_뒤_보여_주기_전에_추가_목록을_저장해도_편집본_줄이_남는다() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let (store, earlier) = try store()
        // 편집 창이 렌더한 편집본을 추가한 곡에 넣는다(앱과 같은 조립)
        let staged = try await AppComposition.renderEdit(store: store).stager.stage(try request())
        // 그 사이 앞 곡의 키 추정이 끝나 화면 모델이 메모리의 목록을 저장한다
        store.setStagedKey(uuid: earlier.uuid, key: "8A", source: .estimate)
        // 넣기가 끝나 편집본을 보여 준다
        store.showStagedEdit(staged)

        #expect(store.testPorts.staging.tracks().map(\.uuid) == [earlier.uuid, staged.uuid], "편집본 줄이 추가 목록 파일에 남아야 한다")
        #expect(store.staged.map(\.uuid) == [earlier.uuid, staged.uuid])
        #expect(store.staged.first?.key == "8A", "앞 곡의 키 저장도 남는다")
    }

    @Test func 넣는_도중_추가_목록이_바뀌어도_두_변경이_모두_남는다() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let (store, earlier) = try store()
        var stager = AppComposition.renderEdit(store: store).stager
        let read = stager.files.readTrack
        // 태그를 읽는 동안(메인 밖) 앞 곡의 키 추정이 끝나 목록이 저장된다
        stager.files.readTrack = { url, addedOn in
            await MainActor.run { store.setStagedKey(uuid: earlier.uuid, key: "8A", source: .estimate) }
            return try await read(url, addedOn)
        }
        let staged = try await stager.stage(try request())

        #expect(store.testPorts.staging.tracks().map(\.uuid) == [earlier.uuid, staged.uuid])
        #expect(store.testPorts.staging.tracks().first?.key == "8A")
        #expect(store.staged.map(\.uuid) == [earlier.uuid, staged.uuid])
    }
}
