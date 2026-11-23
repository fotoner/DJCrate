import DJCDomain
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// USB 수정 생성 조합(#383): 고정 씨앗으로 만든 유효한 편집 묶음을 한 USB에 여러 번 연달아 쓰고, 묶음마다 기준 모델과 형식 불변식을 함께 본다.
/// 기준 모델은 곡을 USB 경로로, 목록을 맨 위부터의 이름 경로로 가리킨다(USB ID는 엔진이 정하므로 쓰지 않는다).
/// 같은 경로의 다른 곡·같은 이름 목록은 `UsbEditEngineTests`·`UsbLibraryMergeTests`가 맡아 생성기는 경로와 부모별 이름을 고유하게 만든다.
/// 실패 메시지에는 씨앗과 그 묶음의 편집 목록이 있다. 같은 씨앗은 같은 묶음을 만든다
@Suite("USB 수정 생성 조합")
struct UsbEditGeneratedTests {
    /// 씨앗 수와 묶음 수는 작게 고정한다(멈춤 감시 HAR-41 안, `--changed`에서 Suite 전체 30초 안팎)
    static let seeds: [UInt64] = Array(1...12)
    static let batchCount = 3

    @Test("생성한 편집 묶음이 기준 모델·형식 불변식과 맞다", arguments: seeds)
    func generatedBatches(seed: UInt64) throws {
        let env = try UsbEditFixture.exported(Generator.exported)
        try env.addLocal(Generator.extra)
        var generator = Generator(seed: seed)
        var stats = Stats()
        var (read, matched) = try Self.expectMatches(env, generator.reference, "씨앗 \(seed) 시작")
        // 기준 모델과 어긋난 상태를 다음 묶음의 입력으로 쓰지 않는다(빈 후보 고르기로 이어진다). 실패는 이미 기록했다
        guard matched else { return }
        for number in 1...Self.batchCount {
            let before = generator.reference.shape
            // 짝수 씨앗의 두 번째 묶음은 순효과가 없게 만든다(이름 A → B → A, 목록 끝에 곡을 넣고 그 자리를 빼기)
            let batch = generator.makeBatch(cancelling: seed % 2 == 0 && number == 2, usb: Self.usbIDs(read))
            let context = "씨앗 \(seed) 묶음 \(number): \(batch.notes.joined(separator: "; ")) | 편집 \(batch.edits)"
            for (id, track) in batch.localUpdates {
                try env.updateLocal(id, "TrackInfoUpdated = ?, Title = ?, Commnt = ?",
                                    [.text(String(track.infoCount)), .text(track.title), .text(track.comment)])
            }
            let result: UsbEditResult
            if generator.reference.shape != before {
                stats.effect += 1
                do {
                    let (written, report) = try env.edit(batch.edits)
                    #expect(report.outcome == .written, "\(context)")
                    result = written
                } catch {
                    Issue.record(error, "\(context)")
                    return
                }
            } else {
                // 순효과가 없으면 엔진은 모두 바뀐 것 없음으로 두고 쓰지 않는다(UsbEditEngine+Plan). 그래서 계획만 한다
                stats.noEffect += 1
                do {
                    result = try env.plan(batch.edits, highWater: env.usb.journal()?.changes.idHighWater ?? [:])
                } catch {
                    Issue.record(error, "\(context)")
                    return
                }
                #expect(result.changes == nil, "순효과가 없는데 쓸 것이 있음. \(context)")
                // 디스크는 그대로이므로 계획의 적용 결과도 두 형식 모두 기준 모델과 같아야 한다
                let applied = try #require(result.applied, "\(context)")
                #expect(applied.formats == UsbFormat.defaultSet, "계획 적용 결과의 형식 \(applied.formats). \(context)")
                guard applied.formats == UsbFormat.defaultSet, Self.expectShape(applied, generator.reference, "계획 적용 결과", context) else { return }
            }
            stats.count(result.outcomes)
            let blocked = result.outcomes.filter { if case .blocked = $0.outcome { true } else { false } }
            #expect(blocked.isEmpty, "막힌 편집 \(blocked). \(context)")
            do {
                (read, matched) = try Self.expectMatches(env, generator.reference, context)
            } catch {
                Issue.record(error, "\(context)")
                return
            }
            guard matched else { return }
            // 형식 비교는 기존 불변식 시험의 것을 그대로 쓴다. 실패 메시지에는 씨앗·묶음·편집 목록을 붙인다
            do {
                try UsbEditInvariantTests.check(env, result, context)
            } catch {
                Issue.record(error, "\(context)")
                return
            }
        }
        #expect(stats.effect > 0 && (seed % 2 == 1 || stats.noEffect > 0) && stats.blocked == 0, "씨앗 \(seed) \(stats)")
    }

