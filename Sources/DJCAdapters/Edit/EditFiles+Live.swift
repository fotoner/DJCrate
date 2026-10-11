import DJCAnalysis
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation

extension EditFiles {
    /// 편집본은 `output`(앱은 음악 폴더의 DJCrate 편집본, `DJC_HOME`을 주면 그 아래 edits)에 둔다. 부를 때마다 읽는다.
    public static func live(output: @escaping @Sendable () -> URL) -> EditFiles {
        EditFiles(
            outputDirectory: output,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
            removeFile: { try? FileManager.default.removeItem(at: $0) },
            render: { job, output, progress in
                switch job.plan {
                case .bars(let edit):
                    _ = try EditRenderer.render(edit, source: job.source, sourceOffset: job.sourceOffset, to: output, progress: progress)
                case .flip(let flip):
                    _ = try EditRenderer.render(flip, source: job.source, sourceOffset: job.sourceOffset, to: output, progress: progress)
                }
            })
    }
}

extension EditStagingFiles {
    /// 렌더한 파일의 태그를 읽고(`StagedTrack.make`), 초안은 초안 폴더 `home`에 쓴다(`EditStaging`).
    public static func live(home: URL) -> EditStagingFiles {
        EditStagingFiles(
            readTrack: { try await StagedTrack.make(fileAt: $0, addedOn: $1) },
            writeDrafts: { try EditStaging.writeDrafts($0, home: home) })
    }
}

extension StageEdit {
    /// 파일만 쓰는 편집본 넣기: 추가 목록은 `home`의 `staged.json`을 바로 읽고 쓴다. 화면이 추가 목록을 들고 있지 않은 곳(CLI 실험·시험)이 쓴다.
    /// 앱은 추가 목록 화면이 든 목록과 디스크를 함께 맞추는 `StagingStore`를 조립 지점이 넣는다.
    public static func files(home: URL, now: @escaping @Sendable () -> Date = { Date() }) -> StageEdit {
        StageEdit(staging: .live(home: home), files: .live(home: home), now: now)
    }
}
