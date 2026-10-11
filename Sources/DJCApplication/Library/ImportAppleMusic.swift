import DJCDomain
import Foundation

/// Music·iTunes 보관함 XML과 그 음원(포트). 실제 구현은 DJCAdapters(`AppleMusicFiles.live`).
public struct AppleMusicFiles: Sendable {
    /// 보관함·재생 목록 XML을 읽는다(음원 파일을 읽을 수 있는지도 본다). 읽지 못하면 던진다
    public var library: @Sendable (URL) throws -> AppleMusicLibrary
    /// 음원 파일을 읽을 수 있는지
    public var isReadable: @Sendable (URL) -> Bool
    /// 보호된(DRM) 음원인지. 읽지 못하면 던진다
    public var isProtected: @Sendable (URL) async throws -> Bool

    public init(library: @escaping @Sendable (URL) throws -> AppleMusicLibrary, isReadable: @escaping @Sendable (URL) -> Bool,
                isProtected: @escaping @Sendable (URL) async throws -> Bool) {
        self.library = library
        self.isReadable = isReadable
        self.isProtected = isProtected
    }
}

/// Music XML에서 곡 가져오기(유스케이스): 내보낸 보관함 XML을 읽고, 고른 곡이 지금 넣을 수 있는 파일인지 다시 본다.
/// 넣기는 추가한 곡(`StageTracks`)이 Apple Music 출처와 함께 한다.
public struct ImportAppleMusic: Sendable {
    let files: AppleMusicFiles

    public init(files: AppleMusicFiles) {
        self.files = files
    }

    /// 보관함 XML을 메인 밖에서 읽는다. 보관함 ID가 없는 재생 목록 XML도 같은 파일을 다시 열면 같은 출처로 잇는다
    public func open(_ url: URL) async throws -> AppleMusicLibrary {
        var library = try await LoadLibrary.background { [files] in try files.library(url) }
        if library.id == nil { library.id = "xml:\(url.standardizedFileURL.path)" }
        return library
    }

    /// 지금 넣을 수 없는 이유(XML을 내보낸 뒤 파일이 바뀌었거나 보호 표시가 빠진 경우도 실제 파일에서 본다). 넣을 수 있으면 nil
    public func exclusion(for url: URL) async -> AppleMusicLibrary.Exclusion? {
        guard files.isReadable(url) else { return .unavailableFile }
        do { return try await files.isProtected(url) ? .protectedContent : nil } catch { return .unavailableFile }
    }
}
