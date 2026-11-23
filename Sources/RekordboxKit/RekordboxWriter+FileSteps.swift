import DJCDomain
import Darwin
import Foundation

/// 초안 쓰기의 커밋 뒤 파일 단계(R10). 분석(그리드 포함)·그림·`masterPlaylists6.xml`의 새 내용은 커밋 전에 준비 폴더
/// `.djc-staging/<대상 키>/`에 만들어 두고, 커밋 뒤에는 이름 바꾸기로 끼우거나 지우기만 한다. 준비 폴더는 바꿀 파일의 루트마다
/// (DB 폴더, 분석 루트) 그 볼륨에 둔다. 곡 분석 폴더와 백업의 `anlz/` 안에는 두지 않는다. 둘 수 없으면 커밋 전에 거절한다.
/// 파일 하나를 바꾸거나 지우기 바로 직전마다 rekordbox·Agent 실행을 다시 본다.
extension RekordboxWriter {
    /// 커밋 뒤 파일 단계 하나
    struct FileStep {
        enum Action {
            /// 준비한 새 내용으로 바꾸거나 새로 만든다
            case place(Data)
            /// 지운다(`cleansFolders`면 비게 된 곡 UUID 폴더도 지운다: 합치기가 지우는 분석·그림 파일)
            case remove(cleansFolders: Bool)
        }

        var target: URL
        var action: Action
        /// 되돌릴 바이트(바꾸거나 지울 파일). nil이면 이 쓰기가 새로 만드는 파일이라 되돌릴 때 지운다
        var original: Data?
        /// 쓰기 기록에 적을 원본 사본(쓰기 전 백업 안). 기록으로 복원이 이 사본으로 되돌린다
        var originalCopy: URL?
        /// 준비 폴더를 둘 루트(분석 루트 또는 DB 폴더)
        var root: URL
        /// 새로 만드는 파일: 이미 있으면 실패한다
        var mustNotExist = false
        /// 이 단계를 마친 뒤 확인(같은 묶음의 마지막 단계가 묶음 전체를 본다)
        var check: (() throws -> Void)?
        /// 파일을 바꾸기 바로 직전 확인(경로에 링크가 생겨 share 밖을 가리키면 바꾸지 않는다)
        var precheck: (() throws -> Void)?
        /// 준비한 새 내용(준비 뒤 채운다)
        var staged: URL?
    }

    // MARK: - 준비

