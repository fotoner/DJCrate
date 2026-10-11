import DJCDomain
import Foundation
import Testing

/// USB 라이브러리의 기기 재생 기록 → 보존 후보(#43, `UsbHistoryCandidates`, 입출력 없음). 곡 제목·경로·ID는 지어낸 값이다.
@Suite("USB 재생 기록 보존 후보")
struct UsbHistoryCandidatesTests {
    static let volumeKey = "SYNTH-USB-UUID"
    static let volumeName = "합성 USB"

    static func source(_ format: UsbFormat, _ id: Int, _ name: String) -> ArchivedHistory.Source {
        ArchivedHistory.Source(volumeKey: volumeKey, volumeName: volumeName, format: format.rawValue, historyID: id, historyName: name)
    }

    static func track(_ id: Int, in formats: Set<UsbFormat> = UsbFormat.defaultSet, artistID: Int? = nil) -> UsbTrack {
        UsbTrack(id: id, presentIn: formats, title: "합성 곡 \(id)", artistID: artistID, path: "/Contents/합성/test\(id).mp3",
                 fileName: "test\(id).mp3", masterDbId: 1_000_001, masterContentId: Int64(id) + 10)
    }

    /// 두 형식을 합친 USB: 곡 1·2는 두 형식, 곡 3은 OneLibrary에만. 기록은 일부러 섞인 순서로 둔다
    static func library() -> UsbLibrary {
        UsbLibrary(formats: UsbFormat.defaultSet, property: UsbProperty(),
                   tracks: [track(1, artistID: 100), track(2), track(3, in: [.oneLibrary])],
                   artists: [UsbNamedRow(id: 100, name: "합성 아티스트")],
                   histories: [
                       UsbHistory(format: .deviceLibrary, id: 2, name: "HISTORY 002", entries: [2, 1]),
                       // 반복 재생
                       UsbHistory(format: .oneLibrary, id: 5, name: "HISTORY 005", entries: [1, 2, 1]),
                       // 폴더 행(곡 없음)
                       UsbHistory(format: .oneLibrary, id: 1, name: "2026", entries: []),
                       // Device Library에 없는 곡(3)과 어디에도 없는 곡(99)도 번호·재생 순서를 보존한다
                       UsbHistory(format: .deviceLibrary, id: 1, name: "HISTORY 001", entries: [3, 99]),
                       UsbHistory(format: .oneLibrary, id: 3, name: "HISTORY 003", entries: [99, 3]),
                   ])
    }

    // MARK: - 후보

