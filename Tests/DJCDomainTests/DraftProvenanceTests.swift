@testable import DJCDomain
import Foundation
import Testing

/// 초안 출처·판·내용 해시(R5·R22). 해시는 바깥에서 고친 초안을 가려낸다: 같은 내용이면 어느 프로세스에서 언제 재도 같아야 하고
/// 사전·칸을 적는 차례에 기대지 않아야 한다(앱과 CLI가 같은 초안을 따로 잰다).
@Suite("초안 출처·판·내용 해시")
struct DraftProvenanceTests {
    /// 칸을 적는 차례만 다른 값(사전의 차례처럼 실행마다 달라질 수 있는 것)
    private struct Ordered: Encodable {
        var reversed: Bool
        enum Keys: String, CodingKey { case a, b, nested }
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            if reversed {
                try container.encode(["y": 2, "x": 1], forKey: .nested)
                try container.encode("2", forKey: .b)
                try container.encode(1, forKey: .a)
            } else {
                try container.encode(1, forKey: .a)
                try container.encode("2", forKey: .b)
                try container.encode(["x": 1, "y": 2], forKey: .nested)
            }
        }
    }

    private static func cueDraft(time: Double) -> CueDraft {
        var draft = CueDraft(trackUUID: "t")
        draft.cues = [EditableCue(kind: .memory, time: time)]
        return draft
    }

    @Test func 같은_내용이면_같은_해시다() throws {
        let draft = Self.cueDraft(time: 1.5)
        #expect(try DraftContentHash(of: draft) == DraftContentHash(of: draft))
        #expect(try DraftContentHash(of: ["b": 1.0, "a": 2.0]) == DraftContentHash(of: ["a": 2.0, "b": 1.0]))
    }

    @Test func 칸을_적는_차례에_기대지_않는다() throws {
        #expect(try DraftContentHash(of: Ordered(reversed: false)) == DraftContentHash(of: Ordered(reversed: true)))
    }

    @Test func 내용이_다르면_해시가_다르다() throws {
        let one = Self.cueDraft(time: 1.5)
        var other = one
        other.cues[0].time = 1.6
        #expect(try DraftContentHash(of: one) != DraftContentHash(of: other))
        // 배열의 차례는 내용이다(재생 목록에 넣는 곡의 차례처럼)
        #expect(try DraftContentHash(of: ["a", "b"]) != DraftContentHash(of: ["b", "a"]))
    }

    /// 해시의 정규 형식: 키를 정렬한 JSON(빈칸 없음, `/` 그대로)의 SHA-256, 소문자 16진 64자. 바꾸면 앱·CLI가 남긴 해시가 모두 어긋난다.
    @Test func 정규_형식은_키를_정렬한_JSON의_SHA256이다() throws {
        #expect(try DraftContentHash(of: ["a": 1]).hex == "015abd7f5cc57a2dd94b7590f04ad8084273905ee33ec5cebeae62276a97f862")
        let hash = try DraftContentHash(of: ["path": "/a/b"])
        #expect(hash.hex.count == 64 && hash.hex.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func 출처·판·도장은_JSON으로_오간다() throws {
        #expect(DraftOrigin.allCases.map(\.rawValue) == ["human", "cli", "agent", "link", "restored", "unknown"])
        let stamp = DraftStamp(revision: DraftRevision(42), origins: [.cli, .human], contentHash: try DraftContentHash(of: ["a": 1]))
        let data = try JSONEncoder.sorted.encode(stamp)
        // 출처는 차례 없이 모으지만 적을 때는 정한 차례로 적는다(같은 도장이면 같은 파일)
        #expect(String(decoding: data, as: UTF8.self).contains(#""origins":["human","cli"]"#))
        #expect(String(decoding: data, as: UTF8.self).contains(#""revision":42"#))
        #expect(try JSONDecoder().decode(DraftStamp.self, from: data) == stamp)
        let key = DraftKey(.tag, "uuid-1")
        #expect(try JSONDecoder().decode(DraftKey.self, from: JSONEncoder.sorted.encode(key)) == key)
        let written = WrittenDraft(key: key, revision: DraftRevision(7), contentHash: stamp.contentHash)
        #expect(try JSONDecoder().decode(WrittenDraft.self, from: JSONEncoder.sorted.encode(written)) == written)
    }

    @Test func 사람_편집만_든_도장인지() {
        let hash = DraftContentHash(hex: String(repeating: "0", count: 64))
        #expect(DraftStamp(revision: DraftRevision(1), origins: [.human], contentHash: hash).isHumanOnly)
        #expect(!DraftStamp(revision: DraftRevision(1), origins: [.human, .cli], contentHash: hash).isHumanOnly)
        #expect(!DraftStamp(revision: DraftRevision(1), origins: [], contentHash: hash).isHumanOnly)
        #expect(DraftRevision(2) > DraftRevision(1))
    }
}

extension JSONEncoder {
    /// 시험에서 적은 글자를 비교할 때(키 정렬)
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
