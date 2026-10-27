@testable import DJCrate
import DJCApplication
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import Testing

/// 목록 위 오류 줄·안내 줄을 없애고 창 알림과 활동 기록으로 옮겼다(#307). 묶음마다 알림으로 뜨고 기록에 남는지 본다.
@MainActor
@Suite("알림 — 목록 위 줄 대신 창 알림")
struct NoticeChannelTests {
    static func store(playlistImportURL: URL? = PlaylistImportStore.url) -> LibraryStore {
        LibraryStore.test(activityLog: ActivityLog(url: nil), feedback: AppFeedback(announce: { _ in }),
                          playlistImportURL: playlistImportURL, stagingSaver: { _ in })
    }

    // MARK: - 읽기·초안 오류

    @Test func 라이브러리_오류는_창_알림으로_뜨고_활동_기록에_남는다() throws {
        let store = Self.store()
        store.reportLibraryError("시험 오류라 이전 목록을 표시합니다. 잠시 뒤 다시 읽으세요")
        let toast = try #require(store.toast)
        #expect(toast.title == "시험 오류라 이전 목록을 표시합니다. 잠시 뒤 다시 읽으세요" && toast.kind == .warning)
        // 결과 보기 대신 [열기]로 활동 팝오버에서 다시 본다
        #expect(!toast.showsResult && toast.opensActivity)
        let entry = try #require(store.activityLog.latest)
        #expect(entry.id == toast.activityID && entry.title == toast.title && entry.unshown != true)
        // 읽기·쓰기 흐름이 보는 오류 상태는 그대로 남는다
        #expect(store.lastError == toast.title)
    }

    @Test func 떠_있는_경고를_덮지_않고_띄우지_못한_알림으로_남긴다() throws {
        let store = Self.store()
        store.showToast(AppToast(kind: .warning, title: "먼저 뜬 경고"))
        let warning = try #require(store.toast)
        store.reportLibraryError("뒤에 온 오류")
        #expect(store.toast?.id == warning.id)
        let entry = try #require(store.activityLog.latest)
        #expect(entry.title == "뒤에 온 오류" && entry.unshown == true)
        #expect(store.activityLog.entries.count == 2)
    }

    /// 읽을 때마다 같은 오류가 다시 와도 떠 있는 실패 알림을 놓치지 않고, 오류가 풀리면 거둔다(#307 리뷰).
    /// 사용자가 닫은 뒤 다시 일어난 오류는 다시 뜬다(#230, `AsyncFailureGuidanceTests`)
    @Test func 떠_있는_같은_오류는_다시_알리지_않고_풀리면_알림을_거둔다() throws {
        let store = Self.store()
        store.reportLibraryError("시험 저장 실패", kind: .failure)
        let first = try #require(store.toast)
        store.reportLibraryError("시험 저장 실패", kind: .failure)
        #expect(store.toast?.id == first.id && store.noticeCount == 1)
        store.clearLibraryError()
        #expect(store.toast == nil)
    }

    @Test func 다른_오류가_오면_앞_오류_알림을_바꾸고_풀리면_거둔다() {
        let store = Self.store()
        store.reportLibraryError("앞 실패", kind: .failure)
        store.reportLibraryError("뒤 실패", kind: .failure)
        #expect(store.toast?.title == "뒤 실패" && store.activityLog.entries.count == 2)
        store.clearLibraryError()
        #expect(store.toast == nil)
    }

