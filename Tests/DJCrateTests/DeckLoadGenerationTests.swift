@testable import DJCrate
import DJCApplication
import DJCDomain
import Foundation
import Synchronization
import Testing

/// 덱 곡 불러오기의 순서와 같은 곡 가드(세대 토큰). 가짜 오디오·가짜 읽기로 파일 없이 본다.
@Suite("덱 곡 불러오기 순서")
@MainActor
struct DeckLoadGenerationTests {
    /// 고른 곡 UUID의 큐 초안 읽기를 시험이 풀 때까지 붙잡는 읽기
    final class Hold: Sendable {
        let uuid: String
        let gate = DispatchSemaphore(value: 0)
        let entered: AsyncStream<Void>
        private let signal: AsyncStream<Void>.Continuation
        init(_ uuid: String) {
            self.uuid = uuid
            (entered, signal) = AsyncStream<Void>.makeStream()
        }
        func reader(_ storage: DeckStorage) -> TrackAssetReader {
            var reader = TrackAssetReader.memory(storage)
            reader.cueDraft = { [self] uuid in
                if uuid == self.uuid { signal.yield(()); gate.waitOffPool() }
                return storage.testDraftStore.currentCue(uuid)
            }
            return reader
        }
    }

    static func row(id: String = "1", uuid: String) -> TrackRow {
        let track = Track(id: id, uuid: uuid, title: "합성 곡", artist: nil, album: nil, albumArtist: nil, genre: nil,
                          composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: 120, lengthSeconds: 180,
                          folderPath: "/djc-test/audio.wav", comment: "", importedOn: nil, analysisDataPath: nil,
                          imagePath: nil, isDeleted: false)
        return TrackRow(track: track, cues: [], playCount: 0, autoGain: nil)
    }

    @Test func 초안_읽기를_기다리지_않고_음원부터_연다() async throws {
        let hold = Hold("slow"), storage = DeckStorage.memory(MemoryDrafts()), audio = FakeDeckAudio()
        let deck = DeckModel.test(audio: audio, storage: storage, reader: hold.reader(storage), runsAnalysis: false)
        deck.load(Self.row(uuid: "slow"))
        for await _ in hold.entered { break }
        // 초안·그리드 읽기가 붙잡혀 있어도 이미 재생할 수 있다.
        #expect(deck.canPlay && audio.log.contains("load"), "\(audio.log)")
        #expect(deck.draft == nil)
        hold.gate.signal()
        await deck.loadTask?.value
        #expect(deck.draft?.trackUUID == "slow")
    }

    @Test func 같은_ID에서_UUID가_바뀌면_그_전_곡의_늦은_읽기를_버린다() async throws {
        let hold = Hold("old"), storage = DeckStorage.memory(MemoryDrafts())
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: storage, reader: hold.reader(storage), runsAnalysis: false)
        deck.load(Self.row(uuid: "old"))
        for await _ in hold.entered { break }
        let stale = deck.loadTask
        // 같은 곡 ID·같은 파일이고 소리를 이미 열었으면 다시 부르지 않고 내용만 맞춘다.
        deck.load(Self.row(uuid: "new"))
        await deck.softReloadTask?.value
        #expect(deck.draft?.trackUUID == "new")
        hold.gate.signal()
        await stale?.value
        #expect(deck.draft?.trackUUID == "new" && deck.row?.track.uuid == "new")
    }
}
