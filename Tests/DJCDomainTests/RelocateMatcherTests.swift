import DJCDomain
import Foundation
import Testing

/// 파일 없는 곡의 새 위치 후보 맞추기(#62): 파일 이름·확장자·길이·크기·태그로 점수를 매겨 확실·애매·없음으로 나눈다.
/// 읽기만 하는 순수 규칙이다. 기준과 허용 오차는 `RelocateRules`에 모여 있고 이 시험이 값을 고정한다.
@Suite("파일 없는 곡 후보 맞추기")
struct RelocateMatcherTests {
    /// 기본값은 모든 근거가 맞는 한 쌍이다(길이 200초·크기 5MB·제목·아티스트). 시험마다 바꿀 것만 준다.
    static func target(_ id: String = "1", name: String = "Song.mp3", title: String = "곡", artist: String? = "아티스트",
                       length: Int? = 200, size: Int64? = 5_000_000) -> RelocateTarget {
        RelocateTarget(id: id, title: title, artist: artist, oldPath: "/Volumes/Old/Music/\(name)", lengthSeconds: length, fileSize: size)
    }

    static func file(_ path: String = "/New/Music/Song.mp3", size: Int64 = 5_000_000, duration: Double? = 200.4,
                     title: String? = nil, artist: String? = nil) -> RelocateFile {
        RelocateFile(path: path, size: size, durationSeconds: duration, title: title, artist: artist)
    }

    static func outcome(_ target: RelocateTarget, _ files: [RelocateFile]) -> RelocateOutcome {
        RelocateMatcher.match(targets: [target], files: files).results[0].outcome
    }

    // MARK: 기준 상수