    /// 읽을 때마다 다시 구하는 상태 안내는 내용이 바뀔 때만 알린다(#307 리뷰)
    @Test func 바뀌지_않은_상태_안내는_다시_알리지_않는다() {
        let store = Self.store()
        func count(_ title: String) -> Int { store.activityLog.entries.filter { $0.title == title }.reduce(0) { $0 + $1.count } }
        store.notifyState(.reflectionCheck, .notice(text: "확인하지 못함 1", kind: .warning))
        store.showToast(.notice(text: "끼어든 안내", kind: .success))
        store.notifyState(.reflectionCheck, .notice(text: "확인하지 못함 1", kind: .warning))
        #expect(count("확인하지 못함 1") == 1)
        // 내용이 바뀌면 다시 알린다
        store.notifyState(.reflectionCheck, .notice(text: "확인하지 못함 2", kind: .warning))
        #expect(count("확인하지 못함 2") == 1)
        // 풀렸다가 다시 생기면 다시 알린다
        store.notifyState(.reflectionCheck, nil)
        store.notifyState(.reflectionCheck, .notice(text: "확인하지 못함 2", kind: .warning))
        #expect(count("확인하지 못함 2") == 2)
    }

    /// 메모리에만 남은 재생 목록 초안은 다른 저장 실패처럼 닫을 때까지 남는 실패로 알린다(#307 리뷰)
    @Test func 재생_목록_초안_저장_실패는_닫을_때까지_남는_실패로_알린다() {
        let store = Self.store()
        store.playlists.applyPlaylistSave(CocoaError(.fileWriteNoPermission))
        #expect(store.toast?.kind == .failure && store.toast?.title == PlaylistEditStore.playlistSaveFailureText)
        store.playlists.applyPlaylistSave(nil)
        #expect(store.toast == nil)
    }

    /// 띄우지 못한 알림도 VoiceOver로는 알린다(목록 위 줄이던 때처럼)
    @Test func 띄우지_못한_알림도_VoiceOver로_알린다() {
        var spoken: [String] = []
        let store = LibraryStore.test(activityLog: ActivityLog(url: nil), feedback: AppFeedback(announce: { spoken.append($0.text) }),
                                      stagingSaver: { _ in })
        store.showToast(AppToast(kind: .failure, title: "먼저 뜬 실패"))
        store.reportLibraryError("뒤에 온 오류")
        #expect(spoken == ["먼저 뜬 실패", "뒤에 온 오류"])
    }

    @Test func 손상된_초안_파일을_옮긴_안내는_알림으로_뜨고_그동안_더_옮기면_수를_더한다() throws {
        let store = Self.store()
        func moved(_ name: String, _ uuid: String) -> DamagedDraftFile {
            DamagedDraftFile(name: name, preserved: URL(filePath: "/tmp/damaged-drafts/\(uuid).json"), trackUUID: uuid)
        }
        store.reportDamagedDrafts([moved("cue-drafts/u1.json", "u1")])
        #expect(store.toast?.title == LibraryStore.damagedDraftText(1))
        store.reportDamagedDrafts([moved("grid-drafts/u2.json", "u2")])
        // 알림이 떠 있는 동안 더 옮기면 앞 알림을 고쳐 수를 더한다(따로 쌓지 않는다)
        #expect(store.toast?.title == LibraryStore.damagedDraftText(2))
        #expect(store.activityLog.entries.map(\.title) == [LibraryStore.damagedDraftText(2)])
        // 닫은 뒤 옮기면 새로 센다
        store.dismissToast()
        store.reportDamagedDrafts([moved("tag-drafts/u3.json", "u3")])
        #expect(store.toast?.title == LibraryStore.damagedDraftText(1))
    }

    /// 손상 안내가 떠 있는 사이 띄우지 못한 알림이 끼어도 손상 안내는 한 항목으로 고친다(수가 겹쳐 읽히지 않게)
    @Test func 손상_안내를_고칠_때_끼어든_항목을_건너뛴다() {
        let store = Self.store()
        func moved(_ uuid: String) -> DamagedDraftFile {
            DamagedDraftFile(name: "cue-drafts/\(uuid).json", preserved: URL(filePath: "/tmp/damaged-drafts/\(uuid).json"), trackUUID: uuid)
        }
        store.reportDamagedDrafts([moved("u1")])
        store.reportLibraryError("끼어든 오류")
        store.reportDamagedDrafts([moved("u2"), moved("u3")])
        #expect(store.toast?.title == LibraryStore.damagedDraftText(3))
        #expect(store.activityLog.entries.map(\.title) == [LibraryStore.damagedDraftText(3), "끼어든 오류"])
    }

