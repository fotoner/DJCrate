import DJCDomain
import Foundation

extension UsbRead {
    /// 곡마다 두 DB가 가리키는 음원(같은 경로는 한 번)이 일반 파일로 있는지
    static func media(oneLibrary: UsbLibrary?, deviceLibrary: UsbLibrary?, isRegularFile: (String) -> Bool) -> UsbInfo.Media {
        let tracks = (oneLibrary?.tracks ?? []) + (deviceLibrary?.tracks ?? [])
        let paths = Set(tracks.map { UsbLayout.nfc($0.path) })
        let missing = paths.filter { path in
            path.isEmpty || !isRegularFile(String(path.drop { $0 == "/" }))
        }.count
        return UsbInfo.Media(tracksChecked: Set(tracks.map(\.id)).count, filesChecked: paths.count, missingFiles: missing)
    }
}