    @Test func 기준과_허용_오차를_고정한다() {
        #expect(RelocateRules.exactNamePoints == 40)
        #expect(RelocateRules.foldedNamePoints == 36)
        #expect(RelocateRules.stemOnlyPoints == 20)
        #expect(RelocateRules.sizePoints == 25)
        #expect(RelocateRules.durationPoints == 20)
        #expect(RelocateRules.titlePoints == 10)
        #expect(RelocateRules.artistPoints == 5)
        #expect(RelocateRules.durationToleranceSeconds == 2.0)
        #expect(RelocateRules.candidateScore == 40)
        #expect(RelocateRules.confidentScore == 80)
        #expect(RelocateRules.ambiguityGap == 10)
        #expect(RelocateRules.maxOptionsPerTrack == 5)
        // 모든 근거가 맞으면 100점이다(점수표가 어긋나면 기준 점수의 뜻이 달라진다).
        #expect(RelocateRules.exactNamePoints + RelocateRules.sizePoints + RelocateRules.durationPoints
                + RelocateRules.titlePoints + RelocateRules.artistPoints == 100)
    }

    // MARK: 근거와 점수

    @Test func 이름_크기_길이가_맞으면_85점이다() throws {
        let evidence = (RelocateMatcher.evidence(for: Self.target(), file: Self.file()))
        #expect(evidence.name == .exact)
        #expect(evidence.sameExtension)
        #expect(evidence.size == .equal)
        #expect(evidence.duration == .equal)
        #expect(evidence.title == .unknown)
        #expect(evidence.artist == .unknown)
        #expect(evidence.score == 85)
    }

    @Test func 제목과_아티스트_태그가_같으면_점수를_더한다() throws {
        let evidence = (RelocateMatcher.evidence(for: Self.target(), file: Self.file(title: "곡", artist: "아티스트")))
        #expect(evidence.title == .equal)
        #expect(evidence.artist == .equal)
        #expect(evidence.score == 100)
    }

    @Test func 태그는_정규화_대소문자_앞뒤_공백을_무시하고_비교한다() throws {
        let decomposed = "한글 Title".decomposedStringWithCanonicalMapping
        let target = Self.target(title: "한글 title", artist: "Artist")
        let evidence = (RelocateMatcher.evidence(for: target, file: Self.file(title: " \(decomposed) ", artist: "ARTIST")))
        #expect(evidence.title == .equal)
        #expect(evidence.artist == .equal)
    }

    @Test func 태그가_다르면_점수를_주지_않지만_후보에서_빼지도_않는다() throws {
        let evidence = (RelocateMatcher.evidence(for: Self.target(), file: Self.file(title: "다른 곡", artist: "다른 사람")))
        #expect(evidence.title == .different)
        #expect(evidence.artist == .different)
        #expect(evidence.score == 85)
    }

    @Test func 암호화된_제목과_빈_아티스트는_태그_근거에서_뺀다() throws {
        let target = Self.target(title: "$A7:abcdef", artist: "")
        let evidence = (RelocateMatcher.evidence(for: target, file: Self.file(title: "$A7:abcdef", artist: "x")))
        #expect(evidence.title == .unknown)
        #expect(evidence.artist == .unknown)
    }

    @Test func 파일_이름은_NFD와_NFC를_같게_본다() throws {
        let nfc = "한글 곡.mp3".precomposedStringWithCanonicalMapping
        let nfd = "한글 곡.mp3".decomposedStringWithCanonicalMapping
        // Swift의 String 비교는 정규화가 달라도 같다고 보므로, 시험 입력이 정말 다른 바이트인지는 유니코드 스칼라로 본다.
        #expect(Array(nfc.unicodeScalars) != Array(nfd.unicodeScalars))
        let evidence = (RelocateMatcher.evidence(for: Self.target(name: nfc), file: Self.file("/New/\(nfd)")))
        #expect(evidence.name == .exact)
        #expect(evidence.score == 85)
    }

    @Test func 대소문자만_다르면_36점을_준다() throws {
        let evidence = (RelocateMatcher.evidence(for: Self.target(name: "Song.mp3"), file: Self.file("/New/SONG.MP3")))
        #expect(evidence.name == .caseInsensitive)
        #expect(evidence.sameExtension)
        #expect(evidence.score == 81)
    }

    @Test func 이름은_같고_확장자만_다르면_20점을_주고_같은_확장자가_아니다() throws {
        let evidence = (RelocateMatcher.evidence(for: Self.target(name: "Song.flac"), file: Self.file("/New/Song.mp3")))
        #expect(evidence.name == .stemOnly)
        #expect(!evidence.sameExtension)
        #expect(evidence.score == 65)
    }

    @Test func 이름이_다르면_이름_점수가_없다() throws {
        let evidence = (RelocateMatcher.evidence(for: Self.target(name: "Song.mp3"), file: Self.file("/New/Other.mp3")))
        #expect(evidence.name == .different)
        #expect(evidence.score == 45)
    }

    @Test func 길이는_허용_오차_안이면_같고_밖이면_어긋난다() throws {
        // 곡 행의 길이는 초 단위로 버린 값이라 파일 길이가 1초 가까이 길 수 있다. 허용 오차는 2초(경계 포함).
        let target = Self.target(length: 200)
        #expect((RelocateMatcher.evidence(for: target, file: Self.file(duration: 202.0))).duration == .equal)
        #expect((RelocateMatcher.evidence(for: target, file: Self.file(duration: 198.0))).duration == .equal)
        #expect((RelocateMatcher.evidence(for: target, file: Self.file(duration: 202.01))).duration == .different)
        #expect((RelocateMatcher.evidence(for: target, file: Self.file(duration: 197.9))).duration == .different)
    }

    @Test func 길이나_크기를_모르면_근거로_세지_않는다() throws {
        let unknownTarget = Self.target(length: 0, size: 0)
        let a = (RelocateMatcher.evidence(for: unknownTarget, file: Self.file()))
        #expect(a.size == .unknown && a.duration == .unknown)
        let nilTarget = Self.target(length: nil, size: nil)
        let b = (RelocateMatcher.evidence(for: nilTarget, file: Self.file()))
        #expect(b.size == .unknown && b.duration == .unknown)
        let unreadable = (RelocateMatcher.evidence(for: Self.target(), file: Self.file(duration: nil)))
        #expect(unreadable.duration == .unknown)
        #expect(unreadable.score == 65)
        let zero = (RelocateMatcher.evidence(for: Self.target(), file: Self.file(duration: 0)))
        #expect(zero.duration == .unknown)
    }

    // MARK: 확실·애매·없음

    @Test func 이름_크기_길이가_모두_맞는_하나뿐인_후보는_확실하다() {
        guard case let .confident(candidate) = Self.outcome(Self.target(), [Self.file("/New/Music/Song.mp3")]) else {
            Issue.record("확실이어야 한다")
            return
        }
        #expect(candidate.file.path == "/New/Music/Song.mp3")
        #expect(candidate.score == 85)
    }

    @Test func 확실로_치는_가장_낮은_점수는_80점이다() {
        // 이름 36 + 크기 25 + 길이 20 = 81(대소문자만 다름) → 확실
        if case .confident = Self.outcome(Self.target(), [Self.file("/New/SONG.MP3")]) {} else { Issue.record("81점은 확실") }
        // 이름 40 + 크기 25 + 태그 15 = 80(길이를 읽지 못함) → 확실
        if case .confident = Self.outcome(Self.target(), [Self.file(duration: nil, title: "곡", artist: "아티스트")]) {} else { Issue.record("80점은 확실") }
        // 이름 40 + 길이 20 + 태그 15 = 75(크기가 다름) → 애매
        guard case let .ambiguous(reason, options) = Self.outcome(Self.target(), [Self.file(size: 5_000_123, title: "곡", artist: "아티스트")]) else {
            Issue.record("75점은 애매")
            return
        }
        #expect(reason == .weakEvidence)
        #expect(options.map(\.score) == [75])
    }

    @Test func 후보가_하나여도_근거가_모자라면_애매하다() {
        // 이름만 맞고 길이·크기를 모른다(40점)
        let target = Self.target(length: 0, size: 0)
        guard case let .ambiguous(reason, options) = Self.outcome(target, [Self.file()]) else {
            Issue.record("애매여야 한다")
            return
        }
        #expect(reason == .weakEvidence)
        #expect(options.count == 1)
    }

    @Test func 길이가_허용_오차를_넘는_같은_이름_파일은_후보가_아니다() {
        let outcome = Self.outcome(Self.target(), [Self.file(duration: 260)])
        #expect(outcome == .none)
    }

    @Test func 근거가_후보_기준_점수_밑이면_없음이다() {
        // 이름이 다르고 크기만 맞는 파일(25+20=45 → 후보). 크기도 다르면 20점뿐이라 후보가 아니다.
        #expect(Self.outcome(Self.target(), [Self.file("/New/Other.mp3", size: 1, duration: 200)]) == .none)
        if case .ambiguous = Self.outcome(Self.target(), [Self.file("/New/Other.mp3", duration: 200)]) {} else { Issue.record("크기+길이는 후보") }
    }

    @Test func 맞는_파일이_없으면_없음이다() {
        #expect(Self.outcome(Self.target(), []) == .none)
        #expect(Self.outcome(Self.target(), [Self.file("/New/Other.mp3", size: 1, duration: 10)]) == .none)
    }

    @Test func 이름_없이_크기_길이_태그만_맞는_파일은_애매한_후보다() {
        // 파일 이름을 바꾼 경우: 25+20+10+5 = 60
        guard case let .ambiguous(reason, options) = Self.outcome(Self.target(), [Self.file("/New/Renamed.mp3", title: "곡", artist: "아티스트")]) else {
            Issue.record("애매여야 한다")
            return
        }
        #expect(reason == .weakEvidence)
        #expect(options.map(\.score) == [60])
    }

    @Test func 확장자가_다르면_근거가_맞아도_확실로_올리지_않는다() {
        let target = Self.target(name: "Song.flac")
        guard case let .ambiguous(reason, options) = Self.outcome(target, [Self.file("/New/Song.mp3", title: "곡", artist: "아티스트")]) else {
            Issue.record("애매여야 한다")
            return
        }
        // 20 + 25 + 20 + 10 + 5 = 80이지만 확장자가 다르다
        #expect(options.first?.score == 80)
        #expect(reason == .differentExtension)
    }

    @Test func 같은_점수_후보가_둘이면_애매하다() {
        let files = [Self.file("/New/A/Song.mp3"), Self.file("/New/B/Song.mp3")]
        guard case let .ambiguous(reason, options) = Self.outcome(Self.target(), files) else {
            Issue.record("애매여야 한다")
            return
        }
        #expect(reason == .severalCandidates)
        #expect(options.map(\.file.path) == ["/New/A/Song.mp3", "/New/B/Song.mp3"])
    }

    @Test func 점수_차가_10점_안이면_같은_급으로_보고_애매하다() {
        // 85점과 81점(대소문자만 다름)
        let files = [Self.file("/New/A/SONG.MP3"), Self.file("/New/B/Song.mp3")]
        guard case let .ambiguous(reason, options) = Self.outcome(Self.target(), files) else {
            Issue.record("애매여야 한다")
            return
        }
        #expect(reason == .severalCandidates)
        #expect(options.map(\.score) == [85, 81])
    }

    @Test func 점수_차가_10점을_넘으면_높은_쪽이_확실하다() {
        // 85점과 크기가 다른 60점(이름+길이)
        let files = [Self.file("/New/B/Song.mp3", size: 4_000_000), Self.file("/New/A/Song.mp3")]
        guard case let .confident(candidate) = Self.outcome(Self.target(), files) else {
            Issue.record("확실이어야 한다")
            return
        }
        #expect(candidate.file.path == "/New/A/Song.mp3")
    }

    @Test func 점수가_정확히_10점_차이이면_같은_급이다() {
        // 이름 40+크기 25+길이 20 = 85, 이름 40+크기 25+태그 10(제목만) = 75 → 10점 차이
        let strong = Self.file("/New/A/Song.mp3")
        let tenLess = Self.file("/New/B/Song.mp3", duration: nil, title: "곡")
        let outcome = Self.outcome(Self.target(), [strong, tenLess])
        guard case let .ambiguous(reason, options) = outcome else {
            Issue.record("애매여야 한다")
            return
        }
        #expect(reason == .severalCandidates)
        #expect(options.map(\.score) == [85, 75])
    }

    @Test func 후보_목록은_점수_높은_순서이고_같으면_경로_순서이며_다섯_개까지만_준다() {
        let files = (1...8).map { Self.file("/New/\($0)/Song.mp3") }
        guard case let .ambiguous(_, options) = Self.outcome(Self.target(), files.reversed()) else {
            Issue.record("애매여야 한다")
            return
        }
        #expect(options.count == RelocateRules.maxOptionsPerTrack)
        #expect(options.map(\.file.path) == (1...5).map { "/New/\($0)/Song.mp3" })
    }

    // MARK: 여러 곡

    @Test func 한_파일을_두_곡이_같은_정도로_후보로_삼으면_둘_다_애매하다() {
        let targets = [Self.target("1"), Self.target("2")]
        let report = RelocateMatcher.match(targets: targets, files: [Self.file()])
        for result in report.results {
            guard case let .ambiguous(reason, options) = result.outcome else {
                Issue.record("곡 \(result.id)는 애매여야 한다")
                continue
            }
            #expect(reason == .sharedFile)
            #expect(options.count == 1)
        }
    }

    @Test func 한_파일을_두_곡이_후보로_삼아도_한쪽이_훨씬_잘_맞으면_그쪽만_확실하다() {
        // 곡 1: 크기·길이가 같음(85점). 곡 2: 같은 이름이고 길이만 허용 오차 안(60점) — 파일이 곡 1의 것이다.
        let strong = Self.target("1")
        let weak = Self.target("2", length: 201, size: 6_000_000)
        let report = RelocateMatcher.match(targets: [strong, weak], files: [Self.file()])
        if case .confident = report.results[0].outcome {} else { Issue.record("곡 1은 확실") }
        guard case let .ambiguous(reason, _) = report.results[1].outcome else {
            Issue.record("곡 2는 애매여야 한다")
            return
        }
        #expect(reason == .sharedFile)
    }

    @Test func 같은_이름이라도_크기와_길이로_가르면_각자_확실하다() {
        // 흔한 이름(01.mp3)이 여러 앨범 폴더에 있는 경우
        let a = Self.target("1", name: "01.mp3", length: 180, size: 4_000_000)
        let b = Self.target("2", name: "01.mp3", length: 240, size: 6_000_000)
        let files = [Self.file("/New/B/01.mp3", size: 6_000_000, duration: 240.2), Self.file("/New/A/01.mp3", size: 4_000_000, duration: 180.7)]
        let report = RelocateMatcher.match(targets: [a, b], files: files)
        guard case let .confident(first) = report.results[0].outcome, case let .confident(second) = report.results[1].outcome else {
            Issue.record("둘 다 확실이어야 한다")
            return
        }
        #expect(first.file.path == "/New/A/01.mp3")
        #expect(second.file.path == "/New/B/01.mp3")
    }

    @Test func 결과는_넘겨받은_곡_순서를_지키고_분류별_개수를_센다() {
        let targets = [Self.target("1"), Self.target("2", name: "Missing.mp3", length: 10, size: 1), Self.target("3", name: "Pair.mp3")]
        let files = [Self.file("/New/Song.mp3"), Self.file("/New/A/Pair.mp3"), Self.file("/New/B/Pair.mp3")]
        let report = RelocateMatcher.match(targets: targets, files: files)
        #expect(report.results.map(\.id) == ["1", "2", "3"])
        #expect(report.confidentCount == 1)
        #expect(report.ambiguousCount == 1)
        #expect(report.noneCount == 1)
        #expect(report.results.map(\.outcome.kind) == [.confident, .none, .ambiguous])
    }

    @Test func 곡도_파일도_없으면_빈_결과다() {
        #expect(RelocateMatcher.match(targets: [], files: [Self.file()]).results.isEmpty)
        #expect(RelocateMatcher.match(targets: [Self.target()], files: []).results.map(\.outcome.kind) == [.none])
    }

    // MARK: 미리 거르기

    @Test func 미리_거르기는_이름_줄기_크기_중_하나라도_맞는_파일만_통과시킨다() {
        let index = RelocateTargetIndex(targets: [Self.target("1", name: "Song.mp3", size: 5_000_000), Self.target("2", name: "Other.flac", size: 0)])
        #expect(index.mayMatch(fileName: "Song.mp3", size: 1))
        #expect(index.mayMatch(fileName: "song.MP3", size: 1))
        #expect(index.mayMatch(fileName: "Song.mp3".decomposedStringWithCanonicalMapping, size: 1))
        #expect(index.mayMatch(fileName: "Other.mp3", size: 1))
        #expect(index.mayMatch(fileName: "Renamed.mp3", size: 5_000_000))
        #expect(!index.mayMatch(fileName: "Renamed.mp3", size: 1))
        // 크기를 모르는(0) 곡 때문에 크기 0 파일이 통과하면 안 된다
        #expect(!index.mayMatch(fileName: "Renamed.mp3", size: 0))
    }
}

