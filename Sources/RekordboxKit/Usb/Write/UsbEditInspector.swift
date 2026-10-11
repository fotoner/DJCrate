import DJCDomain
import Foundation

/// USB 수정의 쓰기 전 확인(A 단계)을 한 번 더: 계획을 세운 뒤 쓰기 전까지 USB가 편집할 수 있는 모양 그대로인지 본다.
/// 계획 base가 같은지는 쓰기 절차가 보고(`usbChanged`), 여기서는 형식 조건을 본다.
/// ① 수정은 있던 DB만 바꾼다(없는 DB를 새로 만들면 내보내기가 된다)
/// ② Device Library를 바꾸면 두 pdb 머리 0x10 = 5(rekordbox가 정상으로 닫은 파일)
public struct UsbEditInspector: UsbWriteInspector {
    public init() {}

    public func blocks(root: UsbRoot, changes: UsbChangeSet) throws -> [UsbBlock] {
        guard changes.purpose == .edit else { return [] }
        var blocks: [UsbBlock] = []
        for database in changes.databases {
            guard try Self.fileSize(root, database.destination) == nil else { continue }
            blocks.append(UsbBlock(code: "editCreatesDatabase", scope: .file(database.destination),
                                   message: String(ui: "USB 수정은 있던 라이브러리 파일만 바꿉니다. USB를 다시 읽은 뒤 고치세요")))
        }
        if changes.databases.contains(where: { $0.format == .deviceLibrary }) {
            for path in [UsbLayout.exportPdb, UsbLayout.exportExtPdb] {
                guard let flag = try Self.headerFlag(root, path), flag != PdbVerifier.closedFlag else { continue }
                blocks.append(UsbBlock(code: "pdbNotClosed", scope: .format(.deviceLibrary),
                                       message: String(ui: "rekordbox에 이 USB를 연결했다가 정상적으로 꺼낸 뒤 다시 시도하세요")))
                break
            }
        }
        return blocks
    }

    /// 일반 파일의 크기(없으면 nil). 링크를 거치거나 열지 않는 경로면 던진다
    static func fileSize(_ root: UsbRoot, _ relative: String) throws -> Int64? {
        let url = try root.url(for: relative)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    /// pdb 파일 머리 0x10(u32 LE). 없거나 짧으면 nil
    static func headerFlag(_ root: UsbRoot, _ relative: String) throws -> UInt32? {
        guard try fileSize(root, relative) != nil, let handle = FileHandle(forReadingAtPath: try root.url(for: relative).path) else { return nil }
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 0x14), head.count == 0x14 else { return nil }
        return head[head.startIndex + 0x10..<head.startIndex + 0x14].enumerated()
            .reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }
}