    @Test func 후보는_OneLibrary_먼저_번호_순이고_빈_기록만_빼고_모든_항목을_담는다() throws {
        let candidates = UsbHistoryCandidates.make(library: Self.library(), volumeKey: Self.volumeKey, volumeName: Self.volumeName,
                                                   matches: [1: "501", 3: "503"])
        #expect(candidates.map(\.source) == [
            Self.source(.oneLibrary, 3, "HISTORY 003"),
            Self.source(.oneLibrary, 5, "HISTORY 005"),
            Self.source(.deviceLibrary, 1, "HISTORY 001"),
            Self.source(.deviceLibrary, 2, "HISTORY 002"),
        ])
        try #require(candidates.count == 4)

        // 찾지 못한 곡(99)은 최소 번호·순서를 남기고 다른 곡으로 잇지 않는다
        #expect(candidates[0].entries.map(\.usbContentID) == [99, 3])
        #expect(candidates[0].entries.map(\.trackNumber) == [1, 2])
        #expect(candidates[0].entries.map(\.contentID) == [nil, "503"])
        #expect(candidates[0].entries[0].path.isEmpty)
        #expect(candidates[0].entries[0].title.contains("99"))

        // 반복 재생은 그대로, 짝이 없는 곡은 nil
        let played = candidates[1].entries
        #expect(played.map(\.usbContentID) == [1, 2, 1])
        #expect(played.map(\.trackNumber) == [1, 2, 3])
        #expect(played.map(\.contentID) == ["501", nil, "501"])
        #expect(played.first == ArchivedHistory.Entry(trackNumber: 1, usbContentID: 1, contentID: "501", title: "합성 곡 1",
                                                       artist: "합성 아티스트", path: "/Contents/합성/test1.mp3", masterDbId: 1_000_001,
                                                       masterContentId: 11, fileName: "test1.mp3"))
        #expect(played.map(\.title) == ["합성 곡 1", "합성 곡 2", "합성 곡 1"])
        #expect(played.map(\.artist) == ["합성 아티스트", nil, "합성 아티스트"])

        // Device Library 기록도 같은 번호 공간(합친 모델의 곡 번호)으로 짝을 찾는다
        #expect(candidates[2].entries.map(\.usbContentID) == [3, 99])
        #expect(candidates[2].entries.allSatisfy { $0.contentID == nil && $0.path.isEmpty })
        #expect(candidates[3].entries.map(\.usbContentID) == [2, 1])
        #expect(candidates[3].entries.map(\.contentID) == [nil, "501"])
        #expect(candidates[3].entries.map(\.path) == ["/Contents/합성/test2.mp3", "/Contents/합성/test1.mp3"])
    }

    @Test func 같은_번호가_형식마다_다른_파일이면_원래_형식의_메타데이터와_순서를_보존한다() throws {
        var olTrack = Self.track(7, in: [.oneLibrary])
        olTrack.path = "/Contents/합성/ol7.mp3"
        olTrack.fileName = "ol7.mp3"
        var dlTrack = Self.track(7, in: [.deviceLibrary])
        dlTrack.title = "다른 곡"
        dlTrack.path = "/Contents/합성/dl7.mp3"
        dlTrack.fileName = "dl7.mp3"
        dlTrack.artistID = 100
        dlTrack.masterContentId = 707
        dlTrack.bpmx100 = 13250
        dlTrack.lengthSeconds = 230
        let oneLibrary = UsbLibrary(formats: [.oneLibrary], property: UsbProperty(), tracks: [olTrack, Self.track(8, in: [.oneLibrary])],
                                    histories: [UsbHistory(format: .oneLibrary, id: 1, name: "HISTORY 001", entries: [7, 8])])
        let deviceLibrary = UsbLibrary(formats: [.deviceLibrary], property: UsbProperty(),
                                       tracks: [dlTrack, Self.track(8, in: [.deviceLibrary])],
                                       artists: [UsbNamedRow(id: 100, name: "Device Library 아티스트")],
                                       histories: [UsbHistory(format: .deviceLibrary, id: 1, name: "HISTORY 001", entries: [8, 7])])
        let (merged, mismatches) = UsbLibrary.merge(oneLibrary: oneLibrary, deviceLibrary: deviceLibrary)
        // 합친 모델은 7번에 OneLibrary 곡만 남기고 그 곡을 Device Library에 없는 것으로 적는다
        #expect(mismatches.contains(.trackPathDiffers(id: 7)))
        #expect(merged.tracks.first { $0.id == 7 }?.presentIn == Set<UsbFormat>([.oneLibrary]))

        let candidates = UsbHistoryCandidates.make(library: merged, volumeKey: Self.volumeKey, volumeName: Self.volumeName,
                                                   matches: [7: "507", 8: "508"])
        #expect(candidates.map(\.source) == [Self.source(.oneLibrary, 1, "HISTORY 001"), Self.source(.deviceLibrary, 1, "HISTORY 001")])
        try #require(candidates.count == 2)
        #expect(candidates[0].entries.map(\.path) == ["/Contents/합성/ol7.mp3", "/Contents/합성/test8.mp3"])
        #expect(candidates[0].entries.map(\.contentID) == ["507", "508"])
        // Device Library의 7번은 다른 파일이라 OneLibrary 7번 곡(과 그 로컬 짝)으로 잇지 않는다
        #expect(candidates[1].entries.map(\.usbContentID) == [8, 7])
        #expect(candidates[1].entries.map(\.contentID) == ["508", nil])
        #expect(candidates[1].entries.map(\.trackNumber) == [1, 2])
        let preserved = candidates[1].entries[1]
        #expect(preserved.title == "다른 곡")
        #expect(preserved.artist == "Device Library 아티스트")
        #expect(preserved.path == dlTrack.path && preserved.fileName == dlTrack.fileName)
        #expect(preserved.masterContentId == 707)
        #expect(preserved.bpm == 132.5 && preserved.lengthSeconds == 230)
        // 다시 합쳐도 원본 형식의 기록용 메타데이터가 남는다
        let again = UsbLibrary.merge(oneLibrary: merged, deviceLibrary: merged).0
        #expect(UsbHistoryCandidates.make(library: again, volumeKey: Self.volumeKey, volumeName: Self.volumeName,
                                          matches: [7: "507", 8: "508"]) == candidates)
    }

    @Test func 충돌_곡만_든_기록과_원본에_없는_반복_항목도_기록_전체를_보존한다() throws {
        var olTrack = Self.track(7, in: [.oneLibrary])
        var dlTrack = Self.track(7, in: [.deviceLibrary])
        olTrack.path = "/Contents/합성/ol7.mp3"
        dlTrack.path = "/Contents/합성/dl7.mp3"
        let ol = UsbLibrary(formats: [.oneLibrary], property: UsbProperty(), tracks: [olTrack])
        let dl = UsbLibrary(formats: [.deviceLibrary], property: UsbProperty(), tracks: [dlTrack],
                            histories: [UsbHistory(format: .deviceLibrary, id: 1, name: "HISTORY 001", entries: [7, 99, 7, 99])])
        let merged = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl).0
        let candidates = UsbHistoryCandidates.make(library: merged, volumeKey: Self.volumeKey, volumeName: Self.volumeName,
                                                   matches: [7: "wrong", 99: "also-wrong"])
        let candidate = try #require(candidates.first)
        #expect(candidate.entries.map(\.usbContentID) == [7, 99, 7, 99])
        #expect(candidate.entries.map(\.trackNumber) == [1, 2, 3, 4])
        #expect(candidate.entries.allSatisfy { $0.contentID == nil })
        #expect(candidate.entries.map(\.path) == [dlTrack.path, "", dlTrack.path, ""])
    }

    @Test func 같은_경로여도_형식별_제목_아티스트와_짝짓기_키를_원본대로_보존한다() throws {
        var olTrack = Self.track(7, in: [.oneLibrary], artistID: 100)
        var dlTrack = Self.track(7, in: [.deviceLibrary], artistID: 100)
        olTrack.title = "OneLibrary 제목"
        dlTrack.title = "Device Library 제목"
        dlTrack.masterDbId += 1
        let ol = UsbLibrary(formats: [.oneLibrary], property: UsbProperty(), tracks: [olTrack],
                            artists: [UsbNamedRow(id: 100, name: "OneLibrary 아티스트")],
                            histories: [UsbHistory(format: .oneLibrary, id: 1, name: "HISTORY 001", entries: [7])])
        let dl = UsbLibrary(formats: [.deviceLibrary], property: UsbProperty(), tracks: [dlTrack],
                            artists: [UsbNamedRow(id: 100, name: "Device Library 아티스트")],
                            histories: [UsbHistory(format: .deviceLibrary, id: 1, name: "HISTORY 001", entries: [7])])
        let merged = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl).0
        let candidates = UsbHistoryCandidates.make(library: merged, volumeKey: Self.volumeKey, volumeName: Self.volumeName, matches: [7: "507"])
        #expect(candidates.map { $0.entries.first?.title } == [olTrack.title, dlTrack.title])
        #expect(candidates.map { $0.entries.first?.artist } == ["OneLibrary 아티스트", "Device Library 아티스트"])
        #expect(candidates.map { $0.entries.first?.contentID } == ["507", nil])
        #expect(candidates.last?.entries.first?.masterDbId == dlTrack.masterDbId)
    }

    @Test func 기록용_원본_메타데이터를_남겨도_쓰기_투영과_재병합_계약은_그대로다() {
        let ol = UsbLibrary(formats: [.oneLibrary], property: UsbProperty(), tracks: [Self.track(7, in: [.oneLibrary])],
                            artists: [UsbNamedRow(id: 100, name: "합성 아티스트")],
                            histories: [UsbHistory(format: .oneLibrary, id: 1, name: "HISTORY 001", entries: [7])])
        let dl = UsbLibrary(formats: [.deviceLibrary], property: UsbProperty(), tracks: [Self.track(7, in: [.deviceLibrary])],
                            artists: [UsbNamedRow(id: 100, name: "합성 아티스트")],
                            histories: [UsbHistory(format: .deviceLibrary, id: 1, name: "HISTORY 001", entries: [7])])
        let merged = UsbLibrary.merge(oneLibrary: ol, deviceLibrary: dl).0
        #expect(merged.historyMetadata(in: .oneLibrary).tracks == ol.tracks)
        #expect(merged.historyMetadata(in: .deviceLibrary).tracks == dl.tracks)
        #expect(merged.projected(to: .oneLibrary) == ol)
        #expect(merged.projected(to: .deviceLibrary) == dl)
        #expect(UsbLibrary.merge(oneLibrary: merged, deviceLibrary: merged).0 == merged)
    }
}
