import DJCDomain
import Foundation

/// USB 큐·그리드 가져오기 결과(토스트에 보인다)
public struct UsbCueGridImportSummary: Sendable {
    public var cueCount = 0
    public var gridCount = 0
    public var skippedCount = 0
    public var details: [String] = []

    public init(cueCount: Int = 0, gridCount: Int = 0, skippedCount: Int = 0, details: [String] = []) {
        self.cueCount = cueCount
        self.gridCount = gridCount
        self.skippedCount = skippedCount
        self.details = details
    }

    public var message: String {
        let counts = String(ui: "큐 \(cueCount)곡·그리드 \(gridCount)곡을 초안으로 가져왔습니다. \(skippedCount)곡은 건너뛰었습니다.")
        return details.first.map { counts + "\n" + $0 } ?? counts
    }
}

/// 가져오기가 보는 로컬 곡: 목록 행의 곡과 rekordbox 큐(앱 목록 행 대신 읽는 데 필요한 값만)
public struct UsbCueGridImportTrack: Sendable, Equatable {
    public var track: Track
    public var cues: [Cue]

    public init(track: Track, cues: [Cue]) {
        self.track = track
        self.cues = cues
    }
}

/// 기기의 값도 로컬 초안의 표현 범위를 벗어나면 덮어쓰지 않는다.
public enum UsbCueGridDraftImport {
    public static func uniqueLocalMatches(library: UsbLibrary, local: LocalLibraryKeys) -> [Int: String] {
        // 사이드바 배지는 비동기로 갱신된다. 지금 읽은 USB 사본과 같은 로컬 스냅샷으로만 짝을 확정한다.
        let fresh = UsbSyncBadges.evaluate(library: library, local: local).matches
        var counts: [String: Int] = [:]
        for track in library.tracks {
            if let id = fresh[track.id] { counts[id, default: 0] += 1 }
        }
        // 여러 USB 곡이 같은 로컬 곡을 가리키면 첫 곡을 임의로 고르지 않는다.
        return fresh.filter { counts[$0.value] == 1 }
    }

    /// 가져오는 칸. rekordbox의 "← CUE GRID INFO"는 로컬이 더 새로워도 USB 값으로 바꿨다(2026-10-08 실험 G5b: 로컬에서
    /// 더한 메모리 큐가 USB의 큐로 돌아갔다). 그래서 로컬 갱신 횟수는 보지 않고, 두 USB 형식이 서로 다를 때만 건너뛴다.
    /// 평점·색·코멘트는 가져오지 않는다: 확인 창은 곡 정보도 적었지만 USB와 로컬 값이 다른 곡에서도 로컬 값을 그대로 두었다
    /// (rekordbox 7.2.19 실험 X1, 2026-10-08)
    public enum Part: Sendable, CaseIterable { case cue, grid }

    public static func formatConflictReason(_ part: Part, conflicts: Set<String>) -> String? {
        switch part {
        case .cue where conflicts.contains("cueUpdateCount"):
            String(ui: "두 USB 형식의 큐 갱신 횟수가 다르니 rekordbox에서 USB를 확인한 뒤 큐를 가져오세요.")
        case .grid where conflicts.contains("analysisDataUpdateCount"):
            String(ui: "두 USB 형식의 그리드 갱신 횟수가 다르니 rekordbox에서 USB를 확인한 뒤 그리드를 가져오세요.")
        default: nil
        }
    }

