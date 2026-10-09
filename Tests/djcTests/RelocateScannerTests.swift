import DJCDomain
import DJCEnvironment
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing
@testable import djc

/// 후보 폴더 훑기(#62): 합성 음원과 합성 폴더 트리로만 시험한다(사용자 음원 폴더·rekordbox 라이브러리는 열지 않는다).
@Suite("후보 폴더 훑기")
struct RelocateScannerTests {
    /// 훑기가 들어가면 안 되는 자리를 모두 가진 합성 트리. 이름은 `root` 아래 상대 경로.
    struct Tree {
        let root: URL
        var music: URL { root.appending(path: "Music") }
        var outside: URL { root.appending(path: "Outside") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "djc-relocate-\(UUID().uuidString)")
            let fm = FileManager.default
            for dir in ["Music/A", "Music/B/sub", "Music/.hidden", "Music/PIONEER/Contents", "Music/Protected", "Music/Tools.app/Contents",
                        "Outside"] {
                try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
            }
            _ = try AudioFixture.wav(seconds: 3, in: music.appending(path: "A"), name: "Song One.wav")
            _ = try AudioFixture.wav(seconds: 4, in: music.appending(path: "B/sub"), name: "Song Two.wav")
            _ = try AudioFixture.wav(seconds: 1, in: music.appending(path: ".hidden"), name: "Hidden.wav")
            _ = try AudioFixture.wav(seconds: 1, in: music, name: ".Secret.wav")
            _ = try AudioFixture.wav(seconds: 1, in: music.appending(path: "PIONEER/Contents"), name: "Exported.wav")
            _ = try AudioFixture.wav(seconds: 1, in: music.appending(path: "Protected"), name: "Inside Data.wav")
            _ = try AudioFixture.wav(seconds: 1, in: music.appending(path: "Tools.app/Contents"), name: "Packaged.wav")
            _ = try AudioFixture.wav(seconds: 1, in: outside, name: "Outside.wav")
            // AppleDouble 찌꺼기는 내용이 음원이 아니어도 건너뛴다
            try Data("x".utf8).write(to: music.appending(path: "A/._Song One.wav"))
            try Data("memo".utf8).write(to: music.appending(path: "notes.txt"))
            // 링크는 파일이든 폴더든 따라가지 않는다
            try fm.createSymbolicLink(at: music.appending(path: "LinkedFolder"), withDestinationURL: outside)
            try fm.createSymbolicLink(at: music.appending(path: "LinkedFile.wav"), withDestinationURL: outside.appending(path: "Outside.wav"))
            // 한글 이름(NFD로 디스크에 둔다)
            _ = try AudioFixture.wav(seconds: 2, in: music, name: "한글 곡.wav".decomposedStringWithCanonicalMapping)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        var protectedRoots: [String] { [music.appending(path: "Protected").path] }

        func size(of relative: String) -> Int64 {
            Int64((try? FileManager.default.attributesOfItem(atPath: music.appending(path: relative).path)[.size] as? Int) ?? 0)
        }
    }

