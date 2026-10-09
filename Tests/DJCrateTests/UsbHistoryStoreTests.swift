import DJCDomain
import DJCStorage
import DJCTestSupport
import Foundation
import RekordboxKit
import Testing

/// USB 기기 재생 기록 보존(#43): USB 라이브러리에서 후보를 만들고, Mac 데이터 폴더(`usb-histories/`)에 기록마다 한 파일로 남긴다.
/// 시험은 임시 폴더만 쓴다(DJCPaths 기본 폴더·USB에는 쓰지 않는다). 곡 제목·경로·ID는 지어낸 값이다.
@Suite("USB 재생 기록 보존 저장소")
struct UsbHistoryStoreTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-10-09 00:00:00 UTC. 초 단위다(저장 날짜는 ISO 8601이라 초 아래를 버린다)
    static let now = Date(timeIntervalSince1970: 1_791_504_000)
    static let volumeKey = "SYNTH-USB-UUID"
    static let volumeName = "합성 USB"

    func temporaryHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "djc-usb-history-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 데이터 폴더(home) 아래 `usb-histories/`. 폴더는 저장할 때 생긴다
    func makeStore(_ home: URL) -> UsbHistoryStore {
        UsbHistoryStore(directory: home.appending(path: "usb-histories"), home: home)
    }

    /// damaged-drafts 아래로 옮겨진 파일
    func preserved(in home: URL) -> [URL] {
        let root = home.appending(path: DamagedDrafts.folderName)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { $0.pathExtension == "json" }
    }

    static func archived(_ suffix: String, sequence: Int = 1, historyID: Int = 1, id: String? = nil) -> ArchivedHistory {
        ArchivedHistory(
            id: id ?? ArchivedHistory.idPrefix + suffix, name: "HISTORY 2026-10-09", importedAt: now, sequence: sequence,
            source: ArchivedHistory.Source(volumeKey: volumeKey, volumeName: volumeName, format: UsbFormat.oneLibrary.rawValue,
                                           historyID: historyID, historyName: "HISTORY 00\(historyID)"),
            entries: [
                // masterDbId는 2³¹을 넘을 수 있다(64비트 그대로 남는지)
                ArchivedHistory.Entry(trackNumber: 1, usbContentID: 1, contentID: "501", title: "합성 곡 1", artist: "합성 아티스트",
                                      path: "/Contents/합성/test1.mp3", masterDbId: Int64(UInt32.max) + 7, masterContentId: 11,
                                      fileName: "test1.mp3"),
                ArchivedHistory.Entry(trackNumber: 2, usbContentID: 2, contentID: nil, title: "합성 곡 2", artist: nil,
                                      path: "/Contents/합성/test2.mp3", masterDbId: 1_000_001, masterContentId: 12, fileName: "test2.mp3"),
            ])
    }

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

    // MARK: - 저장소

    @Test func 저장한_기록을_날짜까지_그대로_다시_읽는다() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = makeStore(home)
        // 폴더가 없으면 빈 결과이고 폴더를 만들지 않는다
        #expect(store.load() == UsbHistoryStore.Loaded())
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))

        let first = Self.archived("A", sequence: 1), second = Self.archived("B", sequence: 2, historyID: 2)
        try store.save([second, first])
        let loaded = store.load()
        #expect(loaded.histories == [first, second])
        #expect(loaded.histories.first?.importedAt == Self.now)
        #expect(loaded.damaged.isEmpty)
        #expect(loaded.unreadable.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted() == ["usbhistory-A.json", "usbhistory-B.json"])

        // 같은 ID로 다시 쓰면 그 파일만 바뀐다
        var changed = first
        changed.entries[1].contentID = "502"
        try store.save([changed])
        #expect(store.load().histories == [changed, second])
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted() == ["usbhistory-A.json", "usbhistory-B.json"])
    }

    @Test func 읽지_못한_파일은_건너뛰고_지우거나_덮지_않고_damaged_drafts로_옮긴다() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = makeStore(home)
        let valid = Self.archived("A")
        try store.save([valid])
        let broken = Data("{\"깨진".utf8)
        try broken.write(to: store.directory.appending(path: "usbhistory-broken.json"))
        // 내용은 맞아도 파일 이름과 ID가 다르면 다음 저장이 다른 파일에 써서 같은 기록이 둘이 된다
        let copied = try Data(contentsOf: store.directory.appending(path: "usbhistory-A.json"))
        try copied.write(to: store.directory.appending(path: "usbhistory-copy.json"))
        // JSON이 아닌 파일은 건드리지 않는다
        try Data("메모".utf8).write(to: store.directory.appending(path: "memo.txt"))

        let loaded = store.load()
        #expect(loaded.histories == [valid])
        #expect(loaded.damaged == ["usbhistory-broken.json", "usbhistory-copy.json"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted() == ["memo.txt", "usbhistory-A.json"])
        // 데이터 폴더의 damaged-drafts/usb-histories/ 아래에 원문 그대로 있다
        let moved = preserved(in: home)
        #expect(moved.map { $0.deletingLastPathComponent().lastPathComponent } == ["usb-histories", "usb-histories"])
        let contents = try Set(moved.map { try Data(contentsOf: $0) })
        #expect(contents == [broken, copied])
        // 초안 손상 알림(초안용 문구)에는 넣지 않는다. 앱은 `damaged`로 따로 알린다
        #expect(DamagedDrafts.take(home: home).isEmpty)
        // 다시 읽으면 옮긴 파일은 더 나오지 않는다
        #expect(store.load() == UsbHistoryStore.Loaded(histories: [valid]))
    }

    @Test func 저장_전에_해석하지_못하는_파일은_옮기고_새_내용을_쓴다() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = makeStore(home)
        let history = Self.archived("A")
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let broken = Data("{\"깨진".utf8)
        try broken.write(to: store.directory.appending(path: "usbhistory-A.json"))
        try store.save([history])
        #expect(store.load() == UsbHistoryStore.Loaded(histories: [history]))
        #expect(preserved(in: home).map { try? Data(contentsOf: $0) } == [broken])
    }

    @Test func 저장_전에_파일명과_내용_ID가_다르면_원문을_옮기고_쓴다() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = makeStore(home)
        let first = Self.archived("A"), second = Self.archived("B")
        try store.save([first])
        let copied = try Data(contentsOf: store.directory.appending(path: first.id + ".json"))
        try copied.write(to: store.directory.appending(path: second.id + ".json"))
        #expect(!store.containsExact(second))
        try store.save([second])
        #expect(store.load().histories == [first, second])
        #expect(preserved(in: home).map { try? Data(contentsOf: $0) } == [copied])
    }

    @Test func 위험한_ID는_던지고_아무_파일도_쓰지_않는다() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = makeStore(home)
        let unsafe = ["../x", "x", ArchivedHistory.idPrefix, "usbhistory-../x", "usbhistory-a/b", "usbhistory-a.b", "usbhistory-a b",
                      "usbhistory-한글", ArchivedHistory.idPrefix + String(repeating: "a", count: 200)]
        for id in unsafe {
            let history = Self.archived("A", id: id)
            // 앞의 안전한 기록도 쓰지 않는다(모두 확인한 뒤에 쓴다)
            let error = #expect(throws: UsbHistoryStore.InvalidID.self) { try store.save([Self.archived("ok"), history]) }
            #expect(error?.id == id)
        }
        // 한 번에 같은 ID가 둘이면 하나가 조용히 덮이므로 던진다
        #expect(throws: UsbHistoryStore.InvalidID.self) { try store.save([Self.archived("A"), Self.archived("A", sequence: 2)]) }
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }

    @Test func 파일_읽기_실패는_이름을_알리고_원본과_다른_기록은_그대로_둔다() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = makeStore(home)
        let valid = Self.archived("A")
        try store.save([valid])
        let unreadable = store.directory.appending(path: "usbhistory-unreadable.json")
        // 파일 대신 폴더면 Data 읽기가 실패한다(실행 사용자 권한과 무관하게 재현)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: false)
        #expect(store.load() == UsbHistoryStore.Loaded(histories: [valid], unreadable: [unreadable.lastPathComponent]))
        #expect(FileManager.default.fileExists(atPath: unreadable.path))
        #expect(preserved(in: home).isEmpty)
    }

    @Test func 폴더_열거_실패는_빈_성공으로_숨기지_않는다() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = makeStore(home)
        try Data("폴더를_막은_파일".utf8).write(to: store.directory)
        #expect(store.load() == UsbHistoryStore.Loaded(unreadable: [store.directory.lastPathComponent]))
        #expect(try Data(contentsOf: store.directory) == Data("폴더를_막은_파일".utf8))
    }

    @Test func 폴더_접근_실패도_없는_폴더처럼_숨기지_않는다() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fs = FaultyUsbFileSystem(root: home)
        fs.failAt = (.stat, 1, .error)
        let store = UsbHistoryStore(directory: home.appending(path: "usb-histories"), home: home, fileSystem: fs)
        #expect(store.load() == UsbHistoryStore.Loaded(unreadable: [store.directory.lastPathComponent]))
    }

    @Test func 손상_파일을_옮기지_못해도_오류를_알리고_원문을_남긴다() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = makeStore(home)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("손상_보관_폴더를_막은_파일".utf8).write(to: home.appending(path: DamagedDrafts.folderName))
        let broken = Data("{깨진".utf8)
        let url = store.directory.appending(path: "usbhistory-broken.json")
        try broken.write(to: url)
        #expect(store.load() == UsbHistoryStore.Loaded(unreadable: [url.lastPathComponent]))
        #expect(try Data(contentsOf: url) == broken)
    }

    @Test func rename_뒤_폴더_fsync가_실패해도_같은_ID의_저장_내용을_확인한다() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fs = FaultyUsbFileSystem(root: home)
        fs.failAt = (.syncDirectory, 1, .error)
        let store = UsbHistoryStore(directory: home.appending(path: "usb-histories"), home: home, fileSystem: fs)
        var history = Self.archived("A")
        // 저장 날짜의 초 아래가 버려져도 같은 저장 내용으로 확인한다
        history.importedAt = history.importedAt.addingTimeInterval(0.25)
        #expect(throws: FaultyUsbFileSystem.InjectedFault.self) { try store.save([history]) }
        #expect(store.containsExact(history))
        let saved = try #require(store.load().histories.first)
        #expect(saved.id == history.id)
        #expect(saved.importedAt == Self.now)
        let candidate = UsbHistoryImport.Candidate(source: history.source, entries: history.entries)
        let plan = UsbHistoryImport.plan(existing: [saved], candidates: [candidate], reservedNames: [], now: Self.now,
                                         calendar: Self.calendar, makeID: { "new-uuid" })
        #expect(plan.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path) == [history.id + ".json"])
    }

    @Test func rename_전_실패나_다른_내용은_같은_ID라도_저장되었다고_하지_않는다() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fs = FaultyUsbFileSystem(root: home)
        let store = UsbHistoryStore(directory: home.appending(path: "usb-histories"), home: home, fileSystem: fs)
        let original = Self.archived("A")
        #expect(!store.containsExact(original))
        try store.save([original])
        var changed = original
        changed.entries[1].contentID = "502"
        fs.failAt = (.rename, 1, .error)
        #expect(throws: FaultyUsbFileSystem.InjectedFault.self) { try store.save([changed]) }
        #expect(!store.containsExact(changed))
        #expect(store.containsExact(original))
        #expect(!store.containsExact(Self.archived("other")))
        #expect(!store.containsExact(Self.archived("unsafe", id: "../outside")))
        #expect(store.load().histories == [original])
    }

    @Test func 여러_기록_저장_도중_실패하면_이미_놓인_파일만_같은_ID로_확인한다() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fs = FaultyUsbFileSystem(root: home)
        fs.failAt = (.syncDirectory, 2, .error)
        let store = UsbHistoryStore(directory: home.appending(path: "usb-histories"), home: home, fileSystem: fs)
        let all = [Self.archived("A", sequence: 1), Self.archived("B", sequence: 2), Self.archived("C", sequence: 3)]
        #expect(throws: FaultyUsbFileSystem.InjectedFault.self) { try store.save(all) }
        #expect(all.filter { store.containsExact($0) }.map(\.id) == [all[0].id, all[1].id])
        #expect(store.load().histories == Array(all.prefix(2)))
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

    // MARK: - 가져오기 흐름

    @Test func 후보를_계획해_저장한_뒤_같은_USB를_다시_읽으면_새로_보존할_것이_없다() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = makeStore(home)
        var counter = 0
        func plan(_ library: UsbLibrary, matches: [Int: String]) -> UsbHistoryImport.Plan {
            let candidates = UsbHistoryCandidates.make(library: library, volumeKey: Self.volumeKey, volumeName: Self.volumeName,
                                                       matches: matches)
            return UsbHistoryImport.plan(existing: store.load().histories, candidates: candidates, reservedNames: [],
                                         now: Self.now, calendar: Self.calendar) {
                counter += 1
                return "T\(counter)"
            }
        }

        let library = Self.library()
        let first = plan(library, matches: [1: "501"])
        #expect(first.added.map(\.source.historyID) == [3, 5, 1, 2])
        #expect(first.added.map(\.id) == ["usbhistory-T1", "usbhistory-T2", "usbhistory-T3", "usbhistory-T4"])
        #expect(first.added.map(\.name) == ["HISTORY 2026-10-09", "HISTORY 2026-10-09 (1)", "HISTORY 2026-10-09 (2)", "HISTORY 2026-10-09 (3)"])
        #expect(first.updated.isEmpty)
        try store.save(first.added + first.updated)
        let loaded = store.load()
        #expect(loaded.histories == first.added)
        #expect(loaded.damaged.isEmpty)

        // 같은 USB를 다시 읽으면 새로 보존할 것이 없다
        #expect(plan(library, matches: [1: "501"]).isEmpty)

        // 로컬 짝을 새로 알게 되면 곡 순서가 같은 보존본의 짝만 채워 같은 파일을 고친다. 곡 순서가 달라진 기록(같은 번호·이름을
        // 기기가 다시 쓴 것)은 옛 보존본을 고치지 않고 새로 보존한다
        var grown = library
        let index = try #require(grown.histories.firstIndex { $0.format == .oneLibrary && $0.id == 5 })
        grown.histories[index].entries.append(3)
        let second = plan(grown, matches: [1: "501", 2: "502"])
        #expect(second.added.map(\.id) == ["usbhistory-T5"])
        #expect(second.added.map(\.source.historyID) == [5])
        #expect(second.added.map(\.name) == ["HISTORY 2026-10-09 (4)"])
        #expect(second.updated.map(\.id) == ["usbhistory-T4"])
        try store.save(second.added + second.updated)
        let reloaded = store.load()
        #expect(reloaded.histories.map(\.id) == ["usbhistory-T1", "usbhistory-T2", "usbhistory-T3", "usbhistory-T4", "usbhistory-T5"])
        try #require(reloaded.histories.count == 5)
        #expect(reloaded.histories[1].entries.map(\.usbContentID) == [1, 2, 1])
        #expect(reloaded.histories[1].entries.map(\.contentID) == ["501", nil, "501"])
        #expect(reloaded.histories[2].entries.map(\.contentID) == [nil, nil])
        #expect(reloaded.histories[3].entries.map(\.contentID) == ["502", "501"])
        #expect(reloaded.histories[4].entries.map(\.usbContentID) == [1, 2, 1, 3])
        #expect(reloaded.histories[4].entries.map(\.contentID) == ["501", "502", "501", nil])
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count == 5)
        #expect(plan(grown, matches: [1: "501", 2: "502"]).isEmpty)
    }
}
