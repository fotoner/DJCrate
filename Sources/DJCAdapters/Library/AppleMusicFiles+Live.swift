import AVFoundation
import DJCApplication
import DJCDomain
import DJCStorage
import Foundation

extension AppleMusicFiles {
    /// 이 Mac의 XML 파일과 음원(AVFoundation으로 보호 표시를 본다)
    public static let live = AppleMusicFiles(
        library: { try AppleMusicLibrary.parse(Data(contentsOf: $0)) },
        isReadable: { AppleMusicLibrary.isReadableFile($0) },
        isProtected: { try await AVURLAsset(url: $0).load(.hasProtectedContent) })
}
