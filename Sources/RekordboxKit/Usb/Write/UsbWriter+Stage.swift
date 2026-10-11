import DJCDomain
import Foundation

/// B 준비: 준비 폴더 파일이 변경 묶음과 같은지 보고 저널을 새로 만든다(볼륨마다 하나라 닫힌 옛 저널을 덮는다)
extension UsbWriteRun {
    func stage(_ changes: UsbChangeSet, plan: Plan) throws {
        var blocks: [UsbBlock] = []
        func changed(_ path: String) {
            blocks.append(UsbBlock(code: "stagedChanged", scope: .file(path),
                                   message: String(ui: "준비한 파일이 바뀌었거나 없습니다. 다시 미리 보기한 뒤 쓰세요")))
        }
        func matches(_ path: String, _ size: Int64, _ sha256: String) throws -> Bool {
            let url = URL(filePath: path)
            guard let info = try fs.stat(url), info.kind == .file, info.size == size else { return false }
            return try fs.sha256(url, uncached: false) == sha256
        }
        for write in changes.writes where write.disposition != .reuse {
            if try !matches(write.staged, write.size, write.sha256) { changed(write.destination) }
        }
        for database in changes.databases {
            if try !matches(database.staged, database.size, database.sha256) { changed(database.destination) }
        }
        for copy in changes.copies where copy.disposition != .reuse {
            // 음원은 여기서 해시하지 않는다(복사하며 SHA-1을 본다)
            guard let info = try fs.stat(URL(filePath: copy.source)), info.kind == .file, info.size == copy.size else {
                changed(copy.destination)
                continue
            }
        }
        if !blocks.isEmpty { throw UsbError.writeRefused(blocks) }

        journal = UsbJournal(changes: changes, volumeUUID: volumeKey, volumeName: volume.name, now: now)
        journal.plannedDatabases = plan.databases
        journal.removals = changes.removals.map { UsbJournal.RemovalEntry(path: $0.path, state: .pending) }
        try journal.move(to: .staged)
        try saveJournal()
    }
}
