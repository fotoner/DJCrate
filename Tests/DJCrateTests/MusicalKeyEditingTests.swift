@testable import DJCrate
import DJCApplication
import AppKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import DJCTestKit
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 태그의 키 고르기(#5): 인스펙터·시트가 Camelot 이름(1A~12B)과 "없음"에서만 고르고, DJCrate 추정은 제안으로만 보이며,
/// 목록에서도 같은 메뉴로 고른다. 추가한 곡의 키 기준은 빈칸(넣을 때 `KeyID` '0')이고, 고른 키는 곡을 넣을 때 함께 쓴다.
@Suite("태그 키 고르기", .serialized)
@MainActor
struct MusicalKeyEditingTests {
    static func row(_ id: String, key: String? = nil, staged: Bool = false, streaming: Bool = false) -> TrackRow {
        TrackRow(track: Track(id: staged ? "djc-\(id)" : id, uuid: "uuid-\(id)", title: "곡 \(id)", artist: "가수", album: nil, albumArtist: nil,
                              genre: nil, composer: nil, releaseYear: nil, trackNumber: nil, key: key, bpm: 120, lengthSeconds: 30,
                              folderPath: streaming ? "spotify:track:\(id)" : "/x/\(id).mp3", comment: "",
                              importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false,
                              dataStatus: staged || streaming ? nil : 0),
                 cues: [], playCount: 0)
    }

    func store() -> LibraryStore { LibraryStore.test(saveTagDrafts: { _ in }) }

    // MARK: 목록 칸 이름

    @Test func 목록의_키_칸은_기존_이름으로_키_태그를_고친다() {
        #expect(TrackListTagEditing.key(forColumn: "key") == .musicalKey)
        #expect(!TrackColumn.all.contains { $0.id == TagFields.Key.musicalKey.rawValue })
        // 저장된 열 배치·정렬 이름은 그대로 둔다.
        #expect(TrackColumn.all.first { $0.id == "key" } != nil)
    }

    // MARK: 고르기 규칙

    @Test func 고르기에서_옛_표기_값은_맨_앞에_보인다() {
        // 고를 수 있는 이름(없음·Camelot 24개)은 곡 목록 키 메뉴 시험(`TrackListKeyEditTests`)이 본다.
        #expect(KeyPicker.choices(current: "Em").first == "Em" && KeyPicker.choices(current: "").first == "1A")
    }

    @Test func 스트리밍_곡은_키를_고를_수_없고_추가한_곡은_고를_수_있다() throws {
        // 추가한 곡의 키는 곡을 rekordbox에 넣을 때 함께 쓴다(#5). 스트리밍 곡은 여전히 막는다.
        let staged = Self.row("1", staged: true), library = Self.row("2"), streaming = Self.row("3", streaming: true)
        #expect(KeyPicker.unavailableReason(library) == nil && KeyPicker.unavailableReason(staged) == nil)
        #expect(KeyPicker.unavailableReason(streaming) != nil)
        #expect(KeyPicker.targets([staged, library, streaming]).map(\.track.id) == ["djc-1", "2"])
        #expect(KeyPicker.isEditable([staged, streaming]) && !KeyPicker.isEditable([streaming]))
    }

    // MARK: 초안에 넣기

    @Test func 키를_고르면_키만_바뀐_초안이_생기고_같은_값은_초안을_만들지_않는다() throws {
        let store = store()
        let row = Self.row("1", key: "5A")
        store.setTag(.musicalKey, "5A", rows: [row])
        #expect(store.tagDrafts.isEmpty, "지금 값과 같으면 초안이 없다")
        store.setTag(.musicalKey, "8A", rows: [row])
        let draft = try #require(store.tagDrafts[row.track.uuid])
        #expect(draft.changedKeys == [.musicalKey] && draft.base.musicalKey == "5A" && draft.fields.musicalKey == "8A")
        #expect(store.tagCell(row, .musicalKey) == "8A" && store.isTagEdited(row, .musicalKey))
        store.setTag(.musicalKey, "", rows: [row])
        #expect(store.tagDrafts[row.track.uuid]?.fields.musicalKey == "")
        store.setTag(.musicalKey, "5A", rows: [row])
        #expect(store.tagDrafts.isEmpty, "처음 값으로 되돌리면 초안이 사라진다")
        // 입력은 Camelot 이름으로 다듬고 아니면 받지 않는다(조합은 Domain `MusicalKeyTagTests`)
        store.setTag(.musicalKey, "Am", rows: [row])
        #expect(store.tagDrafts.isEmpty)
        store.setTag(.musicalKey, " 12b ", rows: [row])
        #expect(store.tagDrafts[row.track.uuid]?.fields.musicalKey == "12B")
    }

    @Test func 추가한_곡의_키_기준은_빈칸이라_목록의_키를_골라도_초안이_된다() throws {
        // 목록의 키(음원 태그·DJCrate 추정 "8A")는 rekordbox 값이 아니다: 곡을 넣으면 `KeyID` '0'이다. 그 키를 고르면 고친 칸이어야
        // 넣을 때 쓰인다(기준이 "8A"이면 같은 값이라 초안이 생기지 않아 키가 조용히 빠진다).
        let store = store()
        let staged = Self.row("1", key: "8A", staged: true)
        #expect(staged.tagFields.musicalKey == "" && store.tagCell(staged, .musicalKey) == "")
        store.setTag(.musicalKey, "8A", rows: [staged])
        let draft = try #require(store.tagDrafts[staged.track.uuid])
        #expect(draft.changedKeys == [.musicalKey] && draft.base.musicalKey == "" && draft.fields.musicalKey == "8A")
        // 없음으로 되돌리면 할 일이 없다(넣는 곡은 처음부터 키가 없다)
        store.setTag(.musicalKey, "", rows: [staged])
        #expect(store.tagDrafts.isEmpty)
        // 다른 칸만 고친 초안의 키 기준도 빈칸이다
        store.setTag(.title, "새 제목", rows: [staged])
        #expect(store.tagDrafts[staged.track.uuid]?.changedKeys == [.title] && store.tagDrafts[staged.track.uuid]?.base.musicalKey == "")
    }

    @Test func 추가한_곡의_옛_초안은_목록의_키를_기준으로_들고_있어도_키를_고친_것이_아니다() throws {
        // 키를 고를 수 없던 때의 초안은 기준·내용 키가 목록의 키("8A")다. 지금 기준(빈칸)으로 맞춰 키를 고친 것으로 보지 않는다.
        let store = store()
        let staged = Self.row("1", key: "8A", staged: true)
        var legacy = TagDraft(trackUUID: staged.track.uuid, base: TagFields(track: staged.track))
        legacy.fields.title = "옛 제목"
        store.tagDrafts[staged.track.uuid] = legacy
        #expect(!store.isTagEdited(staged, .musicalKey) && store.tagCell(staged, .musicalKey) == "")
        #expect(store.confirmedStagedKey(uuid: staged.track.uuid) == nil)
        store.setTag(.musicalKey, "8A", rows: [staged])
        #expect(store.confirmedStagedKey(uuid: staged.track.uuid) == "8A")
    }

    @Test func 옛_표기_키를_가진_곡의_초안을_버리면_옛_표기_기준으로_돌아간다() throws {
        let store = store()
        let row = Self.row("1", key: "Em")
        store.setTag(.musicalKey, "8A", rows: [row])
        #expect(store.tagDrafts[row.track.uuid]?.changedKeys == [.musicalKey])
        store.revertTags(rows: [row])
        #expect(store.tagDrafts.isEmpty, "옛 표기 기준으로 되돌리는 것은 Camelot 이름이 아니어도 받는다")
        #expect(store.tagCell(row, .musicalKey) == "Em")
    }

    @Test func 여러_곡을_고르면_고칠_수_있는_곡만_고친다() throws {
        let store = store()
        let a = Self.row("1", key: "5A"), b = Self.row("2", key: "6A"), streaming = Self.row("3", streaming: true)
        let value = store.tagValue(.musicalKey, rows: [a, b])
        #expect(value.mixed)
        store.setTag(.musicalKey, "8A", rows: KeyPicker.targets([a, b, streaming]))
        #expect(store.tagDrafts.keys.sorted() == ["uuid-1", "uuid-2"])
        #expect(store.tagValue(.musicalKey, rows: [a, b]) == (value: "8A", mixed: false))
    }

    // MARK: 키 칸이 없던 옛 초안

    @Test func 옛_초안이_있는_곡도_키는_지금_값으로_보이고_다른_칸을_고쳐도_키_기준이_어긋나지_않는다() throws {
        let store = store()
        let row = Self.row("1", key: "5A")
        var legacy = TagDraft(trackUUID: row.track.uuid, base: TagFields(track: Self.row("1").track))   // 키 칸이 비어 있던 시절
        legacy.fields.title = "옛 초안 제목"
        store.tagDrafts[row.track.uuid] = legacy
        #expect(legacy.base.musicalKey == "" && store.tagCell(row, .musicalKey) == "5A", "고르기에는 지금 키가 보인다")
        #expect(!store.isTagEdited(row, .musicalKey))
        // 이어서 다른 칸을 고쳐도 키는 안 고친 칸이고 기준이 지금 값으로 맞춰진다
        store.setTag(.comment, "새 코멘트", rows: [row])
        let draft = try #require(store.tagDrafts[row.track.uuid])
        #expect(draft.changedKeys == [.title, .comment] && draft.base.musicalKey == "5A" && draft.fields.musicalKey == "5A")
        // 키를 고르면 지금 값이 기준이다(쓰기가 기준 어긋남으로 막지 않는다)
        store.setTag(.musicalKey, "8A", rows: [row])
        #expect(store.tagDrafts[row.track.uuid]?.base.musicalKey == "5A")
    }

    // MARK: DJCrate 추정은 제안이다

    @Test func 제안은_키가_빈_곡_하나에만_보이고_자동으로_초안을_만들지_않는다() throws {
        let store = store()
        let empty = Self.row("1"), keyed = Self.row("2", key: "5A"), staged = Self.row("3", staged: true), other = Self.row("4")
        func suggestion(_ rows: [TrackRow], estimate: String? = "8A") -> String? {
            KeyPicker.suggestion(estimate: estimate, rows: rows, current: store.tagValue(.musicalKey, rows: rows))
        }
        #expect(suggestion([empty]) == "8A")
        #expect(store.tagDrafts.isEmpty, "제안을 구하고 보여도 초안은 없다: 사용자가 눌러야 들어간다")
        #expect(store.tagCell(empty, .musicalKey) == "")
        #expect(suggestion([keyed]) == nil && suggestion([empty, other]) == nil)
        #expect(suggestion([staged]) == "8A", "추가한 곡도 키가 비었으면(넣을 때 '0') 제안한다")
        #expect(suggestion([empty], estimate: nil) == nil && suggestion([empty], estimate: "Am") == nil)
        // 사용자가 누르면(고르면) 그때 초안이 생긴다
        store.setTag(.musicalKey, "8A", rows: KeyPicker.targets([empty]))
        #expect(store.tagDrafts[empty.track.uuid]?.changedKeys == [.musicalKey])
    }

    @Test func 추가한_곡은_목록의_키를_제안으로만_보인다() {
        // 추가한 곡의 제안은 staged.json의 키(음원 태그 또는 DJCrate 추정)다. 덱 제안 줄이 그 키를 추정으로 넘기고, 눌러야 초안이 생긴다.
        let store = store()
        var estimated = Self.row("1", key: "8A", staged: true)
        estimated.keyEstimated = true
        let tagged = Self.row("2", key: "5A", staged: true), unknown = Self.row("3", staged: true)
        func suggestion(_ rows: [TrackRow]) -> String? {
            KeyPicker.suggestion(estimate: rows.first?.track.key, rows: rows, current: store.tagValue(.musicalKey, rows: rows))
        }
        #expect(suggestion([estimated]) == "8A" && suggestion([tagged]) == "5A" && suggestion([unknown]) == nil)
        #expect(KeyPicker.suggestionSource([estimated]) == .estimate && KeyPicker.suggestionSource([tagged]) == .fileTag)
        #expect(store.tagDrafts.isEmpty, "제안을 보여도 초안은 없다")
        store.setTag(.musicalKey, "8A", rows: [estimated])
        #expect(suggestion([estimated]) == nil, "고른 뒤에는 제안이 사라진다")
        // 여러 곡이면 제안하지 않는다
        #expect(suggestion([tagged, unknown]) == nil)
    }

    @Test(arguments: ["library", "estimate", "fileTag"])
    func 키_제안은_적용할_때만_초안을_만든다(source: String) throws {
        let suite = TestDefaults.suiteName("key-suggestion")
        let defaults = TestDefaults.open(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore.test(settings: SettingsStore(defaults: defaults, persist: false), saveTagDrafts: { _ in })
        var row = Self.row("suggestion", key: source == "library" ? nil : "8B", staged: source != "library")
        row.keyEstimated = source == "estimate"
        let estimate = source == "library" ? "8B" : row.track.key
        #expect(store.keySuggestion(estimate: estimate, rows: [row]) == "8B")
        #expect(store.tagDrafts.isEmpty && store.tagCell(row, .musicalKey).isEmpty)
        #expect(DeckSuggestion.key("8B", fromFileTag: KeyPicker.suggestionSource([row]) == .fileTag).value
                == (source == "fileTag" ? "8B (음원 태그)" : "8B"))
        store.applyKeySuggestion(estimate: estimate, rows: [row])
        let draft = try #require(store.tagDrafts[row.track.uuid])
        #expect(draft.changedKeys == [.musicalKey] && draft.fields.musicalKey == "8B")
        #expect(store.keySuggestion(estimate: estimate, rows: [row]) == nil)
    }

    @Test(arguments: [false, true])
    func 키_제안_무시는_곡별로_영속화하고_그리드_제안과_초안을_건드리지_않는다(staged: Bool) {
        let suite = TestDefaults.suiteName("key-ignore")
        let defaults = TestDefaults.open(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, persist: true)
        let store = LibraryStore.test(settings: settings, saveTagDrafts: { _ in })
        let row = Self.row("ignored", key: staged ? "8B" : nil, staged: staged), other = Self.row("other")
        settings.setStrings(SettingKeys.dismissedGridSuggestions, [other.track.uuid])
        store.dismissKeySuggestion(rows: [row])
        #expect(store.keySuggestion(estimate: "8B", rows: [row]) == nil)
        #expect(store.keySuggestion(estimate: "8B", rows: [other]) == "8B")
        #expect(store.tagDrafts.isEmpty)
        store.applyKeySuggestion(estimate: "8B", rows: [row])
        #expect(store.tagDrafts.isEmpty, "무시한 제안은 늦게 온 적용에서도 초안을 만들지 않는다")
        let reopened = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.open(suite), persist: true), saveTagDrafts: { _ in })
        #expect(reopened.keySuggestion(estimate: "8B", rows: [row]) == nil)
        #expect(settings.strings(SettingKeys.dismissedGridSuggestions) == [other.track.uuid])
        // 무시는 제안만 숨긴다. 직접 키를 고르는 길은 그대로다.
        reopened.setTag(.musicalKey, "5A", rows: [row])
        #expect(reopened.tagDrafts[row.track.uuid]?.fields.musicalKey == "5A")
    }

    @Test func 무시한_키_제안은_다시_보기로_되살리고_그리드_무시는_건드리지_않는다() {
        let suite = TestDefaults.suiteName("key-restore")
        let defaults = TestDefaults.open(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, persist: true)
        let store = LibraryStore.test(settings: settings, saveTagDrafts: { _ in })
        let row = Self.row("restore"), other = Self.row("other")
        settings.setStrings(SettingKeys.dismissedGridSuggestions, [row.track.uuid])
        #expect(store.dismissedKeySuggestion(estimate: "8B", rows: [row]) == nil, "무시하기 전에는 되살릴 것이 없다")
        store.restoreKeySuggestion(uuid: row.track.uuid)
        #expect(settings.strings(SettingKeys.dismissedKeySuggestions).isEmpty)
        store.dismissKeySuggestion(rows: [row])
        store.dismissKeySuggestion(rows: [other])
        #expect(store.keySuggestion(estimate: "8B", rows: [row]) == nil)
        #expect(store.dismissedKeySuggestion(estimate: "8B", rows: [row]) == "8B")
        store.restoreKeySuggestion(uuid: row.track.uuid)
        #expect(store.keySuggestion(estimate: "8B", rows: [row]) == "8B")
        #expect(store.dismissedKeySuggestion(estimate: "8B", rows: [row]) == nil)
        #expect(store.dismissedKeySuggestion(estimate: "8B", rows: [other]) == "8B", "다른 곡의 무시는 그대로")
        #expect(settings.strings(SettingKeys.dismissedKeySuggestions) == [other.track.uuid])
        #expect(settings.strings(SettingKeys.dismissedGridSuggestions) == [row.track.uuid], "그리드 제안의 무시는 건드리지 않는다")
        let reopened = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.open(suite), persist: true), saveTagDrafts: { _ in })
        #expect(reopened.keySuggestion(estimate: "8B", rows: [row]) == "8B" && reopened.keySuggestion(estimate: "8B", rows: [other]) == nil)
    }

    @Test func 다시_보기는_보일_제안이_남은_한_곡에만_있다() throws {
        let suite = TestDefaults.suiteName("key-restore-scope")
        let defaults = TestDefaults.open(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore.test(settings: SettingsStore(defaults: defaults, persist: false), saveTagDrafts: { _ in })
        let row = Self.row("scope"), second = Self.row("scope2"), streaming = Self.row("scope3", streaming: true)
        store.dismissKeySuggestion(rows: [row])
        store.dismissKeySuggestion(rows: [row, second])
        store.dismissKeySuggestion(rows: [streaming])
        #expect(store.dismissedKeySuggestion(estimate: "8B", rows: [row, second]) == nil, "여러 곡을 고르면 제안도 되살릴 것도 없다")
        #expect(store.dismissedKeySuggestion(estimate: "8B", rows: [streaming]) == nil, "키를 못 고치는 곡은 제안이 없다")
        #expect(store.dismissedKeySuggestion(estimate: nil, rows: [row]) == nil, "추정이 없으면 되살릴 것이 없다")
        #expect(store.dismissedKeySuggestion(estimate: "Am", rows: [row]) == nil, "Camelot 이름이 아닌 추정은 제안이 아니다")
        // 무시한 뒤 사용자가 키를 직접 골랐으면 되살릴 제안이 없다(죽은 다시 보기 단추를 보이지 않는다).
        store.setTag(.musicalKey, "5A", rows: [row])
        #expect(store.dismissedKeySuggestion(estimate: "8B", rows: [row]) == nil)
        store.setTag(.musicalKey, "", rows: [row])
        #expect(store.dismissedKeySuggestion(estimate: "8B", rows: [row]) == "8B", "키를 도로 비우면 무시한 제안을 다시 되살릴 수 있다")
    }

    @Test func 재분석은_그_곡의_키_제안_무시만_푼다() {
        let suite = TestDefaults.suiteName("key-reanalyze")
        let defaults = TestDefaults.open(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, persist: true)
        let store = LibraryStore.test(settings: settings, saveTagDrafts: { _ in })
        let row = Self.row("reanalyze"), other = Self.row("other-reanalyze")
        settings.setStrings(SettingKeys.dismissedGridSuggestions, [row.track.uuid])
        store.dismissKeySuggestion(rows: [row])
        store.dismissKeySuggestion(rows: [other])
        store.restoreKeySuggestion(uuid: row.track.uuid)
        #expect(store.keySuggestion(estimate: "8B", rows: [row]) == "8B", "메모리 사본도 같이 풀려야 화면이 바로 바뀐다")
        #expect(store.keySuggestion(estimate: "8B", rows: [other]) == nil)
        #expect(settings.strings(SettingKeys.dismissedKeySuggestions) == [other.track.uuid])
        #expect(settings.strings(SettingKeys.dismissedGridSuggestions) == [row.track.uuid])
        store.restoreKeySuggestion(uuid: "없는 곡")
        #expect(settings.strings(SettingKeys.dismissedKeySuggestions) == [other.track.uuid])
    }

    @Test(.enabled(if: LiveDraftHome.isIsolated))
    func 덱_재분석은_곡_UUID로_알려_키_제안_무시를_풀게_한다() {
        let deck = DeckModel.test(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        var notified: [String] = []
        deck.onReanalyze = { notified.append($0) }
        deck.reanalyze()
        #expect(notified.isEmpty, "곡이 없으면 알릴 것이 없다")
        let row = Self.row("deck-reanalyze-\(UUID().uuidString)")
        deck.row = row
        deck.reanalyze()
        #expect(notified == [row.track.uuid])
    }

    @Test func 키_제안_적용은_여러_곡과_편집_불가_곡과_잘못된_키를_받지_않는다() {
        let store = store()
        let row = Self.row("1"), other = Self.row("2"), streaming = Self.row("3", streaming: true)
        store.applyKeySuggestion(estimate: "8B", rows: [row, other])
        store.applyKeySuggestion(estimate: "8B", rows: [streaming])
        store.applyKeySuggestion(estimate: "Am", rows: [row])
        #expect(store.tagDrafts.isEmpty)
    }

    @Test func 키를_고른_추가한_곡은_넣기_미리_보기에_키를_담는다() async throws {
        // 곡을 넣을 때 고른 키도 같은 쓰기에서 쓴다(#5). 미리 보기(사본 시험 실행)가 키까지 보여 주고, 키 줄이 없으면 키만 막힌 것을 미리 알린다.
        let fixture = try RekordboxFixture()
        try fixture.add(TrackSpec())   // 라이브러리 공통값
        try fixture.insert("djmdKey", ["ID": .text("1486464042"), "ScaleName": .text("8A"), "Seq": .int(1), "UUID": .text("k-8a"),
                                       "rb_data_status": .int(256), "rb_local_deleted": .int(0), "rb_local_usn": .int(1)])
        let store = LibraryStore.test(settings: SettingsStore(defaults: TestDefaults.make("musicalkey"), persist: false),
                                 resultHistory: WriteResultHistory(url: nil), feedback: AppFeedback(announce: { _ in }),
                                 saveTagDrafts: { _ in }, backupDirectory: fixture.backups,
                                 playlistDraftSaver: { _ in }, mergeDraftSaver: { _ in }, playlistImportURL: nil, stagingSaver: { _ in },
                                 rekordboxDatabase: fixture.database, rekordboxShareRoot: fixture.shareRoot, arguments: ["test"], environment: [:],
                                 takeLiveSnapshot: { [database = fixture.database] _ in database })
        let path = try TestResources.url("mp3-notag-cbr.mp3").path
        let staged = try JSONDecoder().decode(StagedTrack.self, from: Data("""
            {"uuid":"\(UUID().uuidString)","path":"\(path)","title":"합성 추가 곡","comment":"","duration":2,"addedOn":"2026-10-04"}
            """.utf8))
        store.staged = [staged]
        let row = TrackRow(track: staged.track, cues: [], playCount: 0)
        store.setTag(.musicalKey, "8A", rows: [row])
        let preview = try await store.session.previewAdd(rows: [row])
        #expect(preview.plans.count == 1 && preview.unreadable.isEmpty)
        #expect(preview.keys == [path: "8A"] && preview.report.added.first?.keyWritten == "8A")
        let prompt = ReflectionPrompts.addConfirmation(preview, writesArtwork: true)
        #expect(prompt.details.contains { $0.contains("합성 추가 곡") && $0.contains("키 8A") }, "\(prompt.details)")
        // 분석 없이 넣는 곡에 키를 쓰면 DJCrate가 나중에 분석을 붙이지 못한다고 알린다
        #expect(prompt.details.contains { $0.contains("키를 함께 쓴") && $0.contains("rekordbox에서 분석") }, "\(prompt.details)")
        // 키 줄이 없는 키: 곡은 넣고 키만 막힌다고 미리 알린다
        store.setTag(.musicalKey, "12B", rows: [row])
        let blocked = try await store.session.previewAdd(rows: [row])
        #expect(blocked.plans.count == 1 && blocked.keys == [path: "12B"])
        #expect(blocked.report.added.first?.written == true && blocked.report.added.first?.keyReason?.contains("12B") == true)
        #expect(ReflectionPrompts.addConfirmation(blocked, writesArtwork: true).details.contains { $0.contains("키는 안 들어감") })
        // 키를 고르지 않은 곡은 키를 넘기지 않는다
        store.setTag(.musicalKey, "", rows: [row])
        #expect(try await store.session.previewAdd(rows: [row]).keys.isEmpty)
    }

    // MARK: 확인 창

    @Test func 확인_창은_키가_막힌_곡만_이유와_함께_보인다() throws {
        // Report는 안쪽 init이 없어 보고서 JSON으로 만든다(옛 보고서를 읽는 것과 같은 길)
        let json = """
            {"outcomes":[],"dryRun":true,"createdAt":"x","tagOutcomes":[
            {"trackUUID":"k","title":"곡 k","status":"written","removed":0,"added":1,"fields":["musicalKey"]},
            {"trackUUID":"m","title":"곡 m","status":"written","removed":0,"added":2,"fields":["title","musicalKey"]},
            {"trackUUID":"x","title":"곡 x","status":"blocked","reason":"rekordbox 키 목록에 '12B' 줄이 없습니다. rekordbox에서 이 곡의 키를 직접 고르세요","removed":0,"added":0}]}
            """
        let report = try JSONDecoder().decode(RekordboxWriter.Report.self, from: Data(json.utf8))
        // 쓰는 곡의 줄은 쓰기 결과에 남기고, 확인 창에는 막힌 곡과 이유만 보인다(#210)
        let prompt = ReflectionPrompts.confirmation(report)
        #expect(prompt.title == "태그 2곡을 rekordbox에 쓸까요?")
        #expect(prompt.details == ["쓰지 않는 것 1:", "• 곡 x: rekordbox 키 목록에 '12B' 줄이 없습니다. rekordbox에서 이 곡의 키를 직접 고르세요"])
    }

    @Test func XML로_내보낼_때는_키_초안이_있는_추가한_곡을_빼고_이유를_알린다() throws {
        // XML(Import To Collection)의 키(Tonality) 가져오기는 확인하지 않아 키 초안을 담지 않는다. 조용히 버리지 않고 그 곡을 빼고
        // 이유를 알린다(곡 넣기는 키를 함께 쓴다).
        let store = store()
        func staged(_ title: String) throws -> StagedTrack {
            try JSONDecoder().decode(StagedTrack.self, from: Data("""
                {"uuid":"\(UUID().uuidString)","path":"/fixtures/\(title).mp3","title":"\(title)","comment":"","duration":2,"addedOn":"2026-10-04"}
                """.utf8))
        }
        let keyed = try staged("키 초안 곡"), plain = try staged("키 초안 없는 곡")
        store.staged = [keyed, plain]
        var draft = TagDraft(track: keyed.track)
        draft.fields.musicalKey = "8A"
        store.tagDrafts[keyed.uuid] = draft
        let folder = FileManager.default.temporaryDirectory.appending(path: "djc-export-key-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = folder.appending(path: "staged.xml")
        let result = try store.exportStaged(to: url)
        #expect(result.count == 1 && result.skipped.count == 1)
        #expect(result.skipped.first?.contains("키 초안 곡") == true && result.skipped.first?.contains("XML") == true)
        #expect(result.skipped.first?.contains("rekordbox에 넣기") == true, "키까지 넣는 길을 알린다")
        let xml = try String(contentsOf: url, encoding: .utf8)
        #expect(xml.contains("키 초안 없는 곡") && !xml.contains("키 초안 곡"))

        // 키 초안이 있는 곡만 고르면 파일을 쓰지 않는다
        let alone = folder.appending(path: "alone.xml")
        let none = try store.exportStaged(to: alone, only: [keyed.id])
        #expect(none.count == 0 && none.skipped.count == 1)
        #expect(!FileManager.default.fileExists(atPath: alone.path))

        // 키 초안을 버리면 담긴다
        store.tagDrafts[keyed.uuid] = nil
        let all = try store.exportStaged(to: folder.appending(path: "all.xml"))
        #expect(all.count == 2 && all.skipped.isEmpty)
    }

    // MARK: 태그 시트

    @Test func 시트의_키_열은_보기_열과_같은_이름으로_정렬하고_태그_칸에_이어진다() throws {
        let column = try #require(SheetColumn.all.first { $0.key == .musicalKey })
        #expect(column.id == "key" && column.title == "키")
        #expect(TrackColumn.comparator(key: column.id, ascending: true) != nil)
    }

    @Test func 시트는_키_칸에_글자_편집기를_열지_않고_고르기_메뉴를_보인다() throws {
        let h = SheetKeyHarness()
        defer { h.window.close() }
        let column = h.keyColumn
        let menu = try #require(h.coordinator.keyMenu(row: 0))
        let titles = menu.items.map(\.title)
        #expect(titles == ["없음"] + KeyNotation.camelotNames, "키 없는 곡: 없음에 체크, 24개 이름")
        #expect(menu.items.first?.state == .on)
        let keyed = try #require(h.coordinator.keyMenu(row: 1))
        #expect(keyed.items.first { $0.state == .on }?.title == "5A")
        let legacy = try #require(h.coordinator.keyMenu(row: 2))
        #expect(legacy.items.first?.title == "Em" && legacy.items.first?.action == nil && legacy.items.first?.state == .on, "옛 표기는 고를 수 없는 현재 값")
        let staged = try #require(h.coordinator.keyMenu(row: 3), "추가한 곡도 메뉴로 고른다(넣을 때 함께 쓴다)")
        #expect(staged.items.first?.title == "없음" && staged.items.first?.state == .on)
        #expect(h.coordinator.editableKey(row: 3, column: column) == .musicalKey && h.coordinator.editableKey(row: 0, column: column) == .musicalKey)
        // 더블클릭·Return·타이핑이 시작하는 편집은 키 칸에서 글자 입력이 아니다(고를 수 없는 스트리밍 곡: 메뉴도 열리지 않는다)
        #expect(h.coordinator.keyMenu(row: 5) == nil && h.coordinator.editableKey(row: 5, column: column) == nil)
        h.coordinator.select(.init(row: 5, column: column), extend: false)
        h.coordinator.beginEditing()
        #expect(!h.coordinator.isEditing)
    }

    @Test func 시트에서_메뉴로_고른_키는_초안이_되고_같은_곡을_가리킨다() throws {
        let h = SheetKeyHarness()
        defer { h.window.close() }
        let menu = try #require(h.coordinator.keyMenu(row: 0))
        let item = try #require(menu.items.first { $0.title == "8A" })
        // 메뉴가 열려 있는 동안 줄 순서가 바뀌어도 고른 곡에 들어간다
        h.coordinator.update(rows: h.coordinator.rows.reversed(), revision: h.store.tagRevision + 1)
        h.coordinator.pickKey(item)
        #expect(h.store.tagDrafts["uuid-1"]?.changedKeys == [.musicalKey] && h.store.tagDrafts["uuid-1"]?.fields.musicalKey == "8A")
        #expect(h.store.tagDrafts.count == 1)
    }

    @Test func 시트_붙여넣기와_채우기는_Camelot_이름과_빈칸만_키_칸에_넣고_건너뛴_수를_알린다() throws {
        let h = SheetKeyHarness()
        defer { h.window.close() }
        var announced: [String] = []
        h.coordinator.announce = { announced.append($0) }
        let column = h.keyColumn
        // 한 값 붙이기: 소문자도 받는다
        h.coordinator.select(.init(row: 0, column: column), extend: false)
        h.coordinator.paste(string: "8a")
        #expect(h.store.tagCell(h.coordinator.rows[0], .musicalKey) == "8A")
        // Camelot이 아닌 값은 건너뛴다
        h.coordinator.select(.init(row: 1, column: column), extend: false)
        h.coordinator.paste(string: "Am")
        #expect(h.store.tagCell(h.coordinator.rows[1], .musicalKey) == "5A")
        #expect(announced.last?.contains("1A~12B") == true)
        // 채우기: 옛 표기(Em) 값을 아래 칸으로 채우려 해도 건너뛴다(가운데 줄은 추가한 곡이다)
        h.coordinator.select(.init(row: 2, column: column), extend: false)
        h.coordinator.select(.init(row: 4, column: column), extend: true)
        h.coordinator.fillDown()
        #expect(h.store.tagCell(h.coordinator.rows[2], .musicalKey) == "Em" && h.store.tagCell(h.coordinator.rows[3], .musicalKey) == "")
        #expect(h.store.tagCell(h.coordinator.rows[4], .musicalKey) == "" && announced.last?.contains("1A~12B") == true)
        // Delete: 빈칸은 받는다(키 지우기)
        h.coordinator.select(.init(row: 1, column: column), extend: false)
        h.coordinator.clearSelection()
        #expect(h.store.tagCell(h.coordinator.rows[1], .musicalKey) == "")
        #expect(h.store.tagDrafts["uuid-2"]?.changedKeys == [.musicalKey])
    }

    // MARK: 추가한 곡

    @Test func 곡_편집_결과의_태그_초안은_원곡의_키를_고친_칸으로_담지_않는다() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "djc-edit-stage-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let output = try AudioFixture.wav(seconds: 8, in: home, name: "원곡 (Edit).wav")
        let grid = [GridSegment(start: 0.5, bpm: 120, firstBeatNumber: 1)]
        let edit = try TrackEdit(grid: grid, sourceDuration: 100.5, bars: BarRange.list("1-4"))
        let source = Self.row("src", key: "5A").track
        let staged = try await StageEdit.put(output, grid: [edit.outputGrid], cues: [], source: source, home: home)
        let tags = try #require(TagDraftStore.load(trackUUID: staged.uuid, directory: home.appending(path: "tag-drafts")))
        #expect(!tags.changedKeys.contains(.musicalKey) && tags.fields.musicalKey == tags.base.musicalKey)
        #expect(tags.fields.title == "곡 src (Edit)")
    }
}

/// 키 있는 곡·없는 곡·옛 표기 곡·추가한 곡·스트리밍 곡이 든 시트
@MainActor
private final class SheetKeyHarness {
    let store = LibraryStore.test(saveTagDrafts: { _ in })
    let coordinator: SheetCoordinator
    let table = SheetTableView()
    let window: NSWindow
    let keyColumn: Int

    init() {
        _ = NSApplication.shared
        coordinator = SheetCoordinator(store: store)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        table.coordinator = coordinator
        coordinator.table = table
        table.delegate = coordinator
        table.dataSource = coordinator
        table.rowHeight = 22
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for spec in SheetColumn.all {
            let column = NSTableColumn(identifier: .init(spec.id))
            column.width = spec.width
            table.addTableColumn(column)
        }
        keyColumn = SheetColumn.all.firstIndex { $0.key == .musicalKey }!
        let scroll = NSScrollView()
        scroll.documentView = table
        window.contentView = scroll
        coordinator.update(rows: [MusicalKeyEditingTests.row("1"), MusicalKeyEditingTests.row("2", key: "5A"),
                                  MusicalKeyEditingTests.row("3", key: "Em"), MusicalKeyEditingTests.row("4", staged: true),
                                  MusicalKeyEditingTests.row("5"), MusicalKeyEditingTests.row("6", streaming: true)], revision: 0)
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
