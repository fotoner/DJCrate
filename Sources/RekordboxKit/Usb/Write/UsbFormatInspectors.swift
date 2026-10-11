import DJCDomain
import Foundation

/// 빈 USB 내보내기의 쓰기 전 확인(A 단계)을 한 번 더: 계획을 세운 뒤 쓰기 전까지 USB가 바뀌지 않았는지 본다(두 겹).
/// ① `PIONEER/` 바로 아래 이름(`.`으로 시작하는 macOS 항목 빼고)이 0개 — 이름만 세고 아래로 내려가지 않는다(열지 않는 경로 포함)
/// ② 만들 대상과 충돌 키가 같은 이름이 없음(`UsbWriter.createCollisionBlocks`, 사용자 파일을 조용히 덮지 않게)
public struct UsbEmptyVolumeInspector: UsbWriteInspector {
    public init() {}

    public func blocks(root: UsbRoot, changes: UsbChangeSet) throws -> [UsbBlock] {
        var blocks: [UsbBlock] = []
        if Self.pioneerNames(root) > 0 { blocks.append(Self.leftoverBlock) }
        blocks += try UsbWriter.createCollisionBlocks(changes, root: root)
        return blocks
    }

    public static var leftoverBlock: UsbBlock {
        UsbBlock(code: "leftoverPioneer", scope: .volume,
                 message: String(ui: "USB의 PIONEER 폴더에 다른 파일이 남아 있습니다. 빈 USB를 쓰거나 PIONEER 폴더를 비운 뒤 다시 시도하세요"))
    }

    /// `PIONEER/`(철자 무관) 바로 아래 이름 수. 폴더가 아니면 1(그 이름 자체가 남은 것)
    public static func pioneerNames(_ root: UsbRoot) -> Int {
        let fm = FileManager.default
        guard let name = ((try? fm.contentsOfDirectory(atPath: root.url.path)) ?? [])
            .first(where: { UsbLayout.collisionKey($0) == UsbLayout.collisionKey("PIONEER") }) else { return 0 }
        let url = root.url.appending(path: name)
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue,
              (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil else { return 1 }
        return ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }.count
    }
}
