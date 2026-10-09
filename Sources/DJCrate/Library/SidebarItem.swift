import DJCDomain

/// 사이드바에서 고르는 대상: 라이브러리 필터 또는 rekordbox 플레이리스트·폴더.
enum SidebarItem: Hashable, Sendable {
    case filter(LibraryFilter)
    case playlist(String)
    case itunesPlaylist(String)
    case history(String)
    case duplicates
    /// DJCrate에 추가한 곡(아직 rekordbox에 없음)
    case staged
    /// 큐·그리드 초안이 있어 rekordbox에 반영할 곡
    case pending
    /// 연결한 USB의 컬렉션·재생 목록(읽기 전용)
    case usb(UsbSidebarTarget)
}
