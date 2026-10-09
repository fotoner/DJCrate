import DJCDomain
import DJCStorage
import Foundation
import Testing

@Suite("USB 실험 경로 제한")
struct UsbScratchPathTests {
    /// 임시 폴더 하나를 만들고 끝나면 지운다.
    func withFolder(under parent: String = NSTemporaryDirectory(), _ body: (String) throws -> Void) throws {
        let folder = (parent as NSString).appendingPathComponent("djc-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try body(folder)
    }

    func reason(_ path: String, _ kind: UsbScratchPath.Kind) -> String? {
        do {
            _ = try UsbScratchPath.check(path, as: kind)
            return nil
        } catch let UsbError.pathRefused(_, reason) {
            return reason
        } catch {
            return "other: \(error)"
        }
    }

    @Test("/tmp와 /private/tmp는 같은 실제 경로로 받는다")
    func tmpAndPrivateTmpBothAccepted() throws {
        try withFolder(under: "/private/tmp") { folder in
            let name = (folder as NSString).lastPathComponent
            let short = try UsbScratchPath.check("/tmp/" + name, as: .existingDirectory)
            let full = try UsbScratchPath.check("/private/tmp/" + name, as: .existingDirectory)
            #expect(short == "/private/tmp/" + name)
            #expect(full == short)
            #expect(try UsbScratchPath.check("/tmp/" + name + "/new.img", as: .newFile) == "/private/tmp/" + name + "/new.img")
        }
    }

    @Test("macOS 임시 폴더를 받는다")
    func temporaryDirectoryAccepted() throws {
        try withFolder { folder in
            let resolved = try UsbScratchPath.check(folder, as: .existingDirectory)
            #expect(resolved.hasPrefix("/private/var/folders/"))
        }
    }

    @Test("Foundation 경로 정규화를 쓰지 않는다")
    func foundationNormalizationNotUsed() throws {
        try withFolder { folder in
            FileManager.default.createFile(atPath: folder + "/a.img", contents: Data("img".utf8))
            let resolved = try UsbScratchPath.check(folder + "/a.img", as: .existingFile)
            // resolvingSymlinksInPath는 /private를 떼어 statfs 마운트 지점과 어긋난다.
            #expect(resolved.hasPrefix("/private/"))
            #expect(UsbScratchPath.realPath(folder) == resolved.replacingOccurrences(of: "/a.img", with: ""))
        }
    }

    @Test func symlinkLeafRejected() throws {
        try withFolder { folder in
            FileManager.default.createFile(atPath: folder + "/real.img", contents: Data())
            try FileManager.default.createSymbolicLink(atPath: folder + "/link.img", withDestinationPath: folder + "/real.img")
            #expect(reason(folder + "/link.img", .existingFile) == "symlink")
            #expect(reason(folder + "/link.img", .newFile) == "symlink")
        }
    }

    @Test("임시 폴더 안 링크가 밖을 가리키면 거부")
    func symlinkParentPointingOutsideRejected() throws {
        try withFolder { folder in
            try FileManager.default.createSymbolicLink(atPath: folder + "/home", withDestinationPath: NSHomeDirectory())
            #expect(reason(folder + "/home/djc-never-created-\(UUID().uuidString).img", .newFile) == "outsideScratch")
        }
    }

    @Test func devNodeRejected() {
        #expect(reason("/dev/null", .existingFile) == "notRegular")
    }

    @Test func volumesRejected() {
        #expect(reason("/Volumes", .existingDirectory) != nil)
        #expect(UsbScratchPath.deniedPrefixes().contains("/Volumes"))
        #expect(UsbScratchPath.deniedPrefixes().contains("/dev"))
    }

    @Test("rekordbox 라이브러리 폴더는 거부(만들지 않는다)")
    func pioneerLibraryRejected() {
        let path = NSHomeDirectory() + "/Library/Pioneer/djc-never-created.img"
        #expect(reason(path, .newFile) != nil)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func homeRejected() {
        #expect(reason(NSHomeDirectory(), .existingDirectory) == "outsideScratch")
    }

    @Test("출력 폴더는 임시 폴더 밖이면 목록을 읽기 전에 거부한다")
    func outputDirectoryOutsideScratchRejectedBeforeListing() {
        // 비었는지 보려고 폴더를 열면 USB 볼륨 맨 위를 열거하게 된다. 뿌리 확인이 먼저다.
        #expect(reason(NSHomeDirectory(), .outputDirectory) == "outsideScratch")
        #expect(reason("/Volumes", .outputDirectory) == "outsideScratch")
    }

    @Test func newFileMustNotExist() throws {
        try withFolder { folder in
            FileManager.default.createFile(atPath: folder + "/a.img", contents: Data())
            #expect(reason(folder + "/a.img", .newFile) == "exists")
            #expect(reason(folder + "/b.img", .newFile) == nil)
        }
    }

    @Test func newFileNeedsParent() throws {
        try withFolder { folder in
            #expect(reason(folder + "/none/b.img", .newFile) == "noParent")
            #expect(reason(folder + "/none/out", .outputDirectory) == "noParent")
        }
    }

    @Test func outputDirectoryMustBeEmpty() throws {
        try withFolder { folder in
            #expect(reason(folder, .outputDirectory) == nil)
            #expect(reason(folder + "/new", .outputDirectory) == nil)
            FileManager.default.createFile(atPath: folder + "/a", contents: Data())
            #expect(reason(folder, .outputDirectory) == "notEmpty")
        }
    }

    @Test func kindMismatchRejected() throws {
        try withFolder { folder in
            FileManager.default.createFile(atPath: folder + "/a.img", contents: Data())
            #expect(reason(folder, .existingFile) == "kindMismatch")
            #expect(reason(folder + "/a.img", .existingDirectory) == "kindMismatch")
            #expect(reason(folder + "/a.img", .outputDirectory) == "kindMismatch")
            #expect(reason(folder + "/none.img", .existingFile) == "notFound")
        }
    }
}
