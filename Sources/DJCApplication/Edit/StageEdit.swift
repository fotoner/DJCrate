import DJCDomain
import Foundation

/// 편집본 넣기가 파일에 하는 것(포트): 렌더한 파일의 태그 읽기, 곡 하나의 초안 파일 쓰기와 되돌리기.
/// 실제 구현(`.live`)은 DJCAdapters가 주고 조립 지점이 고른다. 메인 스레드 밖에서 불린다.
public struct EditStagingFiles: Sendable {
    /// 렌더한 파일의 태그로 추가할 곡 하나를 만든다(새 UUID, 둘째 값은 추가한 날 `yyyy-MM-dd`)
    public var readTrack: @Sendable (URL, String) async throws -> StagedTrack
    /// 곡 하나의 초안(그리드·큐·태그)을 쓴다. 중간에 실패하면 이 쓰기가 바꾼 파일을 되돌리고 던진다.
    /// 돌려준 되돌리기는 뒤 단계(추가 목록 저장)가 실패했을 때 부른다(전에 있던 파일은 그 내용으로 되살린다, #174).
    public var writeDrafts: @Sendable (StagedEditDrafts) throws -> @Sendable () -> Void

    public init(readTrack: @escaping @Sendable (URL, String) async throws -> StagedTrack,
                writeDrafts: @escaping @Sendable (StagedEditDrafts) throws -> @Sendable () -> Void) {
        self.readTrack = readTrack
        self.writeDrafts = writeDrafts
    }
}

/// 편집본 넣기(유스케이스): 렌더한 편집본(곡 편집·Flip)을 "추가한 곡"에 넣고 그리드·큐·태그 초안을 둔다(`StagedEditDrafts`).
/// 이미 추가한 파일이면 막는다. 초안을 쓴 뒤 추가 목록 저장이 실패하면 이 넣기가 만든 초안을 되돌린다.
/// 추가 목록은 `StagingStore` 한 길로 메인 액터에서 고친다(화면이 든 목록 저장과 겹쳐 줄을 잃지 않게, adv2 N8).
public struct StageEdit: Sendable {
    public var staging: StagingStore
    public var files: EditStagingFiles
    public var now: @Sendable () -> Date

    public init(staging: StagingStore, files: EditStagingFiles, now: @escaping @Sendable () -> Date) {
        self.staging = staging
        self.files = files
        self.now = now
    }

    @concurrent
    public func stage(_ request: EditStagingRequest) async throws -> StagedTrack {
        let path = request.file.path
        guard await !staging.contains(path: path) else { throw Self.refused(request.file) }
        let addedOn = String(ISO8601DateFormatter().string(from: now()).prefix(10))
        let read = try await files.readTrack(request.file, addedOn)
        let drafts = StagedEditDrafts(track: read, grid: request.grid, cues: request.cues, source: request.source, title: request.title)
        let rollBack = try files.writeDrafts(drafts)
        do {
            try await append(drafts.track)
        } catch {
            rollBack()
            throw error
        }
        return drafts.track
    }

    /// 지금 목록에 덧붙여 저장한다(기다리는 사이 같은 파일을 넣었으면 막는다)
    @MainActor
    private func append(_ track: StagedTrack) throws {
        try staging.update { list in
            let key = track.path.precomposedStringWithCanonicalMapping
            guard !list.contains(where: { $0.path.precomposedStringWithCanonicalMapping == key }) else {
                throw Self.refused(URL(filePath: track.path))
            }
            list.append(track)
        }
    }

    static func refused(_ file: URL) -> DJCError {
        DJCError.editRefused(String(ui: "\(file.lastPathComponent)은 이미 추가한 곡입니다. 추가 목록에서 확인하세요"))
    }
}
