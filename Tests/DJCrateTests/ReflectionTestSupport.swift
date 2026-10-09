@testable import DJCrate
import DJCAdapters
import DJCApplication
import DJCDomain
import Foundation

/// 시험 저장소의 rekordbox 쓰기 설정. 조립 지점(`AppComposition.reflection`)과 같은 연결로 붙이고, 관문·백업 파일 쓰기·확인 창·
/// rekordbox 실행 여부만 바꿔 넣는다(기본은 실제 관문, 실제 백업 폴더 쓰기, 정해 둔 답의 확인 창, rekordbox 꺼짐).
@MainActor
final class TestReflection {
    var gate: RekordboxWriteGate = .live()
    /// 곡 넣기 백업에 추가 목록·초안 사본을 쓴다(저장 실패를 만들려고 바꾼다)
    var backupFileWriter: @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    var prompter: any ReflectionPrompter = ScriptedPrompter()
    var running = false
}

@MainActor private var testReflections: [ObjectIdentifier: (store: WeakLibraryStore, config: TestReflection)] = [:]

private struct WeakLibraryStore {
    weak var store: LibraryStore?
}

extension LibraryStore {
    /// 이 저장소의 쓰기 시험 설정(처음 부를 때 기본값으로 만든다)
    var testReflection: TestReflection {
        let key = ObjectIdentifier(self)
        if let entry = testReflections[key], entry.store.store === self { return entry.config }
        let config = TestReflection()
        testReflections[key] = (WeakLibraryStore(store: self), config)
        return config
    }

    /// 시험 설정으로 붙인 rekordbox 쓰기의 화면 쪽(부를 때마다 만든다: 상태는 저장소에 있다)
    var reflection: ReflectionCoordinator {
        let config = testReflection, running = config.running
        return AppComposition.reflection(store: self, gate: config.gate, backups: .live(writeFile: config.backupFileWriter), prompter: config.prompter,
                                         runningApps: RunningApps { running })
    }

    /// 시험 설정으로 붙인 반영 세션
    var session: ReflectionSession { reflection.session }
}

extension ReflectionCoordinator {
    /// 시험: 정해 둔 답의 확인 창·rekordbox 실행 여부·관문으로 저장소에 붙인다
    static func test(store: LibraryStore, prompter: any ReflectionPrompter = ScriptedPrompter(), running: Bool = false,
                     gate: RekordboxWriteGate? = nil) -> ReflectionCoordinator {
        let config = store.testReflection
        config.prompter = prompter
        config.running = running
        if let gate { config.gate = gate }
        return store.reflection
    }
}

extension ReflectionSession {
    /// 시험: 초안 묶음을 쓴다(쓴 뒤 처리까지). `database`를 주면 그 DB(사본)에, 아니면 이 세션의 대상에 쓴다. 백업은 위치의 백업 폴더.
    @discardableResult
    func writeToRekordbox(_ drafts: [CueDraft], grids: [GridDraft] = [], gains: [String: Double] = [:], tags: [TagDraft] = [],
                          artworks: [ArtworkEdit] = [], playlists: PlaylistDraft? = nil, merges: [DuplicateMergeDraft] = [],
                          to database: URL? = nil, shareRoot: URL? = nil) async throws -> RekordboxWriteReport {
        try await writeDrafts(DraftWriteBatch(drafts: drafts, grids: grids, gains: gains, tags: tags, artworks: artworks, playlists: playlists,
                                              merges: merges), to: target(database, shareRoot))
    }

    /// 시험: 이 세션의 대상을 백업으로 복원한다(지금 초안 남기기·되살리기까지)
    @discardableResult
    func restoreRekordbox(_ backup: RekordboxWriteBackup, keepingCurrentDrafts: Bool = true) async throws -> URL {
        try await restoreBackup(backup, keepingCurrentDrafts: keepingCurrentDrafts, to: target)
    }

    /// 시험: 미리 본 곡을 넣는다(넣은 뒤 처리까지). `database`를 주면 그 DB(사본)에
    @discardableResult
    func addTracksToRekordbox(_ preview: TrackAddPreview, to database: URL? = nil, shareRoot: URL? = nil) async throws -> RekordboxTrackWriteReport {
        try await add(preview, to: target(database, shareRoot))
    }

    /// 시험: 미리 본 곡을 뺀다(뺀 뒤 처리까지). `database`를 주면 그 DB(사본)에서
    @discardableResult
    func deleteTracksFromRekordbox(_ preview: TrackDeletePreview, from database: URL? = nil, shareRoot: URL? = nil) async throws -> RekordboxTrackWriteReport {
        try await delete(preview, from: target(database, shareRoot))
    }

    private func target(_ database: URL?, _ shareRoot: URL?) -> RekordboxWriteTarget {
        database.map { RekordboxWriteTarget(database: $0, shareRoot: shareRoot, backups: location.backupDirectory) } ?? target
    }
}

/// 확인 창 대신 정해 둔 답을 돌려준다(띄운 창을 남긴다).
@MainActor
final class ScriptedPrompter: ReflectionPrompter {
    var answer = true
    /// 차례로 쓸 확인 답(비면 `answer`)
    var answers: [Bool] = []
    /// 세 갈래 창의 답(비면 `answer`에 따라 확인·취소)
    var choices: [ReflectionChoice] = []
    var shown: [ReflectionPrompt] = []
    func show(_ prompt: ReflectionPrompt) -> Bool {
        shown.append(prompt)
        return answers.isEmpty ? answer : answers.removeFirst()
    }
    func choose(_ prompt: ReflectionPrompt) -> ReflectionChoice {
        shown.append(prompt)
        if !choices.isEmpty { return choices.removeFirst() }
        return answer ? .confirm : .cancel
    }
    /// 막힌 초안 복구 시트(#232): 창을 띄우지 않고 줄을 읽은 뒤 시험이 정한 동작(`onReview`, 없으면 취소)을 한다.
    var reviewed: [RecoverySheetModel] = []
    var onReview: ((RecoverySheetModel) async -> Void)?
    func review(_ model: RecoverySheetModel) async {
        reviewed.append(model)
        await model.load()
        if let onReview { await onReview(model) } else { model.cancel() }
        model.cancel()
    }
}

extension RekordboxWriteGate {
    /// 시험: 복원만 받아들이고(아무것도 바꾸지 않는다) 나머지는 거부하는 관문. 되살리기 같은 복원 뒤 일만 볼 때 쓴다.
    static var restoringOnly: Self {
        let refused = DJCError.writeRefused("시험 관문은 복원만 받는다")
        return RekordboxWriteGate(write: { _, _, _, _ in throw refused }, preview: { _, _, _, _ in throw refused },
                                  restore: { backup, _ in backup.deletingLastPathComponent().appending(path: "before-restore") },
                                  addTracks: { _, _, _ in throw refused }, deleteTracks: { _, _, _ in throw refused },
                                  restorePointSnapshot: { _, _, _, _, _ in throw refused }, writePlaylists: { _, _, _ in throw refused },
                                  syncITunes: { _, _ in throw refused })
    }
}

struct FixtureFailure: Error, CustomStringConvertible { var description = "미리 보기 실패" }