    /// - Parameter newID: 로컬 큐로 시작하는 초안의 큐 ID(가져온 큐가 맞는 로컬 큐의 ID를 이어받는다)
    public static func cueDraft(uuid: String, local: [Cue], imported: [EditableCue], legacy: Bool, newID: () -> UUID) throws -> CueDraft {
        var draft = CueDraft(trackUUID: uuid, rekordboxCues: local, newID: newID)
        var unused = draft.base
        draft.cues = imported.map { incoming in
            var cue = incoming
            let index = unused.firstIndex { old in
                old.kind == cue.kind && (cue.kind != .memory || abs(old.time - cue.time) < 0.001)
            }
            if let index {
                let old = unused.remove(at: index)
                cue.id = old.id
                cue.sourceID = old.sourceID
                // PCOB에는 이름 칸이 없다. 같은 원본 큐의 이름을 빈칸으로 지우지 않는다.
                if legacy { cue.name = old.name }
            }
            return cue
        }
        guard draft.hasChanges else { return draft }
        guard !local.contains(where: { ($0.colorTableIndex ?? 0) != 0 || (1...8).contains($0.color ?? 255) }) else {
            throw issue(String(ui: "로컬 색 큐를 초안으로 보존할 수 없으니 rekordbox에서 직접 가져오세요."))
        }
        guard !local.contains(where: { $0.activeLoop != 0 }) else {
            throw issue(String(ui: "로컬 활성 루프를 초안으로 보존할 수 없으니 rekordbox에서 직접 가져오세요."))
        }
        guard !legacy || !local.contains(where: \.isLoop) else {
            throw issue(String(ui: "확장 큐 정보가 없어 로컬 루프 정보를 보존할 수 없으니 rekordbox에서 직접 가져오세요."))
        }
        return draft
    }

    public static func gridDraft(uuid: String, local: BeatGrid, imported: BeatGrid, duration: Double) throws -> GridDraft {
        guard duration > 0, duration.isFinite, !imported.beats.isEmpty,
              imported.beats.allSatisfy({ $0.time >= 0 && $0.time <= duration + 1 }) else {
            throw issue(String(ui: "박 위치가 곡 길이를 벗어나니 rekordbox에서 그리드를 확인한 뒤 다시 가져오세요."))
        }
        guard canRepresent(local, duration: duration), canRepresent(imported, duration: duration) else {
            throw issue(String(ui: "이 그리드의 박 위치나 박 번호를 초안으로 보존할 수 없으니 rekordbox에서 직접 가져오세요."))
        }
        let draft = GridDraft(trackUUID: uuid, base: GridDraft.segments(from: local), segments: GridDraft.segments(from: imported))
        // 경계 처리는 base에 따라 달라지므로 실제 반환 초안에서도 USB의 모든 박을 검사한다.
        let rebuilt = draft.grid(duration: max(duration + 1, imported.beats.last!.time + 0.01))
        guard preservesBeats(imported, in: rebuilt) else {
            throw issue(String(ui: "이 그리드의 박 위치나 박 번호를 초안으로 보존할 수 없으니 rekordbox에서 직접 가져오세요."))
        }
        return draft
    }

    private static func canRepresent(_ grid: BeatGrid, duration: Double) -> Bool {
        guard !grid.beats.isEmpty else { return true }
        guard grid.beats.allSatisfy({ $0.time.isFinite && $0.time >= 0 && GridDraft.bpmRange.contains($0.bpm) && (1...4).contains($0.number) }),
              zip(grid.beats, grid.beats.dropFirst()).allSatisfy({ $0.time < $1.time }) else { return false }
        let rebuilt = GridDraft(trackUUID: "", grid: grid).grid(duration: max(duration + 1, grid.beats.last!.time + 0.01))
        return preservesBeats(grid, in: rebuilt)
    }

    private static func preservesBeats(_ source: BeatGrid, in rebuilt: BeatGrid) -> Bool {
        // 가장 가까운 박의 시각만 비교하면 박 번호의 불연속을 놓친다.
        return source.beats.allSatisfy { beat in
            let index = rebuilt.firstIndex(atOrAfter: beat.time - 0.002)
            return [index - 1, index, index + 1].filter { rebuilt.beats.indices.contains($0) }.contains { i in
                let other = rebuilt.beats[i]
                return abs(other.time - beat.time) <= 0.002 && other.number == beat.number && abs(other.bpm - beat.bpm) < 0.005
            }
        }
    }

    public static func issue(_ message: String) -> UsbCueGridReadFailure { .init(message: message) }
}

