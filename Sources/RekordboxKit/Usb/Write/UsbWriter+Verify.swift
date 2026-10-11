import DJCDomain
import Foundation

/// G 검증: 검증기를 차례로 부른다. 건너뛴 지우기는 목표에서 뺀다(남긴 것이 맞다).
extension UsbWriteRun {
    func verify(_ changes: UsbChangeSet, verifiers: [any UsbWriteVerifier]) throws {
        try ensureSameVolume()
        emit(.verify, total: verifiers.count, cancellable: false)
        var effective = changes
        let skipped = Set(journal.removals.filter { $0.state == .skipped }.map(\.path))
        effective.target.mustNotExist.subtract(skipped)
        let scratch = paths.staging.appending(path: changes.session + "-verify")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        var problems: [String] = []
        for verifier in verifiers {
            problems += try verifier.verify(root: root, changes: effective, fileSystem: fs, scratch: scratch)
        }
        problems += try UsbSyncSelectionVerifier().verify(root: root, changes: effective, fileSystem: fs, scratch: scratch)
        if options.verifyAudio {
            let audio = Set(changes.copies.filter { $0.disposition == .create }.map(\.destination))
            for entry in journal.entries where audio.contains(entry.destination) && entry.state == .done {
                if try fs.sha256(usb(entry.destination), uncached: true) != entry.newSHA256 {
                    problems.append("sha256: \(entry.destination)")
                }
            }
        }
        if !problems.isEmpty { throw UsbWriteFailure.failed("verification: " + problems.joined(separator: ", ")) }
    }
}
