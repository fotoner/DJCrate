import DJCDomain
import Foundation

/// WAL 형식 DB는 읽기 전용으로 열어도 곁에 공유 메모리를 만든다. 쓰기 전 확인과 커밋 뒤 검증은 각각 새 사본에서 읽는다.
final class WriteReadSnapshot {
    let db: CipherDatabase
    private var folder: URL?

    init(_ database: URL) throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "djc-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
        self.folder = folder
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let source = database.resolvingSymlinksInPath()
            let wal = URL(filePath: source.path + "-wal")
            let dbBefore = RekordboxWriter.fileStamp(source), walBefore = RekordboxWriter.fileStamp(wal)
            let copy = folder.appending(path: "master.db")
            try Self.copyRegularFile(source, to: copy)
            if let walBefore, walBefore.size > 0 {
                try Self.copyRegularFile(wal, to: URL(filePath: copy.path + "-wal"))
            }
            guard dbBefore != nil, dbBefore == RekordboxWriter.fileStamp(source), walBefore == RekordboxWriter.fileStamp(wal) else {
                throw DJCError.sourceChangedDuringCopy(path: source.path)
            }
            // 체크포인트로 DB 페이지를 덮기 전의 바이트를 검증한다. SQLite가 사본의 WAL에서 최신 값을 읽는다.
            db = try CipherDatabase(path: copy.path, key: RekordboxKey.derive())
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    /// 원본의 곁 파일을 직접 열지 않도록 복사된 링크는 거부한다.
    private static func copyRegularFile(_ source: URL, to copy: URL) throws {
        let fm = FileManager.default
        try fm.copyItem(at: source, to: copy)
        guard try fm.attributesOfItem(atPath: copy.path)[.type] as? FileAttributeType == .typeRegular else {
            throw DJCError.sourceChangedDuringCopy(path: source.path)
        }
    }

    func close() {
        guard let folder else { return }
        self.folder = nil
        db.close()
        try? FileManager.default.removeItem(at: folder)
    }
}
