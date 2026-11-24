import DJCDomain
import Foundation

/// 업데이트 전 곡 초안 이관(#295 E1). 도장 기능(#400) 전 빌드가 남긴 도장 없는 곡 초안에 사람 편집 출처(`{human}`)를 한 번 붙인다.
/// 그러면 자동 저장이 그 초안을 대상 편집으로 본다(base가 지금 rekordbox와 다르면 관문이 막아 확인 필요로 남는다).
/// - 대상: 큐·그리드·태그(평점·곡 색 포함)는 도장 파일이 없는 초안, 게인은 도장 묶음(`gain.json`)이 없거나 정상으로 읽힌 묶음에 그 곡
///   항목이 없는 초안. 게인 도장 묶음을 읽지 못하면 게인은 모두 뺀다. 초안 내용을 읽지 못하면 뺀다.
/// - 대상이 아닌 것: 도장이 있는 초안(모름 `{unknown}`·`{human, unknown}` 포함, 그 도장은 의도한 제안이다), 손상된 도장 파일,
///   재생 목록 단계, 그림·합치기 초안
/// - 표지(`legacy-drafts-adopted.json`, 초안 폴더): 먼저 대상 키·"도장 없음"·해시를 적고(못 적으면 이관하지 않는다. 있는 표지를 읽지 못해도 이관하지 않는다), 전용 함수로 도장을
///   만든 뒤 완료를 적는다. 완료가 없으면 다음 실행은 표지에 적힌 키 가운데 아직 도장이 없고 해시가 같은 것만 다시 한다(그 사이 CLI가 같은
///   내용으로 저장해 도장이 생긴 키는 건너뛴다). 완료가 있으면 다시 하지 않는다: 그 뒤에 생긴 도장 없는 초안은 계속 제안이다.
/// 모든 일은 초안 잠금(`DraftStampStore.withLock`) 안에서 한다(앱·CLI의 저장·판 번호와 섞이지 않게).
public enum LegacyDraftAdoption {
    public static let markerName = "legacy-drafts-adopted.json"

    /// 표지의 한 줄: 이관할 키, 그때 도장이 없었다는 표시, 그때 내용의 해시
    struct Entry: Codable, Equatable {
        var kind: DraftKey.Kind
        var id: String
        var stampless: Bool
        var hash: DraftContentHash

        var key: DraftKey { DraftKey(kind, id) }
    }

    struct Marker: Codable, Equatable {
        var version = 1
        var entries: [Entry]
        var completed: Bool
    }

    /// 표지 자리(초안 폴더, 도장 폴더 밖: 도장 폴더를 지워도 이관이 다시 돌지 않게)
    public static func markerURL(home: URL) -> URL { home.appending(path: markerName) }

    /// 이관한다. 이관한 초안 수를 돌려준다(이미 마쳤거나 대상이 없으면 0).
    /// - Parameters:
    ///   - saveMarker: 표지를 원자적으로 적는다(시험이 실패를 넣는다). 시작 표지를 못 적으면 던지고 아무것도 바꾸지 않는다.
    ///     완료 표지를 못 적으면 던지지 않는다(붙인 도장은 남고 다음 실행이 남은 것만 다시 한다)
    ///   - beforeStamping: 시작 표지를 적은 뒤 도장을 붙이기 직전(시험이 중간에 멈춘 실행을 흉내 낸다)
    public static func adopt(home: URL, saveMarker: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
                             beforeStamping: () throws -> Void = {}) throws -> Int {
        try adoptKeys(home: home, saveMarker: saveMarker, beforeStamping: beforeStamping).count
    }