/// 사람이 고른 결과(곡 ↔ 후보). 확실한 곡은 기본으로 그 후보를 따르고, 애매한 곡은 사람이 고른다.
@Suite("후보 고르기")
struct RelocateSelectionTests {
    static func report() -> RelocateReport {
        let targets = [RelocateMatcherTests.target("1"), RelocateMatcherTests.target("2", name: "Pair.mp3"),
                       RelocateMatcherTests.target("3", name: "Nope.mp3", length: 5, size: 7)]
        let files = [RelocateMatcherTests.file("/New/Song.mp3"), RelocateMatcherTests.file("/New/A/Pair.mp3"),
                     RelocateMatcherTests.file("/New/B/Pair.mp3")]
        return RelocateMatcher.match(targets: targets, files: files)
    }

    @Test func 확실한_곡은_기본으로_그_후보를_고른_것으로_본다() {
        let selection = RelocateSelection(report: Self.report())
        #expect(selection.chosen(for: "1")?.file.path == "/New/Song.mp3")
        #expect(selection.chosen(for: "2") == nil)
        #expect(selection.chosen(for: "3") == nil)
        #expect(selection.chosenCount == 1)
    }

    @Test func 애매한_곡은_후보_안에서만_고를_수_있다() {
        var selection = RelocateSelection(report: Self.report())
        selection.choose("/New/B/Pair.mp3", for: "2")
        #expect(selection.chosen(for: "2")?.file.path == "/New/B/Pair.mp3")
        selection.choose("/New/Elsewhere.mp3", for: "2")
        #expect(selection.chosen(for: "2")?.file.path == "/New/B/Pair.mp3")
        selection.choose(nil, for: "2")
        #expect(selection.chosen(for: "2") == nil)
        // 없음인 곡은 고를 후보가 없다
        selection.choose("/New/Song.mp3", for: "3")
        #expect(selection.chosen(for: "3") == nil)
    }

