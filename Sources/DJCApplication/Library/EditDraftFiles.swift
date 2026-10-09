import DJCDomain
import Foundation

/// 큐·태그 초안 파일 하나를 바로 만들거나 지운다(유스케이스, CLI `djc draft`). 앱이 꺼져 있을 때 에이전트·사람이 초안을 만드는 길이고,
/// 앱은 다시 읽기(1초 바깥 변경 확인)로 받는다. rekordbox에는 쓰지 않는다. 실패는 CLI JSON 계약의 `ReadFailure`로 던진다.
public struct EditDraftFiles: Sendable {
    let files: DraftFiles

    public init(files: DraftFiles) {
        self.files = files
    }

    public enum Kind: String, Sendable { case cue, tag }

    /// 큐 하나 넣기
    public struct CueRequest: Sendable {
        public var time: Double
        public var loopEnd: Double?
        public var beats: Double?
        /// 핫큐 칸(0~7). nil이면 메모리 큐
        public var slot: Int?
        public var name: String?
        /// 루프를 활성 루프로
        public var active: Bool

        public init(time: Double, loopEnd: Double?, beats: Double?, slot: Int?, name: String?, active: Bool) {
            self.time = time
            self.loopEnd = loopEnd
            self.beats = beats
            self.slot = slot
            self.name = name
            self.active = active
        }
    }

    /// 초안 파일 이름으로 쓸 수 있는 곡 UUID이고 초안 폴더·파일이 링크가 아닌지 본다(쓰기 전에)
    public func checkTarget(_ kind: Kind, uuid: String) throws {
        guard !uuid.isEmpty, !uuid.contains("/"), !uuid.contains("\0"), uuid != ".", uuid != ".." else {
            throw Self.invalid(String(ui: "곡 UUID를 초안 파일 이름으로 쓸 수 없습니다"))
        }
        guard files.isPlainPath(kind == .cue ? .cue : .tag, uuid) else {
            throw Self.invalid(String(ui: "초안 폴더나 파일의 심볼릭 링크를 해제하세요"))
        }
    }

    /// 초안을 지운다(미리 보기면 지우지 않는다)
    public func remove(_ kind: Kind, uuid: String, dryRun: Bool) throws {
        guard !dryRun else { return }
        try Self.io {
            if kind == .cue { try files.removeCue(uuid) } else { try files.removeTag(uuid) }
        }
    }

    /// 곡의 큐 초안(있으면 그 초안, 없으면 rekordbox 큐로 새로)에 큐 하나를 넣고 저장한다(미리 보기면 저장하지 않는다).
    /// 있던 초안을 먼저 읽고 그다음 요청을 푼다(`request`가 인자 오류를 던질 수 있다)
    public func addCue(_ makeRequest: () throws -> CueRequest, track: Track, rekordboxCues cues: [Cue], dryRun: Bool) throws -> CueDraft {
        try Self.io {
            let saved = try existing { try files.cue(track.uuid) }
            var draft = saved?.includingAutoCues(from: cues, newID: files.newCueID)
                ?? CueDraft(trackUUID: track.uuid, rekordboxCues: cues, newID: files.newCueID)
            guard draft.trackUUID == track.uuid, Set(draft.base.map(\.id)).count == draft.base.count,
                  Set(draft.cues.map(\.id)).count == draft.cues.count,
                  (draft.base + draft.cues).allSatisfy({ cue in
                      switch cue.kind { case .memory: true; case let .hot(slot): (0..<8).contains(slot) }
                  }) else { throw Self.corrupt() }
            let request = try makeRequest()
            let length = Double(track.lengthSeconds)
            guard request.time >= 0, request.time <= length,
                  request.loopEnd.map({ $0 > request.time && $0 <= length }) ?? true,
                  request.beats.map({ $0 > 0 && EditableCue.Loop.beatLoopSize(beats: $0) != 0 }) ?? true else {
                throw Self.invalid(String(ui: "큐·루프 시각은 곡 길이 안에, 루프 끝은 시작 뒤에, 박 수는 정수 또는 1/n으로 쓰세요"))
            }
            let loop = request.loopEnd.map { EditableCue.Loop(end: $0, beats: request.beats) }
            let selected: UUID
            if let slot = request.slot {
                let cue = EditableCue(id: files.newCueID(), kind: .hot(slot), time: request.time, name: request.name ?? "", loop: loop)
                draft.place(cue); selected = cue.id
            } else {
                switch draft.addMemory(at: request.time, loop: loop, newID: files.newCueID) {
                case .limitReached:
                    throw ReadFailure("invalid_draft", String(ui: "메모리 큐는 rekordbox 자동 큐를 포함해 10개까지입니다. 기존 큐를 앱에서 정리하세요"))
                case let .existing(id): selected = id
                case let .added(id):
                    selected = id
                    if var cue = draft.cue(id) { cue.name = request.name ?? ""; draft.place(cue) }
                }
            }
            if request.active, draft.cue(selected)?.loop?.active != true { draft.toggleActiveLoop(selected) }
            let issues = draft.issues(duration: length)
            guard issues.isEmpty else { throw Self.invalid(issues.joined(separator: "; ")) }
            if !dryRun { try files.saveCue(draft) }
            return draft
        }
    }

