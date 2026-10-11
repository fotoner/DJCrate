import Foundation

/// 한 번의 캡처 안에서만 공유한다. 다음 새로고침에서는 바뀐 위치를 다시 읽는다.
struct ITunesLocationCache {
    private var paths: [UInt64: String?] = [:]

    mutating func path(for id: UInt64, location: () -> URL?) -> String? {
        if let cached = paths[id] { return cached }
        let url = location()
        let path = url?.isFileURL == true ? url?.path : nil
        // nil도 값으로 남겨 로컬 위치 없는 곡을 목록마다 다시 묻지 않는다.
        paths.updateValue(path, forKey: id)
        return path
    }
}