    /// 반영 세션은 뒤따른 경고를 쓰기 결과에 담고, 같은 줄을 오류 상태로도 남긴다. 그 줄을 알림으로 또 띄우지 않는다
    @Test func 쓰기_뒤따른_경고는_쓰기_결과_알림만_알린다() {
        let store = Self.store()
        store.applyReflection(.followUp(["rekordbox에는 썼지만 초안을 정리하지 못했습니다."]))
        store.applyReflection(.libraryError("rekordbox에는 썼지만 초안을 정리하지 못했습니다."))
        #expect(store.lastError == "rekordbox에는 썼지만 초안을 정리하지 못했습니다.")
        #expect(store.toast == nil && store.activityLog.entries.isEmpty)
        // 뒤따른 경고 없이 온 오류는 알린다
        store.applyReflection(.libraryError("복원한 곡의 초안을 저장하지 못했습니다."))
        #expect(store.toast?.title == "복원한 곡의 초안을 저장하지 못했습니다.")
    }

    // MARK: - 추가한 곡·XML

    @Test func 추가한_곡_안내는_창_알림으로_뜨고_활동_기록에_남는다() async throws {
        let folder = try TemporaryFolder()
        let text = folder.url.appending(path: "메모.txt")
        try Data("음원이 아님".utf8).write(to: text)
        let store = Self.store()
        await store.staging.addFiles([text])
        let toast = try #require(store.toast)
        #expect(toast.title.contains("추가할 음원이 없습니다") && toast.kind == .warning)
        #expect(store.activityLog.latest?.title == toast.title)
    }

    @Test func XML로_만들_곡이_없으면_창_알림으로_알린다() throws {
        let store = Self.store()
        ReflectionPanels.export(store: store, rows: [])
        let toast = try #require(store.toast)
        #expect(toast.title == "XML로 만들 곡이 없습니다")
        #expect(toast.detail == "고른 곡에 rekordbox와 다른 큐·그리드 초안이 없습니다.")
        #expect(store.activityLog.latest?.title == "XML로 만들 곡이 없습니다")
    }

    /// 연결 기록을 읽지 못해 막힌 곡 추가는 저장 권한이 아니라 연결 기록 파일을 보라고 알린다
    @Test func 연결_기록을_읽지_못했으면_곡_추가_실패에_그_할_일을_알린다() async throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "playlist-imports.json")
        try Data("읽을 수 없는 연결 기록".utf8).write(to: url)
        let file = try AudioFixture.wav(seconds: 0.1, in: folder.url)
        let store = Self.store(playlistImportURL: url)
        store.playlists.rekordboxPlaylists = PlaylistLayout([(.init(id: "P", name: "세트"), 1)])
        store.playlists.refreshPlaylists()
        store.dismissToast()
        await store.staging.addFiles([file], toPlaylist: "P")
        let toast = try #require(store.toast)
        #expect(toast.kind == .failure && toast.title.hasPrefix("재생 목록 연결을 읽지 못했습니다"))
    }

    // MARK: - 재생 목록

    @Test func 재생_목록_안내는_창_알림으로_뜨고_활동_기록에_남는다() throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "playlist-imports.json")
        try Data("읽을 수 없는 연결 기록".utf8).write(to: url)
        let store = Self.store(playlistImportURL: url)
        _ = store.playlists
        let toast = try #require(store.toast)
        #expect(toast.title.hasPrefix("재생 목록 연결을 읽지 못했습니다") && toast.kind == .warning)
        #expect(store.activityLog.latest?.title == toast.title)
    }
}

extension LibraryStore {
    /// 지금까지 남긴 알림 수(바로 앞과 같아 합친 것도 센다). 알림을 새로 남기지 않았는지 볼 때 쓴다(#307)
    var noticeCount: Int { activityLog.entries.reduce(0) { $0 + $1.count } }
}