    // MARK: - 기준 모델과 비교

    /// 지금 USB를 형식마다 읽어 기준 모델과 견준다. 읽은 모델(합친 것)과 일치 여부를 돌려준다
    static func expectMatches(_ env: UsbEditFixture, _ reference: Reference, _ context: String) throws -> (UsbLibrary, Bool) {
        let read = try env.read()
        #expect(read.formats == UsbFormat.defaultSet, "형식 \(read.formats). \(context)")
        let matched = expectShape(read, reference, "읽은 모델", context)
        return (read, matched && read.formats == UsbFormat.defaultSet)
    }

    /// 모델의 형식마다 기준 모델과 견준다. 열쇠 문제도 차이도 없으면 참
    static func expectShape(_ library: UsbLibrary, _ reference: Reference, _ label: String, _ context: String) -> Bool {
        let expected = reference.shape
        #expect(!library.formats.isEmpty, "\(label)에 형식이 없음. \(context)")
        var matched = !library.formats.isEmpty
        for format in UsbFormat.allCases where library.formats.contains(format) {
            let (shape, problems) = Self.shape(library.projected(to: format), format: format)
            #expect(problems.isEmpty, "[\(format.rawValue)] \(label) 열쇠 문제 \(problems). \(context)")
            let differences = expected.differences(shape)
            #expect(differences.isEmpty, "[\(format.rawValue)] \(label): 기준 모델과 다름 \(differences.prefix(8)). \(context)")
            matched = matched && problems.isEmpty && differences.isEmpty
        }
        return matched
    }

    /// 한 형식 모델을 기준 모델 모양으로 바꾼다. 곡 경로·목록 이름 경로가 겹치거나 가리키는 행이 없으면 문제로 센다
    static func shape(_ library: UsbLibrary, format: UsbFormat) -> (Shape, [String]) {
        var problems: [String] = []
        var tracks: [String: Shape.Track] = [:], paths: [Int: String] = [:]
        for track in library.tracks {
            paths[track.id] = track.path
            if tracks.updateValue(Shape.Track(title: track.title, comment: track.comment), forKey: track.path) != nil {
                problems.append("곡 경로 겹침 \(track.path)")
            }
        }
        let (names, nameProblems) = namePaths(library.playlists)
        problems += nameProblems
        var lists: [[String]: Shape.List] = [:]
        for playlist in library.playlists {
            guard let key = names[playlist.id] else { continue }
            var entries: [String] = []
            for id in playlist.entries[format] ?? [] {
                if paths[id] == nil { problems.append("목록 \(key) 항목 \(id)의 곡 없음") }
                entries.append(paths[id] ?? "#\(id)")
            }
            if lists.updateValue(Shape.List(isFolder: playlist.attribute == 1, entries: entries), forKey: key) != nil {
                problems.append("목록 이름 경로 겹침 \(key)")
            }
        }
        return (Shape(tracks: tracks, lists: lists), problems)
    }

    /// 목록 번호 → 맨 위부터의 이름 경로
    static func namePaths(_ playlists: [UsbPlaylist]) -> ([Int: [String]], [String]) {
        var byID: [Int: UsbPlaylist] = [:], problems: [String] = []
        for playlist in playlists where byID.updateValue(playlist, forKey: playlist.id) != nil {
            problems.append("목록 번호 겹침 \(playlist.id)")
        }
        var paths: [Int: [String]] = [:]
        for playlist in playlists {
            var names = [playlist.name], parent = playlist.parentID, seen: Set<Int> = [playlist.id]
            while parent != 0 {
                guard let up = byID[parent], seen.insert(parent).inserted else {
                    problems.append("목록 \(playlist.id)의 부모 \(parent) 없음·순환")
                    break
                }
                names.insert(up.name, at: 0)
                parent = up.parentID
            }
            if parent == 0 { paths[playlist.id] = names }
        }
        return (paths, problems)
    }

    /// 생성기가 편집을 만들 때 쓰는 지금 USB ID(합친 모델의 대표 번호). 기준 모델과 맞은 뒤에만 부른다
    static func usbIDs(_ library: UsbLibrary) -> Generator.UsbIDs {
        Generator.UsbIDs(tracks: Dictionary(library.tracks.map { ($0.path, $0.id) }) { first, _ in first },
                         lists: Dictionary(namePaths(library.playlists).0.map { ($0.value, $0.key) }) { first, _ in first })
    }

