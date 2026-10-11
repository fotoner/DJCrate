import DJCApplication
import DJCDomain
import Foundation
import Synchronization

/// rekordbox XML 파일의 메모리 구현: 정해 둔 문서(`put`)와 폴더(`addFolder`)만 있다. 파일 쪽 약속(없는 파일 읽기·자리 종류·내보낼 자리 확인·
/// 추가한 곡 XML 쓰기)은 실제(`XMLFiles.live`)와 같은지 `xmlFilesContract`가 본다. 형식이 필요한 계획·확인·라이브러리 읽기는 쓰지 않는 자리다.
public final class MemoryXMLFiles: Sendable {
    private struct State {
        var documents: [String: XMLLibrary] = [:]
        var folders: Set<String> = []
        var staged: [String: [StagedXMLEntry]] = [:]
    }
    private let state = Mutex(State())

    public init() {}

    public func put(_ library: XMLLibrary, at url: URL) { state.withLock { $0.documents[url.path] = library } }
    public func addFolder(_ url: URL) { state.withLock { _ = $0.folders.insert(url.path) } }
    /// 그 자리에 쓴 추가한 곡 XML의 곡
    public func staged(at url: URL) -> [StagedXMLEntry]? { state.withLock { $0.staged[url.path] } }

    public var files: XMLFiles {
        XMLFiles(
            read: { url in
                guard let library = self.state.withLock({ $0.documents[url.path] }) else { throw XMLReadError(reason: "XML 파일 없음(시험)") }
                return library
            },
            library: { _, _, _ in throw XMLReadError(reason: "메모리 구현은 사본 라이브러리를 읽지 않음") },
            checkOutput: { url in
                guard url.pathExtension.lowercased() == "xml" else { throw LibraryXMLOutputError(reason: "이름은 .xml(시험)") }
                try self.state.withLock { state in
                    guard state.folders.contains(url.deletingLastPathComponent().path) else { throw LibraryXMLOutputError(reason: "폴더 없음(시험)") }
                    if state.folders.contains(url.path) { throw LibraryXMLOutputError(reason: "같은 이름의 폴더(시험)") }
                }
            },
            exportLibrary: { _, _, _, _ in throw XMLReadError(reason: "메모리 구현은 사본 라이브러리를 읽지 않음") },
            item: { url in
                self.state.withLock { state in
                    if state.folders.contains(url.path) { return .directory }
                    return state.documents[url.path] != nil || state.staged[url.path] != nil ? .file : .none
                }
            },
            reflectionPlan: { track, _, _, _ in
                ReflectionXMLPlan(trackID: track.id, uuid: track.uuid, path: track.folderPath, title: track.title, marks: [], tempos: nil,
                                  blockers: [], cueChanged: false, gridChanged: false, before: ReflectionXMLMetadata(track), beforeMarks: [])
            },
            verifyReflection: { _, _, _, _ in ReflectionXMLCheck(result: .notYet, problems: []) },
            writeReflection: { _, _, _ in },
            writeStaged: { entries, _, out in self.state.withLock { $0.staged[out.path] = entries } })
    }
}
