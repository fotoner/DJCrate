import DJCDomain
import Foundation

/// 렌더한 편집본(곡 편집·Flip)을 "추가한 곡"에 넣을 때 쓰는 초안 파일(그리드·큐·태그).
/// 무엇을 둘지는 `StagedEditDrafts`(DJCDomain), 넣는 순서·중복 확인·추가 목록 저장은 유스케이스 `StageEdit`(DJCApplication)이 정한다.
public enum EditStaging {
    /// 곡 하나의 초안을 초안 폴더 `home`에 쓴다. 중간에 실패하면 이 쓰기가 바꾼 파일을 되돌리고 던진다.
    /// - Returns: 되돌리기. 뒤 단계(추가 목록 저장)가 실패하면 부른다(전에 있던 파일은 그 내용으로 되살린다, #174)
    public static func writeDrafts(_ drafts: StagedEditDrafts, home: URL) throws -> @Sendable () -> Void {
        let uuid = drafts.track.uuid
        let grids = home.appending(path: "grid-drafts"), cueDirectory = home.appending(path: "cue-drafts")
        let tagDirectory = home.appending(path: "tag-drafts")
        var touched = Touched()
        do {
            if let grid = drafts.grid {
                try touched.remember(grids.appending(path: "\(uuid).json"))
                try GridDraftStore.save(grid, directory: grids)
            }
            try touched.remember(cueDirectory.appending(path: "\(uuid).json"))
            try CueDraftStore.save(drafts.cues, directory: cueDirectory)
            try touched.remember(tagDirectory.appending(path: "\(uuid).json"))
            try TagDraftStore.save(drafts.tags, directory: tagDirectory)
        } catch {
            touched.rollBack()
            throw error
        }
        let done = touched
        return { done.rollBack() }
    }

    /// 넣기가 바꾼 초안 파일과 그 전 내용(nil이면 없던 파일)
    struct Touched: Sendable {
        private var files: [(url: URL, previous: Data?)] = []

        /// 바꾸기 전 내용을 적어 둔다. 있던 파일을 읽지 못하면 되돌릴 수 없으므로 바꾸지 않는다.
        mutating func remember(_ url: URL) throws {
            let previous = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            files.append((url, previous))
        }

        func rollBack() {
            for file in files.reversed() {
                if let previous = file.previous { try? previous.write(to: file.url, options: .atomic) }
                else { try? FileManager.default.removeItem(at: file.url) }
            }
        }
    }
}
