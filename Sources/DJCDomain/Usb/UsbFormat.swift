import Foundation

/// USB 라이브러리 형식. rekordbox 7은 한 USB에 둘을 함께 쓴다.
public enum UsbFormat: String, CaseIterable, Codable, Sendable, Hashable {
    /// OneLibrary: `PIONEER/rekordbox/exportLibrary.db`(SQLCipher)
    case oneLibrary
    /// Device Library: `PIONEER/rekordbox/export.pdb` + `exportExt.pdb`(CDJ-2000 등 옛 기기)
    case deviceLibrary

    /// 첫 판 기본: 둘 다(rekordbox 7.2.18과 같게)
    public static let defaultSet: Set<UsbFormat> = [.oneLibrary, .deviceLibrary]
}