/// 가져온 초안을 쓰는 곳(포트). 실제 구현은 앱이 DJCStorage 큐·그리드 초안 저장소로 붙인다. 메인 액터에서 부른다
public struct UsbCueGridDraftFiles {
    /// 이 곡의 초안 파일이 있거나 쓰기를 기다리는지
    public var cueExists: (String) -> Bool
    public var saveCue: (CueDraft) throws -> Void
    public var gridExists: (String) -> Bool
    public var saveGrid: (GridDraft) throws -> Void

    public init(cueExists: @escaping (String) -> Bool, saveCue: @escaping (CueDraft) throws -> Void,
         gridExists: @escaping (String) -> Bool, saveGrid: @escaping (GridDraft) throws -> Void) {
        self.cueExists = cueExists
        self.saveCue = saveCue
        self.gridExists = gridExists
        self.saveGrid = saveGrid
    }
}

/// USB 큐·그리드 → 로컬 초안(유스케이스). 읽기(`UsbCueGridImportPlan.read`)는 메인 밖에서, 초안 쓰기(`saveDrafts`)는 부르는 쪽이
/// 라이브러리 상태를 확인한 같은 메인 액터 차례에서 한다. rekordbox와 USB에는 쓰지 않는다.
public enum UsbCueGridImport {
    /// 쓴 초안과 결과. 부르는 쪽이 쓴 초안을 화면 상태에 알린다
    public struct Saved {
        public var summary = UsbCueGridImportSummary()
        public var cues: [CueDraft] = []
        public var gridUUIDs: [String] = []
    }

    /// 이미 초안이 있는 곡(`hasDraft`: 앱이 들고 있는 초안·복구 입력, `files`: 파일·쓰기 대기)은 덮지 않고 이유를 남긴다
    public static func saveDrafts(_ plan: UsbCueGridImportPlan, files: UsbCueGridDraftFiles,
                           hasDraft: (String, UsbCueGridDraftImport.Part) -> Bool) -> Saved {
        var saved = Saved()
        for item in plan.rows {
            let uuid = item.row.track.uuid
            var reasons = item.reasons
            if let draft = item.cues, draft.hasChanges {
                if hasDraft(uuid, .cue) || files.cueExists(uuid) {
                    reasons.append(String(ui: "큐 초안이 이미 있으니 먼저 반영하거나 버린 뒤 다시 가져오세요."))
                } else {
                    do {
                        try files.saveCue(draft)
                        saved.cues.append(draft)
                        saved.summary.cueCount += 1
                    } catch { reasons.append(saveFailure) }
                }
            }
            if let draft = item.grid, draft.hasChanges {
                if hasDraft(uuid, .grid) || files.gridExists(uuid) {
                    reasons.append(String(ui: "그리드 초안이 이미 있으니 먼저 반영하거나 버린 뒤 다시 가져오세요."))
                } else {
                    do {
                        try files.saveGrid(draft)
                        saved.gridUUIDs.append(uuid)
                        saved.summary.gridCount += 1
                    } catch { reasons.append(saveFailure) }
                }
            }
            if !reasons.isEmpty {
                saved.summary.skippedCount += 1
                saved.summary.details += reasons.map { item.row.track.title + ": " + $0 }
            }
        }
        saved.summary.skippedCount += plan.unmatchedCount
        if plan.unmatchedCount > 0 {
            saved.summary.details.append(String(ui: "로컬 곡과 짝이 하나로 맞지 않는 \(plan.unmatchedCount)곡은 가져오지 않았으니 원본 라이브러리를 확인하세요."))
        }
        return saved
    }

    private static var saveFailure: String {
        String(ui: "초안을 저장하지 못했으니 DJCrate 데이터 폴더의 쓰기 권한을 확인한 뒤 다시 가져오세요.")
    }
}

/// USB 사본에서 읽은 가져오기 계획: 곡마다 만들 큐·그리드 초안과 건너뛰는 이유(파일은 아직 쓰지 않는다)
public struct UsbCueGridImportPlan: Sendable {
    public struct Row: Sendable {
        public var row: UsbCueGridImportTrack
        public var cues: CueDraft?
        public var grid: GridDraft?
        public var reasons: [String] = []

