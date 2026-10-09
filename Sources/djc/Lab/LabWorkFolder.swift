import DJCApplication
import DJCDomain
import DJCEnvironment
import Foundation
import RekordboxKit

/// 재현 실험(`loop-repro`·`vbr-cue-repro`·`playlist-repro`)이 통째로 지우고 다시 만드는 `--work` 폴더.
/// USB 실험 도구(`UsbScratchPath`)와 같은 규칙: 임시 폴더(`UsbScratchRoots`) 아래만 받는다.
/// 임시 폴더 안이어도 뿌리 자체와 rekordbox 폴더·DJCrate 데이터 폴더를 품거나 그 안인 폴더는 받지 않는다(시험 프로세스는 둘 다 임시 폴더다).
enum LabWorkFolder {
    static var protectedFolders: [URL] {
        let location = CLIComposition.live.location
        return [location.rekordboxDirectory, location.draftHome, location.snapshotDirectory, location.backupDirectory,
                DJCIdentity.dataDirectory, DJCIdentity.supportDirectory, DJCIdentity.userSupportDirectory,
                FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Pioneer")]
    }

    /// 지워도 되는 작업 폴더인지 본다. 통과하면 링크를 푼 실제 경로를 돌려준다(지우는 것도 이 경로다)
    @discardableResult
    static func check(_ path: String, protected: [URL] = protectedFolders) throws -> URL {
        guard let resolved = resolve(path) else {
            throw CLIGuards.Refusal("실험 작업 폴더 경로를 풀 수 없습니다. --work에 mktemp -d로 만든 폴더 아래 경로를 주세요")
        }
        let roots = UsbScratchRoots.allowedRoots()
        guard UsbScratchRoots.isUnderAllowedRoot(resolved),
              !roots.contains(where: { contains(resolved, $0) }) else {
            throw CLIGuards.Refusal("실험 작업 폴더는 통째로 지워지므로 임시 폴더 아래만 받습니다. --work에 mktemp -d로 만든 폴더 아래 경로를 주세요")
        }
        for folder in protected {
            guard let guarded = resolve(folder.path) else { continue }
            if contains(resolved, guarded) || contains(guarded, resolved) {
                throw CLIGuards.Refusal("실험 작업 폴더는 통째로 지워지므로 rekordbox 폴더·DJCrate 데이터 폴더와 겹치면 받지 않습니다. --work에 mktemp -d로 만든 새 폴더를 주세요")
            }
        }
        return URL(filePath: resolved)
    }

    /// 판정을 지난 작업 폴더를 비우고 다시 만든다
    static func reset(_ path: String, attributes: [FileAttributeKey: Any]? = nil, protected: [URL] = protectedFolders) throws -> URL {
        let folder = try check(path, protected: protected)
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: attributes)
        return folder
    }

    /// `outer`가 `inner`와 같거나 그 위 폴더인지(둘 다 realpath 결과)
    private static func contains(_ outer: String, _ inner: String) -> Bool {
        inner == outer || inner.hasPrefix(outer == "/" ? "/" : outer + "/")
    }

    /// 있는 가장 가까운 조상을 realpath(3)로 풀고 나머지 성분을 붙인다. `.`·`..`가 남으면 nil
    private static func resolve(_ path: String) -> String? {
        let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        var head = absolute, tail: [String] = []
        while true {
            if let real = UsbScratchRoots.realPath(head) {
                guard !tail.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
                return tail.isEmpty ? real : ([real == "/" ? "" : real] + tail.reversed()).joined(separator: "/")
            }
            let name = (head as NSString).lastPathComponent
            let parent = (head as NSString).deletingLastPathComponent
            guard !name.isEmpty, parent != head else { return nil }
            tail.append(name)
            head = parent
        }
    }
}