    /// 이관한 초안의 키(`adopt`와 같다). 앱은 게인을 빼고 센다(게인은 base가 없어 이관해도 자동으로 쓰지 않는다)
    public static func adoptKeys(home: URL, saveMarker: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
                                 beforeStamping: () throws -> Void = {}) throws -> [DraftKey] {
        try DraftStampStore.withLock(home: home) {
            let url = markerURL(home: home), places = DraftLocations(home: home)
            // 표지 파일이 있는데 읽거나 풀지 못하면 이관하지 않는다: 새로 모으면 표지 뒤에 생긴 도장 없는 초안까지 사람 편집이 된다
            var previous: Marker?
            if FileManager.default.fileExists(atPath: url.path) {
                guard let data = try? Data(contentsOf: url), let marker = try? JSONDecoder().decode(Marker.self, from: data) else { return [] }
                previous = marker
            }
            if previous?.completed == true { return [] }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let entries: [Entry]
            if let previous {
                // 마치지 못한 앞 실행: 표지의 키 가운데 아직 도장이 없고 내용이 그때와 같은 것만
                entries = previous.entries.filter { entry in
                    entry.stampless && isStampless(entry.key, places: places) && StampedDrafts.currentHash(entry.key, places: places) == entry.hash
                }
            } else {
                entries = candidates(places: places)
                try saveMarker(try encoder.encode(Marker(entries: entries, completed: false)), url)
            }
            try beforeStamping()
            let revisions = try DraftStampStore.nextRevisions(entries.count, home: home)
            for (entry, revision) in zip(entries, revisions) {
                try DraftStampStore.adoptAsHuman(entry.key, revision: revision, hash: entry.hash, home: home)
            }
            let done = Marker(entries: previous?.entries ?? entries, completed: true)
            if let data = try? encoder.encode(done) { try? saveMarker(data, url) }
            return entries.map(\.key)
        }
    }

    /// 표지가 없을 때 이관할 초안: 도장 파일이 없는 큐·그리드·태그와, 읽힌 게인 도장 묶음에 항목이 없는 게인
    static func candidates(places: DraftLocations) -> [Entry] {
        var keys: [DraftKey] = []
        for (kind, directory) in [(DraftKey.Kind.cue, places.cue), (.grid, places.grid), (.tag, places.tags)] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".json") {
                keys.append(DraftKey(kind, String(name.dropLast(".json".count))))
            }
        }
        if gainStamps(home: places.home) != nil, let gains = try? GainDraftStore.read(url: places.gain) {
            keys += gains.keys.sorted().map { DraftKey(.gain, $0) }
        }
        return keys.compactMap { key in
            guard isStampless(key, places: places), let hash = StampedDrafts.currentHash(key, places: places) else { return nil }
            return Entry(kind: key.kind, id: key.id, stampless: true, hash: hash)
        }
    }

    /// 도장이 없는지: 곡마다 파일인 종류는 도장 파일이 없을 때(손상된 도장 파일은 도장이 있는 것으로 본다), 게인은 도장 묶음이 없거나
    /// 읽힌 묶음에 그 곡 항목이 없을 때(묶음을 읽지 못하면 도장이 있는 것으로 본다)
    static func isStampless(_ key: DraftKey, places: DraftLocations) -> Bool {
        switch key.kind {
        case .cue, .grid, .tag:
            guard DraftStampStore.isSafeName(key.id) else { return false }
            let file = DraftStampStore.folder(home: places.home).appending(path: key.kind.rawValue, directoryHint: .isDirectory)
                .appending(path: "\(key.id).json")
            return !FileManager.default.fileExists(atPath: file.path)
        case .gain:
            guard let stamps = gainStamps(home: places.home) else { return false }
            return stamps[key.id] == nil
        case .artwork, .merge:
            return false
        }
    }

    /// 게인 도장 묶음. 파일이 없으면 빈 묶음, 읽지 못하면 nil
    static func gainStamps(home: URL) -> [String: DraftStamp]? {
        let url = DraftStampStore.folder(home: home).appending(path: "\(DraftKey.Kind.gain.rawValue).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: DraftStamp].self, from: data)
    }
}

extension DraftStampStore {
    /// 업데이트 전 초안에 사람 편집 출처의 도장을 새로 적는다(이관 전용: 기존 출처를 모으지 않는다). 초안 잠금 안에서 부른다
    static func adoptAsHuman(_ key: DraftKey, revision: DraftRevision, hash: DraftContentHash, home: URL) throws {
        try write(DraftStamp(revision: revision, origins: [.human], contentHash: hash), for: key, home: home)
    }
}
