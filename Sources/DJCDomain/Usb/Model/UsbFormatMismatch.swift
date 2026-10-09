import Foundation

/// 한 USB의 두 형식(OneLibrary·Device Library)이 서로 맞지 않는 곳
public enum UsbFormatMismatch: Sendable, Hashable {
    case trackOnlyIn(UsbFormat, id: Int)
    case trackPathDiffers(id: Int)
    case trackFieldDiffers(id: Int, field: String)
    /// 맨 위에서 닿지 않는 목록(id = 대표 번호)
    case playlistConflict(id: Int)
    case playlistEntriesDiffer(id: Int)
    case playlistOnlyIn(UsbFormat, id: Int)
    case propertyDiffers(field: String)
    /// 같은 id 행의 두 형식 모두 칸이 다르거나, 공유 표(artist·album·menuItem 등) 행이 한 형식에만 있다
    case sharedRowDiffers(table: String, id: Int)

    /// 곡이 한 형식에만 있거나 같은 id가 다른 파일을 가리키면, 고쳐 쓸 때 한쪽 곡을 잃을 수 있어 편집을 막는다.
    /// 맨 위에서 닿지 않는 목록(없는 부모·고리·한 형식 안 번호 중복)은 대표 번호와 부모를 정할 수 없어(`UsbPlaylistPairing`),
    /// 고쳐 쓰면 그 목록이 다른 자리로 갈 수 있다.
    public var blocksEditing: Bool {
        switch self {
        case .trackOnlyIn, .trackPathDiffers, .playlistConflict: true
        default: false
        }
    }
}
