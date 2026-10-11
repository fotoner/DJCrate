import DJCDomain
@testable import RekordboxKit
import Foundation
import Testing

@Suite("rekordbox XML")
struct RekordboxXMLTests {
    func staged(path: String = "/Volumes/T7 Shield/새 폴더/곡 & 이름 (TV).mp3") -> StagedTrack {
        StagedTrack(uuid: "u1", path: path, title: #"제목 "따옴표" <꺾쇠>"#, artist: "아티스트", genre: "애니송",
                    comment: "TVA 테큐 OP 2", duration: 269.4, addedOn: "2026-09-25")
    }

    @Test func 추가한_곡의_키는_XML에_넣지_않는다() {
        // 목록에만 보이는 키(태그·추정)다. rekordbox에 키를 넣는 것은 사용자가 확인한 조성만 쓰는 #5에서 한다.
        var track = staged()
        track.key = "8A"
        track.keySource = .estimate
        let xml = RekordboxXML.document(entries: [RekordboxXML.Entry(track: track, tempos: [], cues: [])], playlistName: "DJCrate 추가")
        #expect(!xml.contains("Tonality"))
    }

    @Test func 첫_템포_구간은_곡_시작_쪽_첫_박으로_당긴다() {
        // 154 BPM, 첫 박 번호 1인 박이 10.0초 → 0~0.39초 사이 첫 박으로, 박 번호도 함께 되돌린다.
        let period = 60 / 154.0
        let normalized = RekordboxXML.normalized([GridSegment(start: 10.0, bpm: 154.0, firstBeatNumber: 1)])
        #expect(normalized.count == 1)
        #expect(normalized[0].start >= 0 && normalized[0].start < period)
        let movedBeats = Int(((10.0 - normalized[0].start) / period).rounded())
        #expect(normalized[0].firstBeatNumber == ((1 - 1 - movedBeats) % 4 + 4) % 4 + 1)
    }

    @Test func 문서는_올바른_XML이고_값이_보존된다() throws {
        let cues = [EditableCue(kind: .memory, time: 12.3456, name: "인트로"), EditableCue(kind: .hot(2), time: 30.0)]
        let entry = RekordboxXML.Entry(track: staged(), tempos: [GridSegment(start: 0.256, bpm: 153.9987, firstBeatNumber: 1)], cues: cues)
        let xml = RekordboxXML.document(entries: [entry], playlistName: "DJCrate 추가")
        let parser = XMLParser(data: Data(xml.utf8))
        final class Collector: NSObject, XMLParserDelegate {
            var elements: [(String, [String: String])] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
                elements.append((name, attributes))
            }
        }
        let collector = Collector()
        parser.delegate = collector
        #expect(parser.parse(), "XML 파싱 실패: \(String(describing: parser.parserError))")
        let track = try #require(collector.elements.first { $0.0 == "TRACK" && $0.1["TrackID"] != nil }?.1)
        #expect(track["Name"] == #"제목 "따옴표" <꺾쇠>"#)
        #expect(track["Location"] == "file://localhost/Volumes/T7%20Shield/%EC%83%88%20%ED%8F%B4%EB%8D%94/%EA%B3%A1%20&%20%EC%9D%B4%EB%A6%84%20(TV).mp3")
        #expect(track["AverageBpm"] == "154.00")
        #expect(track["TotalTime"] == "269")
        let tempo = try #require(collector.elements.first { $0.0 == "TEMPO" }?.1)
        #expect(tempo["Inizio"] == "0.256" && tempo["Bpm"] == "154.00" && tempo["Battito"] == "1" && tempo["Metro"] == "4/4")
        let marks = collector.elements.filter { $0.0 == "POSITION_MARK" }.map(\.1)
        #expect(marks.count == 2)
        #expect(marks[0]["Num"] == "-1" && marks[0]["Start"] == "12.346" && marks[0]["Name"] == "인트로")
        #expect(marks[1]["Num"] == "2" && marks[1]["Type"] == "0")
        #expect(collector.elements.contains { $0.0 == "NODE" && $0.1["Name"] == "DJCrate 추가" && $0.1["Entries"] == "1" })
    }

    @Test func 그리드가_없으면_TEMPO를_쓰지_않는다() {
        let xml = RekordboxXML.document(entries: [.init(track: staged(), tempos: [], cues: [])], playlistName: "p")
        #expect(!xml.contains("<TEMPO"))
        #expect(!xml.contains("AverageBpm"))
    }
}