    @Test func 확실한_곡도_고르기를_해제할_수_있다() {
        var selection = RelocateSelection(report: Self.report())
        selection.choose(nil, for: "1")
        #expect(selection.chosen(for: "1") == nil)
        #expect(selection.chosenCount == 0)
    }

    @Test func 한_파일이_두_곡의_후보이면_둘_다_고를_때_겹침으로_알린다() {
        let targets = [RelocateMatcherTests.target("1"), RelocateMatcherTests.target("2")]
        var selection = RelocateSelection(report: RelocateMatcher.match(targets: targets, files: [RelocateMatcherTests.file()]))
        selection.choose("/New/Music/Song.mp3", for: "1")
        #expect(selection.conflicts.isEmpty)
        selection.choose("/New/Music/Song.mp3", for: "2")
        #expect(selection.conflicts == ["/New/Music/Song.mp3": ["1", "2"]])
    }

    @Test func 고른_후보를_한_번에_구한_것은_곡마다_구한_것과_같다() {
        var selection = RelocateSelection(report: Self.report())
        selection.choose("/New/A/Pair.mp3", for: "2")
        let all = selection.chosenCandidates
        #expect(all.keys.sorted() == ["1", "2"])
        for id in ["1", "2", "3"] {
            #expect(all[id] == selection.chosen(for: id), "\(id)")
        }
    }
}