    /// 단계마다 새 내용을 루트의 준비 폴더에 만든다(커밋 전). 준비 폴더를 만들지 못하거나 대상과 볼륨이 다르면 거절한다
    static func stage(_ steps: inout [FileStep], key: RekordboxWriteLockKey) throws {
        let fm = FileManager.default
        var folders: [String: URL] = [:]
        for index in steps.indices {
            guard case let .place(data) = steps[index].action else { continue }
            // 새로 만드는 파일 자리에 이미 파일이 있으면 커밋 전에 멈춘다(기록으로 복원이 그 파일을 이 쓰기가 만든 것으로 보고 지우지 않게)
            if steps[index].mustNotExist, fm.fileExists(atPath: steps[index].target.path) {
                throw DJCError.writeVerificationFailed(String(ui: "파일이 이미 있습니다: \(steps[index].target.lastPathComponent)"))
            }
            let root = steps[index].root
            let folder: URL
            if let made = folders[root.path] {
                folder = made
            } else {
                folder = try makeStagingFolder(root: root, key: key)
                folders[root.path] = folder
            }
            let staged = folder.appending(path: "\(index)-\(steps[index].target.lastPathComponent)", directoryHint: .notDirectory)
            do {
                try data.write(to: staged)
            } catch {
                throw stagingRefusal(root, DJCError.reason(of: error))
            }
            guard sameVolume(folder, steps[index].target) else {
                throw stagingRefusal(root, String(ui: "준비 폴더와 바꿀 파일이 다른 볼륨에 있음"))
            }
            if fm.fileExists(atPath: steps[index].target.path), let mode = try? fm.attributesOfItem(atPath: steps[index].target.path)[.posixPermissions] {
                try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: staged.path)
            }
            steps[index].staged = staged
        }
    }

    static func stagingRefusal(_ root: URL, _ detail: String) -> DJCError {
        .writeRefused(String(ui: "저장할 파일을 미리 만들 준비 폴더를 \(root.path)에 둘 수 없어 저장하지 않았습니다(\(detail)). 그 폴더에 쓸 수 있는지 확인한 뒤 다시 저장하세요"))
    }

    /// 이 대상의 준비 폴더를 비워 새로 만든다(남은 것은 다음 쓰기 전에 지운다)
    static func makeStagingFolder(root: URL, key: RekordboxWriteLockKey) throws -> URL {
        let fm = FileManager.default
        let folder = RekordboxStaging.folder(root: root, key: key)
        try? fm.removeItem(at: folder)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw stagingRefusal(root, DJCError.reason(of: error))
        }
        guard sameVolume(root, folder) else { throw stagingRefusal(root, String(ui: "준비 폴더가 루트와 다른 볼륨에 있음")) }
        return folder
    }

    /// 이 대상의 준비 폴더를 지운다(다른 대상의 준비 폴더는 건드리지 않는다). `.djc-staging`이 비면 그것도 지운다
    static func removeStaging(roots: [URL], key: RekordboxWriteLockKey) {
        let fm = FileManager.default
        for root in Set(roots.map(\.standardizedFileURL)) {
            let folder = RekordboxStaging.folder(root: root, key: key)
            try? fm.removeItem(at: folder)
            let parent = folder.deletingLastPathComponent()
            // 비었을 때만 지운다(rmdir): 다른 대상이 사이에 만든 준비 폴더를 함께 지우지 않게
            rmdir(parent.path)
        }
    }

    /// 두 경로가 같은 볼륨인지(없는 경로는 있는 가장 가까운 조상으로 본다)
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func device(_ url: URL) -> dev_t? {
            var current = url.standardizedFileURL
            while true {
                var info = stat()
                if stat(current.path, &info) == 0 { return info.st_dev }
                let parent = current.deletingLastPathComponent()
                guard parent.path != current.path else { return nil }
                current = parent
            }
        }
        guard let left = device(a), let right = device(b) else { return false }
        return left == right
    }

    // MARK: - 끼우기·되돌리기

    /// 단계를 차례로 한다. 단계마다 바로 직전에 실행을 다시 보고(켜졌으면 멈춘다) 끝 훅을 부른다.
    /// - Parameter performed: 마친 단계 수(실패하면 되돌릴 범위). 단계를 바꾼 뒤 확인이 실패해도 그 단계까지 센다
    static func applyFileSteps(_ steps: [FileStep], run: WriteRun?, performed: inout Int) throws {
        let fm = FileManager.default
        for (index, step) in steps.enumerated() {
            try run?.recheck(.fileReplace)
            try step.precheck?()
            try run?.before(.fileReplace)
            switch step.action {
            case .place:
                guard let staged = step.staged else {
                    throw DJCError.writeVerificationFailed(String(ui: "준비한 파일이 없습니다: \(step.target.lastPathComponent)"))
                }
                if step.mustNotExist, fm.fileExists(atPath: step.target.path) {
                    throw DJCError.writeVerificationFailed(String(ui: "파일이 이미 있습니다: \(step.target.lastPathComponent)"))
                }
                try fm.createDirectory(at: step.target.deletingLastPathComponent(), withIntermediateDirectories: true)
                run?.changed = true
                guard rename(staged.path, step.target.path) == 0 else {
                    throw DJCError.writeVerificationFailed(String(ui: "파일을 바꾸지 못했습니다: \(step.target.lastPathComponent) (\(String(cString: strerror(errno))))"))
                }
            case let .remove(cleansFolders):
                run?.changed = true
                if cleansFolders {
                    try removeOwnedFiles([step.target])
                } else if fm.fileExists(atPath: step.target.path) {
                    try fm.removeItem(at: step.target)
                }
            }
            run?.changed = true
            performed = index + 1
            try step.check?()
            try run?.after(.fileReplace)
        }
    }

    /// 마친 단계를 뒤에서부터 되돌린다(바꾼 파일은 원래 바이트로, 만든 파일은 지운다). 하나가 실패해도 나머지를 해 보고 처음 실패를 던진다.
    /// 되돌리기도 파일을 바꾸므로 바로 직전마다 실행을 다시 본다(켜졌으면 곧바로 멈춘다)
    static func revertFileSteps(_ steps: some Collection<FileStep>, run: WriteRun?) throws {
        let fm = FileManager.default
        var first: (any Error)?
        for step in steps.reversed() {
            do {
                try run?.recheck(.fileReplace)
                // 되돌리기도 경로에 링크가 생겼으면 share 밖에 쓰거나 지우지 않는다
                try step.precheck?()
                if let original = step.original {
                    guard (try? Data(contentsOf: step.target)) != original else { continue }
                    try fm.createDirectory(at: step.target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try original.write(to: step.target, options: .atomic)
                } else if fm.fileExists(atPath: step.target.path) {
                    try removeAnalysisFiles([step.target])
                }
            } catch let error where error is RekordboxRunningSeen || error is RekordboxWriteStop {
                throw error
            } catch {
                first = first ?? error
            }
        }
        if let first { throw first }
    }

    /// 쓰기 기록에 적을 파일 목록(원본 사본이 없으면 새로 만드는 파일)
    static func journalFiles(_ steps: [FileStep]) -> [RekordboxWriteJournal.File] {
        steps.map { RekordboxWriteJournal.File(path: $0.target.path, original: $0.originalCopy?.path) }
    }
}