    /// 읽은 태그 호출을 세고, 읽는 값은 시험이 정한다.
    final class TagLog: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func record(_ url: URL) { lock.withLock { names.append(url.lastPathComponent) } }
        var read: [String] { lock.withLock { names.sorted() } }
    }

    static func target(_ id: String, name: String, length: Int?, size: Int64?, title: String = "곡") -> RelocateTarget {
        RelocateTarget(id: id, title: title, artist: nil, oldPath: "/Volumes/Old/\(name)", lengthSeconds: length, fileSize: size)
    }

    @Test func 음원만_모으고_숨은_파일_AppleDouble_링크_패키지_보호_폴더_PIONEER는_건너뛴다() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let root = tree.music.resolvingSymlinksInPath()
        let listed = try RelocateScanner.listAudioFiles(in: root, protectedRoots: tree.protectedRoots) { _ in }
        let names = listed.map { $0.url.lastPathComponent.precomposedStringWithCanonicalMapping }.sorted()
        #expect(names == ["Song One.wav", "Song Two.wav", "한글 곡.wav"])
        // 크기는 실제 파일 크기다
        #expect(listed.first { $0.url.lastPathComponent == "Song One.wav" }?.size == tree.size(of: "A/Song One.wav"))
    }

    @Test func 맞추기는_이름이나_크기가_맞는_파일만_태그를_읽는다() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let log = TagLog()
        let one = Self.target("1", name: "Song One.wav", length: 3, size: tree.size(of: "A/Song One.wav"))
        // 이름은 다르고 크기만 같은 파일(Song Two)도 읽는다
        let renamed = Self.target("2", name: "Other.wav", length: 4, size: tree.size(of: "B/sub/Song Two.wav"))
        let output = try await RelocateScanner.scan(targets: [one, renamed], folder: tree.music, protectedRoots: tree.protectedRoots,
                                                    readTags: { url in
                                                        log.record(url)
                                                        return RelocateScanner.Tags(duration: url.lastPathComponent == "Song One.wav" ? 3.0 : 4.0)
                                                    })
        #expect(log.read == ["Song One.wav", "Song Two.wav"])
        #expect(output.summary == RelocateScanner.Summary(audioFiles: 3, comparedFiles: 2))
        guard case let .confident(first) = output.report.results[0].outcome else {
            Issue.record("곡 1은 확실이어야 한다")
            return
        }
        #expect(first.file.name == "Song One.wav")
        // 이름이 달라도 크기·길이가 맞으면 애매한 후보다
        guard case let .ambiguous(reason, options) = output.report.results[1].outcome else {
            Issue.record("곡 2는 애매여야 한다")
            return
        }
        #expect(reason == .weakEvidence)
        #expect(options.map(\.file.name) == ["Song Two.wav"])
    }

    @Test func 실제_합성_음원의_길이를_읽어_후보를_맞춘다() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let target = Self.target("1", name: "Song One.wav", length: 3, size: tree.size(of: "A/Song One.wav"))
        let wrongLength = Self.target("2", name: "Song Two.wav", length: 60, size: nil)
        let output = try await RelocateScanner.scan(targets: [target, wrongLength], folder: tree.music, protectedRoots: tree.protectedRoots)
        #expect(output.report.results.map(\.outcome.kind) == [.confident, .none])
        guard case let .confident(candidate) = output.report.results[0].outcome else { return }
        #expect(candidate.evidence.duration == .equal)
        #expect(candidate.evidence.size == .equal)
        #expect(candidate.score == 85)
    }

    @Test func NFD로_디스크에_있는_한글_이름도_NFC_곡과_맞춘다() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let target = Self.target("1", name: "한글 곡.wav".precomposedStringWithCanonicalMapping, length: 2, size: tree.size(of: "한글 곡.wav".decomposedStringWithCanonicalMapping))
        let output = try await RelocateScanner.scan(targets: [target], folder: tree.music, protectedRoots: tree.protectedRoots)
        guard case let .confident(candidate) = output.report.results[0].outcome else {
            Issue.record("확실이어야 한다")
            return
        }
        #expect(candidate.evidence.name == .exact)
    }

    @Test func 링크_너머의_파일은_후보가_되지_않는다() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let target = Self.target("1", name: "Outside.wav", length: 1, size: nil)
        let output = try await RelocateScanner.scan(targets: [target], folder: tree.music, protectedRoots: tree.protectedRoots)
        #expect(output.report.results[0].outcome == .none)
        // 링크가 아닌 자기 폴더로 훑으면 찾는다
        let direct = try await RelocateScanner.scan(targets: [target], folder: tree.outside, protectedRoots: tree.protectedRoots)
        #expect(direct.report.results[0].outcome.kind != .none)
    }

    @Test func 보호_폴더와_폴더가_아닌_것은_고를_수_없다() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let target = Self.target("1", name: "Song One.wav", length: 3, size: nil)
        await #expect(throws: RelocateScanner.ScanError.protectedFolder) {
            _ = try await RelocateScanner.scan(targets: [target], folder: tree.music.appending(path: "Protected"), protectedRoots: tree.protectedRoots)
        }
        await #expect(throws: RelocateScanner.ScanError.protectedFolder) {
            _ = try await RelocateScanner.scan(targets: [target], folder: tree.music.appending(path: "Protected/deeper"),
                                               protectedRoots: tree.protectedRoots)
        }
        await #expect(throws: RelocateScanner.ScanError.notAFolder) {
            _ = try await RelocateScanner.scan(targets: [target], folder: tree.music.appending(path: "notes.txt"), protectedRoots: tree.protectedRoots)
        }
        await #expect(throws: RelocateScanner.ScanError.notAFolder) {
            _ = try await RelocateScanner.scan(targets: [target], folder: tree.music.appending(path: "없는 폴더"), protectedRoots: tree.protectedRoots)
        }
    }

    @Test func 고른_폴더가_PIONEER이거나_그_안이면_열지_않고_거부한다() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let fm = FileManager.default
        // USB 루트의 PIONEER 아래 extracted·CDP는 열거하지 않는 규칙이다(UsbLayout.neverRead)
        let usb = tree.root.appending(path: "USB")
        for dir in ["PIONEER/extracted", "PIONEER/CDP", "Pioneer-lower/Pioneer/rekordbox"] {
            try fm.createDirectory(at: usb.appending(path: dir), withIntermediateDirectories: true)
        }
        _ = try AudioFixture.wav(seconds: 1, in: usb.appending(path: "PIONEER/extracted"), name: "Extracted.wav")
        let target = Self.target("1", name: "Extracted.wav", length: 1, size: nil)
        for folder in [usb.appending(path: "PIONEER"), usb.appending(path: "PIONEER/extracted"), usb.appending(path: "PIONEER/CDP"),
                       usb.appending(path: "Pioneer-lower/Pioneer"), usb.appending(path: "Pioneer-lower/Pioneer/rekordbox")] {
            let read = TagLog()
            await #expect(throws: RelocateScanner.ScanError.usbLibraryFolder, "\(folder.lastPathComponent)") {
                _ = try await RelocateScanner.scan(targets: [target], folder: folder, protectedRoots: tree.protectedRoots,
                                                   readTags: { url in read.record(url); return RelocateScanner.Tags() })
            }
            #expect(read.read.isEmpty)
        }
        // 링크로 PIONEER 안을 가리켜도 거부한다
        let link = tree.root.appending(path: "ToExtracted")
        try fm.createSymbolicLink(at: link, withDestinationURL: usb.appending(path: "PIONEER/extracted"))
        await #expect(throws: RelocateScanner.ScanError.usbLibraryFolder) {
            _ = try await RelocateScanner.scan(targets: [target], folder: link, protectedRoots: tree.protectedRoots)
        }
        // 이름에 Pioneer가 들어가기만 한 폴더는 고를 수 있다
        let output = try await RelocateScanner.scan(targets: [target], folder: usb.appending(path: "Pioneer-lower"),
                                                    protectedRoots: tree.protectedRoots)
        #expect(output.summary.audioFiles == 0)
        // 사용자에게 보이는 이유는 무엇을 하면 되는지까지 적는다
        #expect(RelocateScanner.ScanError.usbLibraryFolder.errorDescription?.isEmpty == false)
    }

    @Test func 하위의_소문자_Pioneer_폴더도_건너뛴다() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let lower = tree.music.appending(path: "B/Pioneer/Contents")
        try FileManager.default.createDirectory(at: lower, withIntermediateDirectories: true)
        _ = try AudioFixture.wav(seconds: 1, in: lower, name: "Lower.wav")
        let listed = try RelocateScanner.listAudioFiles(in: tree.music.resolvingSymlinksInPath(), protectedRoots: tree.protectedRoots) { _ in }
        #expect(!listed.map(\.url.lastPathComponent).contains("Lower.wav"))
        #expect(listed.count == 3)
    }

    @Test func 링크로_보호_폴더를_가리켜도_고를_수_없다() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let link = tree.root.appending(path: "ShortCut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tree.music.appending(path: "Protected"))
        await #expect(throws: RelocateScanner.ScanError.protectedFolder) {
            _ = try await RelocateScanner.scan(targets: [], folder: link, protectedRoots: tree.protectedRoots)
        }
    }

    @Test func 기본_보호_폴더에_실제_rekordbox_폴더와_DJCrate_데이터_폴더가_든다() {
        let roots = RelocateScanner.protectedRoots.map { URL(filePath: $0).standardizedFileURL.path }
        #expect(roots.contains(LibrarySnapshot.realRekordboxDirectory.standardizedFileURL.path))
        #expect(roots.contains(LibrarySnapshot.realRekordboxDirectory.deletingLastPathComponent().standardizedFileURL.path))
        #expect(roots.contains(DJCIdentity.userSupportDirectory.standardizedFileURL.path))
        #expect(roots.contains(DJCIdentity.dataDirectory.standardizedFileURL.path))
        #expect(roots.contains(LibrarySnapshot.rekordboxDirectory.standardizedFileURL.path))
    }

    @Test func 폴더_안에_보호_폴더를_품은_폴더를_고르면_보호_폴더만_건너뛴다() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let target = Self.target("1", name: "Inside Data.wav", length: 1, size: nil)
        // Music 전체를 훑어도 Protected 안의 음원은 후보가 아니다
        let output = try await RelocateScanner.scan(targets: [target], folder: tree.music, protectedRoots: tree.protectedRoots)
        #expect(output.report.results[0].outcome == .none)
        #expect(output.summary.audioFiles == 3)
    }

    @Test func 취소하면_CancellationError로_멈춘다() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let target = Self.target("1", name: "Song One.wav", length: 3, size: nil)
        let task = Task {
            try await RelocateScanner.scan(targets: [target], folder: tree.music, protectedRoots: tree.protectedRoots,
                                           readTags: { _ in
                                               try? await Task.sleep(for: .seconds(60))
                                               return RelocateScanner.Tags()
                                           })
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test @MainActor func 메인_스레드에서_불러도_훑기와_진행_알림은_메인_스레드_밖에서_돈다() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let target = Self.target("1", name: "Song One.wav", length: 3, size: tree.size(of: "A/Song One.wav"))
        let onMain = Locked<[Bool]>([])
        _ = try await RelocateScanner.scan(targets: [target], folder: tree.music, protectedRoots: tree.protectedRoots,
                                           progress: { _ in onMain.withLock { $0.append(Thread.isMainThread) } })
        let seen = onMain.withLock { $0 }
        #expect(!seen.isEmpty)
        #expect(!seen.contains(true))
    }

    @Test func 진행_알림은_찾기_읽기_맞추기_순서로_온다() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let target = Self.target("1", name: "Song One.wav", length: 3, size: nil)
        let phases = Locked<[RelocateScanner.Progress.Phase]>([])
        _ = try await RelocateScanner.scan(targets: [target], folder: tree.music, protectedRoots: tree.protectedRoots,
                                           progress: { progress in phases.withLock { if $0.last != progress.phase { $0.append(progress.phase) } } })
        #expect(phases.withLock { $0 } == [.listing, .reading, .matching])
    }

    // MARK: 곡 목록 만들기

    @Test func 곡_목록은_스트리밍_곡을_빼고_곡_행의_파일_크기를_붙인다() throws {
        let fixture = try RekordboxFixture()
        var local = TrackSpec(id: "1")
        local.title = "로컬 곡"
        local.folderPath = "/Volumes/Old/Local.mp3"
        local.length = 123
        try fixture.add(local)
        var streaming = TrackSpec(id: "2")
        streaming.folderPath = "apple-music:42"
        try fixture.add(streaming)
        try fixture.execute("UPDATE djmdContent SET FileSize = 4242 WHERE ID = '1'")
        let tracks = try RekordboxLibrary.load(snapshot: fixture.database).tracks
        let targets = try RelocateScanner.targets(for: tracks, snapshot: fixture.database)
        #expect(targets.map(\.id) == ["1"])
        #expect(targets[0].fileSize == 4242)
        #expect(targets[0].lengthSeconds == 123)
        #expect(targets[0].fileName == "Local.mp3")
    }

    // MARK: lab 명령의 출력

    @Test func lab_출력은_개수만_찍고_곡_제목과_경로를_찍지_않는다() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let one = Self.target("1", name: "Song One.wav", length: 3, size: tree.size(of: "A/Song One.wav"), title: "비밀 제목")
        let none = Self.target("2", name: "Missing.wav", length: 10, size: 1, title: "또 다른 제목")
        let output = try await RelocateScanner.scan(targets: [one, none], folder: tree.music, protectedRoots: tree.protectedRoots)
        let lines = RelocateLab.summaryLines(targets: 2, output: output)
        #expect(lines.count == 3)
        #expect(lines[1] == "확실 1 · 애매 0 · 없음 1")
        let text = lines.joined(separator: "\n")
        for secret in ["비밀 제목", "또 다른 제목", "Song One", "Missing", tree.root.lastPathComponent, "Volumes"] {
            #expect(!text.contains(secret), "\(secret)")
        }
    }

    @Test func lab_명령은_사본_DB와_폴더_인자가_모두_있어야_한다() async throws {
        await #expect(throws: UsageError.self) { try await RelocateLab.candidates([]) }
        await #expect(throws: UsageError.self) { try await RelocateLab.candidates(["--db", "/tmp/x.db"]) }
        await #expect(throws: UsageError.self) { try await RelocateLab.candidates(["--folder", "/tmp"]) }
    }
}

/// 시험용 잠금 상자
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}