/// 폴더 훑기가 건너뛸 것: 숨은 파일·`._*`·rekordbox/DJCrate 데이터 폴더·USB의 PIONEER 폴더.
@Suite("후보 폴더 훑기 규칙")
struct RelocateScanPolicyTests {
    @Test func 숨은_파일과_AppleDouble은_건너뛴다() {
        #expect(RelocateScanPolicy.skipsName(".hidden.mp3"))
        #expect(RelocateScanPolicy.skipsName("._Song.mp3"))
        #expect(RelocateScanPolicy.skipsName(".DS_Store"))
        #expect(!RelocateScanPolicy.skipsName("Song.mp3"))
        #expect(!RelocateScanPolicy.skipsName("Song.hidden.mp3"))
    }

    @Test func USB의_PIONEER_폴더와_djprofile은_열지_않는다() {
        #expect(RelocateScanPolicy.skipsDirectory(named: "PIONEER"))
        #expect(!RelocateScanPolicy.skipsDirectory(named: "Pioneer DJ 곡"))
        #expect(!RelocateScanPolicy.skipsDirectory(named: "Contents"))
        #expect(RelocateScanPolicy.skipsFile(named: "djprofile.nxs"))
        #expect(!RelocateScanPolicy.skipsFile(named: "Song.mp3"))
    }

