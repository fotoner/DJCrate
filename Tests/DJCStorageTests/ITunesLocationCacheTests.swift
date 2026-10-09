@testable import DJCStorage
import Foundation
import Testing

@Suite("Music 곡 위치 중복 조회")
struct ITunesLocationCacheTests {
    @Test func 중복_항목의_순서를_유지하며_없는_위치도_한_번만_조회한다() {
        var cache = ITunesLocationCache()
        var calls: [UInt64: Int] = [:]
        let lists: [[UInt64]] = [[1, 2, 1, 3], [2, 3, 4, 1]]
        let paths = lists.map { ids in
            ids.map { id in
                cache.path(for: id) {
                    calls[id, default: 0] += 1
                    return switch id {
                    case 1: URL(filePath: "/synthetic/a.mp3")
                    case 2: nil
                    case 3: URL(string: "https://example.invalid/stream")
                    default: URL(filePath: "/synthetic/b.mp3")
                    }
                }
            }
        }
        #expect(paths == [["/synthetic/a.mp3", nil, "/synthetic/a.mp3", nil],
                          [nil, nil, "/synthetic/b.mp3", "/synthetic/a.mp3"]])
        #expect(calls == [1: 1, 2: 1, 3: 1, 4: 1])
        var nextCapture = ITunesLocationCache()
        #expect(nextCapture.path(for: 1) { URL(filePath: "/synthetic/moved.mp3") } == "/synthetic/moved.mp3")
    }
}