    // MARK: - 모양

    /// 비교 모양: 곡은 USB 경로 → 제목·코멘트, 목록은 이름 경로 → 폴더 여부·곡 경로 순서
    struct Shape: Equatable {
        struct Track: Hashable {
            var title: String
            var comment: String
        }

        struct List: Hashable {
            var isFolder: Bool
            var entries: [String]
        }

        var tracks: [String: Track]
        var lists: [[String]: List]

        /// 기대(self)와 읽은 것의 차이
        func differences(_ read: Shape) -> [String] {
            var result: [String] = []
            for path in Set(tracks.keys).union(read.tracks.keys).sorted() where tracks[path] != read.tracks[path] {
                result.append("곡 \(path): 기대 \(tracks[path].map { "\($0)" } ?? "없음"), 읽음 \(read.tracks[path].map { "\($0)" } ?? "없음")")
            }
            for key in Set(lists.keys).union(read.lists.keys).sorted(by: { $0.lexicographicallyPrecedes($1) }) where lists[key] != read.lists[key] {
                result.append("목록 \(key): 기대 \(lists[key].map { "\($0)" } ?? "없음"), 읽음 \(read.lists[key].map { "\($0)" } ?? "없음")")
            }
            return result
        }
    }

    /// 기준 모델. 목록은 생성기 핸들로 들고(이름·부모 핸들), 비교할 때 이름 경로로 바꾼다
    struct Reference {
        struct List {
            var name: String
            /// nil = 맨 위
            var parent: String?
            var isFolder: Bool
            /// 곡 경로 순서
            var entries: [String]
        }

        var tracks: [String: Shape.Track] = [:]
        var lists: [String: List] = [:]

        func namePath(_ handle: String) -> [String] {
            var names: [String] = [], current: String? = handle
            while let at = current, let list = lists[at], names.count <= lists.count {
                names.insert(list.name, at: 0)
                current = list.parent
            }
            return names
        }

        var shape: Shape {
            Shape(tracks: tracks, lists: Dictionary(lists.map { handle, list in
                (namePath(handle), Shape.List(isFolder: list.isFolder, entries: list.entries))
            }) { first, _ in first })
        }

        /// 그 목록 아래(자손) 핸들
        func descendants(of handle: String) -> Set<String> {
            var result: Set<String> = [], queue = [handle]
            while let parent = queue.popLast() {
                for (child, list) in lists where list.parent == parent && result.insert(child).inserted { queue.append(child) }
            }
            return result
        }

        var trackLists: [String] { lists.filter { !$0.value.isFolder }.map(\.key).sorted() }
        var folders: [String] { lists.filter(\.value.isFolder).map(\.key).sorted() }
    }

    struct Stats: CustomStringConvertible {
        var effect = 0, noEffect = 0
        /// 편집 결과별 수(`.blocked`는 따로 센다)
        var written = 0, unchanged = 0, blocked = 0, deferred = 0

        mutating func count(_ outcomes: [(edit: Int, outcome: UsbOutcome)]) {
            for (_, outcome) in outcomes {
                switch outcome {
                case .written: written += 1
                case .unchanged: unchanged += 1
                case .blocked: blocked += 1
                case .deferred: deferred += 1
                }
            }
        }

        var description: String {
            "순효과 묶음 \(effect)·없는 묶음 \(noEffect), 편집 written \(written)·unchanged \(unchanged)·blocked \(blocked)·deferred \(deferred)"
        }
    }

    // MARK: - 생성기

    /// 씨앗 고정 난수(SplitMix64). 표준 라이브러리의 고르기 알고리즘에 기대지 않게 고르기도 직접 한다
    struct SeededRandom {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func below(_ count: Int) -> Int { Int(next() % UInt64(count)) }
        mutating func pick<T>(_ values: [T]) -> T { values[below(values.count)] }
    }

    /// 현재 곡·목록 트리를 따라 유효한 편집만 만든다. 곡 넣기·빼기(USB·목록), 목록 만들기·이름 바꾸기·옮기기, 곡 정보 갱신
    struct Generator {
        struct LocalTrack {
            var title: String
            var comment: String
            /// 로컬 TrackInfoUpdated(갱신할 때마다 1 올린다. 재료 기본값 1)
            var infoCount: Int
        }

        struct UsbIDs {
            /// 곡 경로 → content id
            var tracks: [String: Int]
            /// 목록 이름 경로 → 목록 번호
            var lists: [[String]: Int]
        }