    @Test func PIONEER와_djprofile은_대소문자를_가리지_않는다() {
        // FAT USB에서는 `Pioneer`처럼 보일 수 있다
        for name in ["Pioneer", "pioneer", "PIONEER"] {
            #expect(RelocateScanPolicy.skipsDirectory(named: name), "\(name)")
        }
        #expect(RelocateScanPolicy.skipsFile(named: "DJPROFILE.NXS"))
    }

    @Test func 경로의_어느_구성_요소든_PIONEER면_USB_라이브러리_폴더다() {
        #expect(RelocateScanPolicy.isInsideUsbLibraryFolder("/Volumes/USB/PIONEER"))
        #expect(RelocateScanPolicy.isInsideUsbLibraryFolder("/Volumes/USB/PIONEER/extracted"))
        #expect(RelocateScanPolicy.isInsideUsbLibraryFolder("/Volumes/USB/Pioneer/CDP/"))
        #expect(RelocateScanPolicy.isInsideUsbLibraryFolder("/Volumes/USB/pioneer/rekordbox/share".decomposedStringWithCanonicalMapping))
        #expect(!RelocateScanPolicy.isInsideUsbLibraryFolder("/Volumes/USB"))
        #expect(!RelocateScanPolicy.isInsideUsbLibraryFolder("/Volumes/USB/Pioneer DJ 곡"))
        #expect(!RelocateScanPolicy.isInsideUsbLibraryFolder("/Volumes/PIONEERS/Music"))
    }