        public init(row: UsbCueGridImportTrack, cues: CueDraft? = nil, grid: GridDraft? = nil, reasons: [String] = []) {
            self.row = row
            self.cues = cues
            self.grid = grid
            self.reasons = reasons
        }
    }
    public var rows: [Row] = []
    public var unmatchedCount = 0

    public init(rows: [Row] = [], unmatchedCount: Int = 0) {
        self.rows = rows
        self.unmatchedCount = unmatchedCount
    }

    /// USB 사본·로컬 스냅샷 사본·로컬 분석 파일을 읽어 계획한다(메인 스레드 밖). 읽기 전후로 그 자리의 볼륨을 다시 본다.
    /// - rows: 로컬 ContentID → 곡(앱이 읽기 직전에 넘긴 목록 행의 곡·rekordbox 큐)
    /// - engine: USB 사본·로컬 사본·분석 파일 읽기
    /// - device: 이 Mac의 일(USB 사본 지우기, 로컬 분석 파일이 있는지·모양, 스냅샷 시각)
    /// - currentVolume: 그 자리의 볼륨을 다시 본다(앱은 DiskArbitration·statfs, 바뀌었으면 던진다)
    public static func read(volume listed: UsbVolumeInfo, snapshot: URL, share: URL, scratch: URL,
                            rows: [String: UsbCueGridImportTrack], engine: UsbLibraryEngine, device: UsbDevice,
                            currentVolume: (UsbVolumeInfo) throws -> UsbVolumeInfo) throws -> Self {
        let volume = try currentVolume(listed)
        let root = URL(filePath: volume.mountPoint)
        let copy = try engine.read.copyDatabases(root, scratch)
        defer { device.remove(scratch) }
        let one = try copy.oneLibrary.map { try engine.read.oneLibrary($0) }
        let deviceLibrary = try copy.exportPdb.map { try engine.read.deviceLibrary($0, copy.exportExtPdb) }
        guard deviceLibrary?.report.issues.isEmpty != false else {
            throw UsbCueGridDraftImport.issue(String(ui: "Device Library 구조가 맞지 않으니 rekordbox에서 USB를 확인한 뒤 다시 가져오세요."))
        }
        let (library, mismatches) = UsbLibrary.merge(oneLibrary: one, deviceLibrary: deviceLibrary?.library)
        let local = try engine.cueGrid.localKeys(snapshot)
        let snapshotTime = try device.snapshotTime(nil, snapshot).date
        let freshMatches = UsbCueGridDraftImport.uniqueLocalMatches(library: library, local: local)
        var cueRows: Set<Int> = []
        if let url = copy.oneLibrary { cueRows = try engine.cueGrid.deviceCueContentIDs(url) }
        var result = Self()
        for track in library.tracks {
            guard let id = freshMatches[track.id], let row = rows[id], !row.track.isStreaming else {
                result.unmatchedCount += 1
                continue
            }
            var item = Row(row: row)
            let conflicts = mismatches.compactMap { mismatch -> String? in
                switch mismatch {
                case let .trackFieldDiffers(id, field) where id == track.id: return field
                case let .trackOnlyIn(_, id) where id == track.id: return "identity"
                case let .trackPathDiffers(id) where id == track.id: return "identity"
                default: return nil
                }
            }
            if conflicts.contains("identity") || conflicts.contains("masterDbId") || conflicts.contains("masterContentId") {
                item.reasons.append(String(ui: "두 USB 형식의 곡 연결이 다르니 rekordbox에서 USB를 확인한 뒤 다시 가져오세요."))
                result.rows.append(item)
                continue
            }
            let conflictSet = Set(conflicts)
            if conflicts.contains("analysisDataPath") || conflicts.contains("fileType") || conflicts.contains("fileSize") {
                item.reasons.append(String(ui: "두 USB 형식의 분석 파일 정보가 다르니 rekordbox에서 확인한 뒤 다시 가져오세요."))
                result.rows.append(item)
                continue
            }
            do {
                let source = try engine.cueGrid.readTrack(root, track)
                if cueRows.contains(track.id) {
                    item.reasons.append(String(ui: "OneLibrary 기기 큐 행의 해석을 확인하지 못했으니 큐는 rekordbox에서 직접 가져오세요."))
                } else if let reason = UsbCueGridDraftImport.formatConflictReason(.cue, conflicts: conflictSet) {
                    item.reasons.append(reason)
                } else if let cues = source.cues {
                    do {
                        let draft = try UsbCueGridDraftImport.cueDraft(uuid: row.track.uuid, local: row.cues, imported: cues,
                                                                   legacy: source.usesLegacyCues, newID: engine.cueGrid.newCueID)
                        guard draft.issues(duration: Double(row.track.lengthSeconds) + 1).isEmpty,
                              draft.cues.allSatisfy({ ($0.loop?.end ?? $0.time) <= Double(row.track.lengthSeconds) + 1 }) else {
                            throw UsbCueGridDraftImport.issue(String(ui: "큐나 루프 위치가 곡 길이를 벗어나니 rekordbox에서 확인한 뒤 다시 가져오세요."))
                        }
                        item.cues = draft
                    } catch { item.reasons.append(reason(error)) }
                } else if let issue = source.cueIssue { item.reasons.append(issue) }
                if let reason = UsbCueGridDraftImport.formatConflictReason(.grid, conflicts: conflictSet) {
                    item.reasons.append(reason)
                } else if let grid = source.grid {
                    do {
                        guard let dat = engine.cueGrid.analysisURL(row.track.analysisDataPath, share),
                              device.exists(dat), device.exists(dat.deletingPathExtension().appendingPathExtension("EXT")) else {
                            throw UsbCueGridDraftImport.issue(String(ui: "로컬 파형 분석 파일이 없으니 rekordbox에서 곡을 분석한 뒤 그리드를 가져오세요."))
                        }
                        let ext = dat.deletingPathExtension().appendingPathExtension("EXT")
                        guard let datStamp = try device.stat(dat), let extStamp = try device.stat(ext),
                              datStamp.isRegularFile, extStamp.isRegularFile,
                              datStamp.modificationDate <= snapshotTime, extStamp.modificationDate <= snapshotTime else {
                            throw UsbCueGridDraftImport.issue(String(ui: "로컬 분석 파일이 스냅샷 뒤에 바뀌었으니 새 스냅샷을 뜬 뒤 그리드를 가져오세요."))
                        }
                        let localGrid = try engine.cueGrid.localGrid(dat)
                        guard try device.stat(dat) == datStamp, try device.stat(ext) == extStamp else {
                            throw UsbCueGridDraftImport.issue(String(ui: "읽는 동안 로컬 분석 파일이 바뀌었으니 새 스냅샷을 뜬 뒤 그리드를 가져오세요."))
                        }
                        item.grid = try UsbCueGridDraftImport.gridDraft(uuid: row.track.uuid, local: localGrid,
                                                                       imported: grid, duration: Double(row.track.lengthSeconds))
                    } catch { item.reasons.append(reason(error)) }
                } else if let issue = source.gridIssue { item.reasons.append(issue) }
            } catch { item.reasons.append(reason(error)) }
            result.rows.append(item)
        }
        // 사본을 읽는 동안 매체 DB가 바뀌었으면 섞인 시점의 초안을 만들지 않는다.
        guard try engine.cueGrid.databasesUnchanged(copy.fingerprint, root) else {
            throw UsbCueGridDraftImport.issue(String(ui: "읽는 동안 USB 라이브러리가 바뀌었으니 기기 사용을 마친 뒤 다시 가져오세요."))
        }
        _ = try currentVolume(volume)
        return result
    }

    private static func reason(_ error: any Error) -> String {
        (error as? UsbCueGridReadFailure)?.message
            ?? String(ui: "큐나 그리드를 읽지 못했으니 rekordbox에서 이 곡을 확인한 뒤 다시 가져오세요.")
    }
}