        struct Batch {
            var edits: [UsbLibraryEdit] = []
            var notes: [String] = []
            /// 계획 전에 로컬 사본에 쓸 곡 정보(갱신 편집의 요청 값)
            var localUpdates: [(id: String, track: LocalTrack)] = []
        }

        enum Kind: CaseIterable {
            case addTracks, removeTracks, create, rename, move, addEntries, removeEntries, refresh

            /// 고를 때의 비중. 목록 트리를 넓히려고 만들기·옮기기를 두 배로 둔다
            static let weighted: [Kind] = allCases + [.create, .move]
        }

        /// USB에 내보낸 곡(목록 "합성 목록"에 이 순서로 든다)과 로컬에만 있는 곡
        static let exported = ["101", "102", "103", "104", "105"]
        static let extra = ["106", "107", "108"]

        /// 재료 곡의 USB 경로(`UsbExportFixture.addTrack`의 아티스트·앨범·파일 이름)
        static func path(_ localID: String) -> String { "/Contents/합성 아티스트/합성 앨범/track\(localID).mp3" }

        let seed: UInt64
        var random: SeededRandom
        var reference = Reference()
        var local: [String: LocalTrack] = [:]
        var counter = 0
        let localIDByPath: [String: String]

        // 묶음 하나 동안의 상태
        var knownTracks: [String: Int] = [:]
        var knownLists: [String: Int] = [:]
        var created: Set<String> = []
        var added: Set<String> = []
        var removed: Set<String> = []
        var refreshed: Set<String> = []
        var moved: Set<String> = []
        var batch = Batch()

        init(seed: UInt64) {
            self.seed = seed
            random = SeededRandom(state: seed)
            localIDByPath = Dictionary(uniqueKeysWithValues: (Self.exported + Self.extra).map { (Self.path($0), $0) })
            for id in Self.exported + Self.extra { local[id] = LocalTrack(title: "합성 곡 \(id)", comment: "", infoCount: 1) }
            for id in Self.exported { reference.tracks[Self.path(id)] = Shape.Track(title: "합성 곡 \(id)", comment: "") }
            reference.lists["L0"] = Reference.List(name: "합성 목록", parent: nil, isFolder: false, entries: Self.exported.map(Self.path))
        }

        /// 묶음 하나를 만든다. 기준 모델·로컬 곡 값은 이 묶음을 적용한 뒤로 바뀐다
        mutating func makeBatch(cancelling: Bool, usb: UsbIDs) -> Batch {
            knownTracks = usb.tracks.filter { reference.tracks[$0.key] != nil }
            knownLists = Dictionary(uniqueKeysWithValues: reference.lists.keys.compactMap { handle in
                usb.lists[reference.namePath(handle)].map { (handle, $0) }
            })
            (created, added, removed, refreshed, moved, batch) = ([], [], [], [], [], Batch())
            if cancelling {
                cancellingEdits()
            } else {
                // 첫 묶음은 폴더 하나로 시작한다(폴더가 없으면 옮기기·폴더 안 만들기를 만들 수 없다)
                if reference.folders.isEmpty { create(folder: true) }
                for _ in 0..<(2 + random.below(3)) {
                    // 고른 종류를 만들 수 없으면(대상 없음) 다음 종류로 간다. 목록 만들기는 늘 된다
                    let kinds = Kind.allCases, start = kinds.firstIndex(of: random.pick(Kind.weighted))!
                    for offset in kinds.indices {
                        if apply(kinds[(start + offset) % kinds.count]) { break }
                    }
                }
            }
            return batch
        }

        mutating func apply(_ kind: Kind) -> Bool {
            switch kind {
            case .addTracks: addTracks()
            case .removeTracks: removeTracks()
            case .create: create()
            case .rename: rename()
            case .move: move()
            case .addEntries: addEntries()
            case .removeEntries: removeEntries()
            case .refresh: refresh()
            }
        }

        mutating func append(_ edit: UsbLibraryEdit, _ note: String) {
            batch.edits.append(edit)
            batch.notes.append(note)
        }

        /// 묶음 시작에 USB에 있던 목록은 USB 번호로, 이 묶음에서 만든 목록은 만들 때 준 key로 가리킨다
        func ref(_ handle: String?) -> PlaylistRef {
            guard let handle else { return .root }
            if created.contains(handle) { return .new(handle) }
            return knownLists[handle].map { .id(String($0)) } ?? .new(handle)
        }

