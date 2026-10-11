import Foundation
import RekordboxKit
import Testing

@Suite("임시 폴더 뿌리")
struct UsbScratchRootsTests {
    @Test("realpath는 /private를 붙인 실제 경로를 낸다")
    func realPathResolvesPrivate() throws {
        let name = "djc-roots-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: "/private/tmp/" + name, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: "/private/tmp/" + name) }
        #expect(UsbScratchRoots.realPath("/tmp/" + name) == "/private/tmp/" + name)
        #expect(UsbScratchRoots.realPath("/tmp/" + name + "/") == "/private/tmp/" + name)
        #expect(UsbScratchRoots.realPath("/tmp/" + name + "/none") == nil)
    }

    @Test("허용 뿌리는 모두 realpath 결과")
    func allowedRootsAreRealPaths() {
        let roots = UsbScratchRoots.allowedRoots()
        #expect(roots.allSatisfy { UsbScratchRoots.realPath($0) == $0 })
        #expect(roots.contains("/private/tmp"))
        #expect(roots.contains("/private/var/folders"))
        #expect(Set(roots).count == roots.count)
        if let temp = UsbScratchRoots.realPath(NSTemporaryDirectory()) {
            #expect(UsbScratchRoots.isUnderAllowedRoot(temp))
        }
    }

    @Test("뿌리 아래인지는 성분 경계로 본다")
    func isUnderAllowedRoot() {
        #expect(UsbScratchRoots.isUnderAllowedRoot("/private/tmp/x"))
        #expect(UsbScratchRoots.isUnderAllowedRoot("/private/tmp"))
        #expect(!UsbScratchRoots.isUnderAllowedRoot("/private/tmpx"))
        #expect(!UsbScratchRoots.isUnderAllowedRoot("/Volumes/X"))
        #expect(!UsbScratchRoots.isUnderAllowedRoot("/Library/DJCNotScratch"))
        #expect(!UsbScratchRoots.isUnderAllowedRoot("/tmp/x"))
    }

    @Test("임시 폴더는 마운트 지점이 아니다")
    func mountedOnTempFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mount = try #require(UsbScratchRoots.mountedOn(folder.path))
        #expect(mount != UsbScratchRoots.realPath(folder.path))
        #expect(mount.hasPrefix("/"))
        #expect(UsbScratchRoots.mountedOn(folder.path + "/none") == nil)
    }
}