    /// 곡의 태그 초안(있으면 그 초안, 없으면 지금 rekordbox 값으로 새로)의 칸을 바꾸고 저장한다(미리 보기면 저장하지 않는다).
    /// 키·평점·곡 색은 고르기 값으로 맞추고, 쓰기 규칙을 확인하지 않은 칸은 막는다
    /// - Parameters:
    ///   - colors: rekordbox 곡 색 목록, `inPlaylist`: 그 곡이 재생 목록에 들었는지(쓰기 범위 판정)
    public func setTags(_ values: [TagFields.Key: String], track: Track, colors: [TrackColor], inPlaylist: Bool, dryRun: Bool) throws -> TagDraft {
        try Self.io {
            var draft: TagDraft = (try existing { try files.tag(track.uuid) } ?? TagDraft(track: track)).adoptingIndependentKeys(of: TagFields(track: track))
            guard draft.trackUUID == track.uuid else { throw Self.corrupt() }
            for key in TagFields.Key.allCases {
                guard let value = values[key] else { continue }
                draft.fields[key] = switch key {
                case .musicalKey: KeyNotation.normalizedCamelotName(value) ?? value
                case .rating: TrackRating.accepted(value) ?? value
                case .color: TrackColor.accepted(value, in: colors) ?? value
                default: value
                }
            }
            guard draft.issues.isEmpty else { throw Self.invalid(draft.issues.joined(separator: "; ")) }
            let touched = draft.changedKeys.filter { values[$0] != nil }
            if let reason = TagWriteScope.blockReason(keys: touched, state: track.dataStatus, inPlaylist: inPlaylist) {
                throw ReadFailure("unverified_field", reason)
            }
            if !dryRun { try files.saveTag(draft) }
            return draft
        }
    }

    /// 있던 초안 파일을 읽지 못하면 고치지 않는다
    private func existing<T>(_ read: () throws -> T?) throws -> T? {
        do { return try read() } catch { throw Self.corrupt() }
    }

    /// 실패를 CLI 계약의 이유로: 이미 `ReadFailure`면 그대로, 그 밖의 파일 오류는 초안 입출력 실패로
    private static func io<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as ReadFailure { throw error }
        catch { throw ReadFailure("draft_io_failed", String(ui: "초안을 읽거나 저장하지 못했습니다. DJC_HOME의 초안 파일과 접근 권한을 확인하세요")) }
    }

    static func corrupt() -> ReadFailure {
        ReadFailure("invalid_draft", String(ui: "기존 초안을 읽을 수 없습니다. 초안을 백업하고 앱에서 확인한 뒤 다시 시도하세요"))
    }

    static func invalid(_ message: String) -> ReadFailure {
        ReadFailure("invalid_arguments", String(ui: "\(message). docs/cli.md의 draft 사용법을 확인하세요"))
    }
}