        func label(_ handle: String?) -> String { handle.map { "\($0)'\(reference.lists[$0]?.name ?? "?")'" } ?? "맨 위" }
        func label(path: String) -> String { localIDByPath[path] ?? path }

        /// ID를 아는 곡(묶음 시작에 USB에 있었고 이 묶음에서 빼거나 다시 넣지 않은 곡)
        var usableTracks: [String] { knownTracks.keys.filter { reference.tracks[$0] != nil && !added.contains($0) }.sorted() }

        mutating func addTracks() -> Bool {
            // 같은 묶음에서 USB에서 뺀 곡은 다시 넣지 않는다. 지금 엔진은 계획을 통과시키고 쓰기 사전 확인이 분석 파일 셋을
            // destinationExists로 거부한다(#383 보고, 최소 조합 [곡 빼기 2, 곡 넣기 102]). 엔진을 고치면 이 제외를 푼다
            let candidates = (Self.exported + Self.extra).filter { reference.tracks[Self.path($0)] == nil && !removed.contains(Self.path($0)) }
            guard !candidates.isEmpty else { return false }
            let lists = reference.trackLists
            // 목록에 넣을 때는 한 곡만(여러 곡의 목록 순서는 엔진의 계획 순서라 기준 모델이 정하지 않는다)
            let target = lists.isEmpty || random.below(2) == 0 ? nil : random.pick(lists)
            var picked = [random.pick(candidates)]
            if target == nil, candidates.count > 1, random.below(2) == 0 { picked.append(random.pick(candidates.filter { $0 != picked[0] })) }
            for id in picked {
                let path = Self.path(id)
                reference.tracks[path] = Shape.Track(title: local[id]!.title, comment: local[id]!.comment)
                added.insert(path)
                if let target { reference.lists[target]!.entries.append(path) }
            }
            append(.addTracks(localContentIDs: picked, playlist: target.map { ref($0) }),
                   "USB에 곡 넣기 \(picked)" + (target.map { " → \(label($0))" } ?? ""))
            return true
        }

        mutating func removeTracks() -> Bool {
            let tracks = usableTracks
            // 곡을 둘 이상 남긴다(마지막 곡 빼기 막힘은 기존 시험이 본다)
            guard reference.tracks.count > 2, !tracks.isEmpty else { return false }
            let path = random.pick(tracks)
            reference.tracks[path] = nil
            removed.insert(path)
            for handle in reference.lists.keys { reference.lists[handle]!.entries.removeAll { $0 == path } }
            append(.removeTracks(usbContentIDs: [knownTracks[path]!]), "USB에서 곡 빼기 \(label(path: path))")
            return true
        }

        @discardableResult
        mutating func create(folder: Bool? = nil) -> Bool {
            let parent = random.pick([nil] + reference.folders.map(Optional.some))
            let isFolder = folder ?? (random.below(3) == 0)
            counter += 1
            let handle = "L\(counter)", name = (isFolder ? "합성 폴더 " : "합성 목록 ") + "\(seed)-\(counter)"
            reference.lists[handle] = Reference.List(name: name, parent: parent, isFolder: isFolder, entries: [])
            append(.playlist(edit: .create(key: handle, name: name, isFolder: isFolder, parent: ref(parent))),
                   "\(isFolder ? "폴더" : "목록") 만들기 \(handle)'\(name)' 부모 \(label(parent))")
            created.insert(handle)
            return true
        }

        mutating func rename() -> Bool {
            let handle = random.pick(reference.lists.keys.sorted())
            counter += 1
            let name = "합성 이름 \(seed)-\(counter)", note = "이름 바꾸기 \(label(handle)) → '\(name)'"
            append(.playlist(edit: .rename(playlist: ref(handle), name: name)), note)
            reference.lists[handle]!.name = name
            return true
        }

        /// 다른 부모(맨 위·폴더)로만, 목록 하나는 묶음에서 한 번만 옮긴다. 같은 부모로 되돌리는 옮기기는 순번만 바뀌어
        /// 기준 모델(이름·부모·곡 순서)로는 순효과를 가릴 수 없기 때문이다
        mutating func move() -> Bool {
            var options: [(handle: String, target: String?)] = []
            for handle in reference.lists.keys.sorted() where !moved.contains(handle) {
                let list = reference.lists[handle]!
                let inside = reference.descendants(of: handle).union([handle])
                for target in [nil] + reference.folders.map(Optional.some) where target != list.parent && !(target.map(inside.contains) ?? false) {
                    let clash = reference.lists.contains { $0.key != handle && $0.value.parent == target && $0.value.name == list.name }
                    if !clash { options.append((handle, target)) }
                }
            }
            guard !options.isEmpty else { return false }
            let (handle, target) = random.pick(options)
            append(.playlist(edit: .move(playlist: ref(handle), into: ref(target))), "옮기기 \(label(handle)) → \(label(target))")
            reference.lists[handle]!.parent = target
            moved.insert(handle)
            return true
        }