    @Test func 후보로_읽는_확장자는_rekordbox가_읽는_형식이다() {
        for ext in ["mp3", "MP3", "m4a", "aac", "mp4", "wav", "aif", "aiff", "flac", "alac"] {
            #expect(RelocateScanPolicy.isAudio(fileName: "a.\(ext)"), "\(ext)")
        }
        #expect(!RelocateScanPolicy.isAudio(fileName: "a.txt"))
        #expect(!RelocateScanPolicy.isAudio(fileName: "mp3"))
        #expect(!RelocateScanPolicy.isAudio(fileName: "a.mp3.part"))
    }

    @Test func 경로가_다른_경로_안에_있는지_구성_요소_단위로_본다() {
        #expect(RelocateScanPolicy.isInside("/home/dj/Library/RbData/rekordbox/share", root: "/home/dj/Library/RbData"))
        #expect(RelocateScanPolicy.isInside("/home/dj/Library/RbData", root: "/home/dj/Library/RbData"))
        #expect(RelocateScanPolicy.isInside("/home/dj/Library/RbData/", root: "/home/dj/Library/RbData"))
        // 이름만 접두가 같은 형제 폴더는 안이 아니다
        #expect(!RelocateScanPolicy.isInside("/home/dj/Library/RbData DJ", root: "/home/dj/Library/RbData"))
        #expect(!RelocateScanPolicy.isInside("/home/dj/Library", root: "/home/dj/Library/RbData"))
    }

    @Test func 임시_폴더의_private_표기와_NFD_표기를_같게_본다() {
        #expect(RelocateScanPolicy.isInside("/private/tmp/djc/Music", root: "/tmp/djc"))
        #expect(RelocateScanPolicy.isInside("/tmp/djc/Music", root: "/private/tmp/djc"))
        #expect(RelocateScanPolicy.isInside("/var/folders/x/한글".decomposedStringWithCanonicalMapping, root: "/private/var/folders/x/한글"))
    }

    @Test func 폴더_기준_상대_경로를_표기_차이와_상관없이_구한다() {
        #expect(RelocateScanPolicy.relativePath(of: "/Music/New/A/Song.mp3", in: "/Music/New") == "A/Song.mp3")
        #expect(RelocateScanPolicy.relativePath(of: "/Music/New/Song.mp3", in: "/Music/New/") == "Song.mp3")
        #expect(RelocateScanPolicy.relativePath(of: "/private/tmp/djc/한글/곡.mp3", in: "/tmp/djc") == "한글/곡.mp3")
        #expect(RelocateScanPolicy.relativePath(of: "/tmp/djc/한글/곡.mp3".decomposedStringWithCanonicalMapping, in: "/private/tmp/djc") == "한글/곡.mp3")
        // 폴더 밖·폴더 자신·이름만 접두가 같은 형제는 상대 경로가 없다
        #expect(RelocateScanPolicy.relativePath(of: "/Music/Other/Song.mp3", in: "/Music/New") == nil)
        #expect(RelocateScanPolicy.relativePath(of: "/Music/New", in: "/Music/New") == nil)
        #expect(RelocateScanPolicy.relativePath(of: "/Music/New-2/Song.mp3", in: "/Music/New") == nil)
    }

    @Test func 보호_폴더_안이거나_보호_폴더를_품은_경로를_가린다() {
        let protected = ["/home/dj/Library/RbData", "/home/dj/Library/Application Support/DJCrate"]
        #expect(RelocateScanPolicy.isProtected("/home/dj/Library/RbData/rekordbox", protectedRoots: protected))
        #expect(RelocateScanPolicy.isProtected("/home/dj/Library/Application Support/DJCrate/snapshots", protectedRoots: protected))
        #expect(!RelocateScanPolicy.isProtected("/home/dj/Music", protectedRoots: protected))
        // 홈 폴더처럼 보호 폴더를 품은 폴더는 고를 수 있다(훑을 때 보호 폴더만 건너뛴다)
        #expect(!RelocateScanPolicy.isProtected("/home/dj", protectedRoots: protected))
        #expect(RelocateScanPolicy.containsProtected("/home/dj", protectedRoots: protected))
        #expect(!RelocateScanPolicy.containsProtected("/home/dj/Music", protectedRoots: protected))
    }
}