        mutating func addEntries() -> Bool {
            let lists = reference.trackLists, tracks = usableTracks
            guard !lists.isEmpty, !tracks.isEmpty else { return false }
            let handle = random.pick(lists)
            var paths = [random.pick(tracks)]
            if random.below(2) == 0 { paths.append(random.pick(tracks)) }
            append(.playlist(edit: .addTracks(playlist: ref(handle), contentIDs: paths.map { String(knownTracks[$0]!) })),
                   "목록에 곡 넣기 \(label(handle)) + \(paths.map { label(path: $0) })")
            reference.lists[handle]!.entries += paths
            return true
        }

        mutating func removeEntries() -> Bool {
            let usable = Set(usableTracks)
            var options: [(handle: String, index: Int)] = []
            for handle in reference.trackLists {
                for (index, path) in reference.lists[handle]!.entries.enumerated() where usable.contains(path) { options.append((handle, index)) }
            }
            guard !options.isEmpty else { return false }
            let (handle, index) = random.pick(options)
            let path = reference.lists[handle]!.entries[index]
            append(.playlist(edit: .removeTracks(playlist: ref(handle),
                                                 entries: [PlaylistEntry(trackNo: index + 1, contentID: String(knownTracks[path]!))])),
                   "목록에서 곡 빼기 \(label(handle)) \(index + 1)번째 \(label(path: path))")
            reference.lists[handle]!.entries.remove(at: index)
            return true
        }

        mutating func refresh() -> Bool {
            let tracks = usableTracks.filter { !refreshed.contains($0) }
            guard !tracks.isEmpty else { return false }
            let path = random.pick(tracks), id = localIDByPath[path]!
            counter += 1
            local[id]!.infoCount += 1
            local[id]!.title = "합성 갱신 \(seed)-\(counter)"
            local[id]!.comment = "합성 코멘트 \(seed)-\(counter)"
            reference.tracks[path] = Shape.Track(title: local[id]!.title, comment: local[id]!.comment)
            refreshed.insert(path)
            batch.localUpdates.append((id, local[id]!))
            append(.refreshTracks(usbContentIDs: [knownTracks[path]!], parts: [.info]), "곡 정보 갱신 \(id) → '\(local[id]!.title)'")
            return true
        }

        /// 순효과가 없는 묶음: 이름 A → B → A, 그 사이에 목록 끝에 곡을 넣고 그 자리를 다시 뺀다
        mutating func cancellingEdits() {
            let lists = knownLists.keys.sorted()
            let handle = random.pick(lists), original = reference.lists[handle]!.name
            counter += 1
            let temporary = "합성 잠깐 \(seed)-\(counter)"
            append(.playlist(edit: .rename(playlist: ref(handle), name: temporary)), "이름 바꾸기 \(label(handle)) → '\(temporary)'")
            reference.lists[handle]!.name = temporary
            let targets = lists.filter { !reference.lists[$0]!.isFolder }, tracks = usableTracks
            var entry: (handle: String, trackNo: Int, id: Int)?
            if !targets.isEmpty, !tracks.isEmpty {
                let target = random.pick(targets), path = random.pick(tracks)
                append(.playlist(edit: .addTracks(playlist: ref(target), contentIDs: [String(knownTracks[path]!)])),
                       "목록에 곡 넣기 \(label(target)) + \(label(path: path))")
                reference.lists[target]!.entries.append(path)
                entry = (target, reference.lists[target]!.entries.count, knownTracks[path]!)
            }
            append(.playlist(edit: .rename(playlist: ref(handle), name: original)), "이름 되돌리기 \(label(handle)) → '\(original)'")
            reference.lists[handle]!.name = original
            if let entry {
                append(.playlist(edit: .removeTracks(playlist: ref(entry.handle), entries: [PlaylistEntry(trackNo: entry.trackNo, contentID: String(entry.id))])),
                       "목록에서 곡 빼기 \(label(entry.handle)) \(entry.trackNo)번째")
                reference.lists[entry.handle]!.entries.removeLast()
            }
        }
    }
}
