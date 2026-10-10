@testable import DJCrate
import AppKit
import DJCDomain
import Testing

/// 곡 목록에서 바로 태그를 고친다(#88): 칸·대상 곡·키 규칙과 표 흐름.
@Suite("곡 목록 바로 태그 편집")
@MainActor
struct TrackListTagEditTests {
    static func row(_ id: String, title: String? = nil, artist: String? = nil, comment: String = "",
                    year: Int? = nil, trackNumber: Int? = nil, streaming: Bool = false,
                    rule: (any CommentRule)? = nil) -> TrackRow {
        TrackRow(track: Track(id: id, uuid: "uuid-\(id)", title: title ?? "곡 \(id)", artist: artist, album: nil, albumArtist: nil,
                              genre: nil, composer: nil, releaseYear: year, trackNumber: trackNumber, key: nil, bpm: 120,
                              lengthSeconds: 180, folderPath: streaming ? "spotify:track:\(id)" : "/x/\(id).mp3", comment: comment,
                              importedOn: nil, analysisDataPath: nil, imagePath: nil, isDeleted: false, dataStatus: streaming ? nil : 0),
                 cues: [], playCount: 0, commentRule: rule)
    }

    // MARK: - 칸

    /// 앨범 아티스트·작곡가·연도·트랙 번호 칸은 처음엔 숨기고, 머리글 메뉴로 보이면 편집·정렬한다.
    @Test func 모든_태그_칸이_목록에_있고_새_칸은_처음에_숨긴다() throws {
        let ids = TrackColumn.all.map(\.id)
        // 키 태그(musicalKey)는 기존 목록 칸 이름("key")으로 편집한다.
        for key in TagFields.Key.allCases where key != .musicalKey { #expect(ids.contains(key.rawValue)) }
        #expect(ids.contains("key") && !ids.contains(TagFields.Key.musicalKey.rawValue))
        #expect(TrackColumn.hiddenByDefault == ["preview", "albumArtist", "composer", "year", "trackNumber"])
        for id in ["albumArtist", "composer", "year", "trackNumber"] {
            let spec = try #require(TrackColumn.all.first { $0.id == id })
            #expect(spec.sortKey.flatMap { TrackColumn.comparator(key: $0, ascending: true) } != nil)
        }
    }

    @Test func 연도와_트랙_번호는_숫자로_정렬한다() throws {
        let rows = [Self.row("1", year: 2001, trackNumber: 10), Self.row("2", trackNumber: 2), Self.row("3", year: 1999, trackNumber: 1)]
        let year = try #require(TrackColumn.comparator(key: "year", ascending: true))
        #expect(rows.sorted(using: year).map(\.track.id) == ["2", "3", "1"])
        let number = try #require(TrackColumn.comparator(key: "trackNumber", ascending: true))
        #expect(rows.sorted(using: number).map(\.track.id) == ["3", "2", "1"])
        #expect(TrackColumn.sortKey(of: year.keyPath) == "year")
        #expect(TrackColumn.sortKey(of: number.keyPath) == "trackNumber")
    }

    // MARK: - 대상 곡·값

    /// 인스펙터 여러 곡 편집과 같다: 고른 곡 안에서 고치면 고른 곡 모두에 적용한다.
    @Test func 누른_줄이_선택_안이면_고른_곡_모두가_대상이다() {
        let a = Self.row("1"), b = Self.row("2"), c = Self.row("3"), d = Self.row("4")
        #expect(TrackListTagEditing.targets(anchor: b, selection: [a, b, c]) == [a, b, c])
        #expect(TrackListTagEditing.targets(anchor: d, selection: [a, b, c]) == [d])
        // 재생 기록처럼 같은 곡이 여러 줄이어도 한 번만 고친다
        #expect(TrackListTagEditing.targets(anchor: a, selection: [a, b, a]) == [a, b])
    }

    @Test func 스트리밍_곡은_빼고_누른_곡이_스트리밍이면_편집하지_않는다() {
        let a = Self.row("1"), s = Self.row("9", streaming: true), b = Self.row("2")
        #expect(TrackListTagEditing.targets(anchor: a, selection: [a, s, b]) == [a, b])
        #expect(TrackListTagEditing.targets(anchor: s, selection: [a, s, b]).isEmpty)
    }

    @Test func 값이_다르면_빈_칸으로_시작하고_비운_채_나오면_그대로_둔다() throws {
        let a = Self.row("1"), b = Self.row("2")
        let session = try #require(TrackListTagEditing.Session(key: .title, targets: [a, b], value: { $0.track.title }))
        #expect(session.mixed && session.original.isEmpty)
        #expect(TrackListTagEditing.changes(session, committing: "").isEmpty)
        #expect(TrackListTagEditing.changes(session, committing: "같은 제목") == [a, b])
    }

    @Test func 같은_값이면_그_값으로_시작하고_그대로면_초안을_만들지_않는다() throws {
        let a = Self.row("1", artist: "A"), b = Self.row("2", artist: "A")
        let session = try #require(TrackListTagEditing.Session(key: .artist, targets: [a, b], value: { $0.artist }))
        #expect(!session.mixed && session.original == "A")
        #expect(TrackListTagEditing.changes(session, committing: "A").isEmpty)
        #expect(TrackListTagEditing.changes(session, committing: "B") == [a, b])
        #expect(TrackListTagEditing.Session(key: .artist, targets: [], value: { $0.artist }) == nil)
    }

    @Test func 목록_칸은_태그_초안_값을_보이고_바뀐_칸만_초안으로_표시한다() {
        let row = Self.row("1", title: "원래", artist: "A", year: 2001)
        #expect(TrackListTagEditing.text(row, .title, draft: nil) == ("원래", false))
        #expect(TrackListTagEditing.text(row, .year, draft: nil) == ("2001", false))
        var draft = TagDraft(track: row.track)
        draft.fields.title = "새 제목"
        #expect(TrackListTagEditing.text(row, .title, draft: draft) == ("새 제목", true))
        #expect(TrackListTagEditing.text(row, .artist, draft: draft) == ("A", false))
        // 암호화된 스트리밍 곡은 지금 목록 표시 그대로
        let spotify = TrackRow(track: Track(id: "s", uuid: "s", title: "$A7:v1:abc", artist: "$A7:v1:def", album: nil, albumArtist: nil,
                                            genre: nil, composer: nil, releaseYear: nil, trackNumber: nil, key: nil, bpm: nil,
                                            lengthSeconds: 0, folderPath: "spotify:track:s", comment: "", importedOn: nil,
                                            analysisDataPath: nil, imagePath: nil, isDeleted: false),
                               cues: [], playCount: 0)
        #expect(TrackListTagEditing.text(spotify, .title, draft: nil).text == spotify.title)
        #expect(TrackListTagEditing.text(spotify, .artist, draft: nil).text.isEmpty)
    }

    /// 코멘트 프리셋(#60)이 켜져 있으면 분류 칸은 초안 코멘트로 다시 가른다.
    @Test func 코멘트_초안이면_분류를_초안_코멘트로_다시_계산한다() throws {
        let rule = try #require(CommentPreset.anisong.rule)
        let row = Self.row("1", comment: "", rule: rule)
        var draft = TagDraft(track: row.track)
        draft.fields.title = "제목만 바꿈"
        #expect(TrackListTagEditing.commentEvaluation(row, draft: draft, rule: rule) == row.commentEvaluation)
        draft.fields.comment = "TVA 시험 OP 1"
        let evaluation = try #require(TrackListTagEditing.commentEvaluation(row, draft: draft, rule: rule))
        #expect(evaluation.isMatch && evaluation != row.commentEvaluation)
        #expect(TrackListTagEditing.commentEvaluation(row, draft: draft, rule: nil) == nil)
    }

    // MARK: - 키

    /// 편집 키(Return·Enter·Esc·Tab)는 덱 동작에 줄 수 없고 곡 목록에서 늘 표로 간다.
    @Test(arguments: [36, 76, 53, 48] as [UInt16])
    func 편집_키는_덱_단축키와_부딪히지_않는다(_ key: UInt16) {
        #expect(DeckShortcuts.isReserved(key))
        #expect(DeckShortcuts.standard.action(for: key) == nil)
        #expect(!KeyRoutingPolicy.accepts(key, in: .init(focus: .trackList)))
    }

    @Test func 칸_편집_중에는_덱_단축키가_칸으로_가고_확정_취소는_표가_처리한다() throws {
        let h = ListHarness(rows: [Self.row("1")], selection: ["1"])
        defer { h.close() }
        #expect(KeyRouter.focus(in: h.window) == .trackList)
        h.pressReturn()
        #expect(KeyRouter.focus(in: h.window) == .textInput)
        for key in KeyRoutingTests.deckKeys { #expect(!KeyRoutingPolicy.accepts(key, in: .init(focus: .textInput))) }
        // Return·Esc 뒤 포커스를 창(nil)으로 놓지 않고 표가 되찾는다(↑↓로 곡 고르기가 이어진다).
        #expect(KeyRouter.editsInTable(try #require(h.field)))
        let outside = NSTextField(string: "")
        h.window.contentView?.addSubview(outside)
        #expect(!KeyRouter.editsInTable(outside))
    }

    // MARK: - 표 흐름

    @Test func Return으로_제목을_고치고_Tab은_숨긴_칸을_건너뛰고_Esc는_취소한다() throws {
        let a = Self.row("1"), b = Self.row("2")
        let h = ListHarness(rows: [a, b], selection: [a.id], hidden: ["album"])
        defer { h.close() }
        h.pressReturn()
        #expect(h.coordinator.editingColumn == "title")
        #expect(h.editor?.string == "곡 1")
        h.type("새 제목")
        h.command(#selector(NSResponder.insertTab(_:)))
        #expect(h.store.tags.tagCell(a, .title) == "새 제목")
        #expect(h.coordinator.editingColumn == "artist")
        h.type("아티스트")
        h.command(#selector(NSResponder.cancelOperation(_:)))
        #expect(!h.coordinator.isEditing)
        #expect(h.store.tags.tagCell(a, .artist).isEmpty)
        #expect(h.window.firstResponder === h.table)
        #expect(h.table.selectedRowIndexes == [0])
        h.undo.undo()
        #expect(h.store.tagDrafts.isEmpty && !h.undo.canUndo)
    }

    @Test func 끝_칸에서_Tab은_확정하고_목록으로_돌아간다() throws {
        let a = Self.row("1")
        let h = ListHarness(rows: [a], selection: [a.id])
        defer { h.close() }
        #expect(h.coordinator.beginEditing(row: 0, column: "comment"))
        h.type("새 코멘트")
        h.command(#selector(NSResponder.insertTab(_:)))
        #expect(!h.coordinator.isEditing)
        #expect(h.window.firstResponder === h.table)
        #expect(h.store.tags.tagCell(a, .comment) == "새 코멘트")
        #expect(h.coordinator.beginEditing(row: 0, column: "comment"))
        h.command(#selector(NSResponder.insertBacktab(_:)))
        #expect(h.coordinator.editingColumn == "artist")
    }

    /// 다른 곳(검색창·인스펙터 등)을 눌러 칸을 벗어나면 확정하고 포커스는 누른 곳에 둔다(태그 시트와 같다).
    @Test func 다른_곳을_누르면_확정하고_그곳에_포커스를_둔다() throws {
        let a = Self.row("1")
        let h = ListHarness(rows: [a], selection: [a.id])
        defer { h.close() }
        h.pressReturn()
        h.type("밖을 눌러 확정")
        let other = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 20))
        h.window.contentView?.addSubview(other)
        #expect(h.window.makeFirstResponder(other))
        #expect(!h.coordinator.isEditing)
        #expect(h.store.tags.tagCell(a, .title) == "밖을 눌러 확정")
        #expect(h.window.firstResponder === other)
        #expect(h.cell(row: 0, column: "title")?.text == "밖을 눌러 확정")
    }

    @Test func 여러_곡을_고른_채_고치면_모두_바뀌고_한_번에_되돌린다() throws {
        let a = Self.row("1"), s = Self.row("9", streaming: true), b = Self.row("2")
        let h = ListHarness(rows: [a, s, b], selection: [a.id, s.id, b.id])
        defer { h.close() }
        h.pressReturn()
        #expect(h.coordinator.editingColumn == "title")
        #expect(h.editor?.string.isEmpty == true)
        #expect(h.field?.placeholderString == "(여러 값 — 입력하면 모두 바뀜)")
        // 비운 채 확정하면 그대로
        h.command(#selector(NSResponder.insertNewline(_:)))
        #expect(h.store.tagDrafts.isEmpty && !h.undo.canUndo)
        h.pressReturn()
        h.type("같은 제목")
        h.command(#selector(NSResponder.insertNewline(_:)))
        #expect(h.store.tags.tagCell(a, .title) == "같은 제목")
        #expect(h.store.tags.tagCell(b, .title) == "같은 제목")
        #expect(h.store.tagDrafts[s.track.uuid] == nil)
        #expect(h.table.selectedRowIndexes == [0, 1, 2])
        h.undo.undo()
        #expect(h.store.tagDrafts.isEmpty && !h.undo.canUndo)
    }

    @Test func 태그_칸만_편집하고_스트리밍_곡과_쓰는_중에는_막는다() throws {
        let a = Self.row("1"), s = Self.row("9", streaming: true)
        let h = ListHarness(rows: [a, s], selection: [a.id])
        defer { h.close() }
        #expect(!h.coordinator.beginEditing(row: 0, column: "bpm"))
        #expect(!h.coordinator.beginEditing(row: 1, column: "title"))
        h.store.isWritingRekordbox = true
        #expect(!h.coordinator.beginEditing(row: 0, column: "title"))
        h.pressReturn()
        #expect(!h.coordinator.isEditing)
        h.store.isWritingRekordbox = false
        #expect(h.coordinator.beginEditing(row: 0, column: "comment"))
        h.type("쓰기 전 입력")
        // 편집 중에 rekordbox 쓰기가 시작되면 입력을 버리고 칸을 닫는다
        h.store.isWritingRekordbox = true
        h.coordinator.updateWriteLock(true)
        #expect(!h.coordinator.isEditing)
        #expect(h.store.tagDrafts.isEmpty)
    }

    @Test func 고친_칸은_초안_값과_모서리_표식_VoiceOver_초안으로_보인다() throws {
        let a = Self.row("1", artist: "A")
        let h = ListHarness(rows: [a], selection: [a.id])
        defer { h.close() }
        h.pressReturn()
        h.type("새 제목")
        h.command(#selector(NSResponder.insertNewline(_:)))
        let title = try #require(h.cell(row: 0, column: "title"))
        #expect(title.text == "새 제목")
        #expect(title.showsDraftMark)
        #expect(spoken(title) == "새 제목, 초안")
        let artist = try #require(h.cell(row: 0, column: "artist"))
        #expect(!artist.showsDraftMark)
        #expect(spoken(artist) == "A")
        // 되돌리기·인스펙터처럼 다른 곳에서 바뀐 초안도 태그 번호가 바뀌면 다시 그린다
        h.undo.undo()
        h.coordinator.updateTagRevision(h.store.tagRevision)
        #expect(title.text == "곡 1")
        #expect(!title.showsDraftMark)
        #expect(spoken(title) == "곡 1")
    }

    @Test func 코멘트를_고치면_분류_칸을_다시_계산한다() throws {
        let store = ListHarness.store()
        store.commentPreset = .anisong
        let rule = try #require(store.commentPreset.rule)
        let a = Self.row("1", comment: "", rule: rule)
        let h = ListHarness(rows: [a], selection: [a.id], store: store)
        defer { h.close() }
        h.coordinator.updateCommentPreset(store.commentPreset)
        #expect(h.cell(row: 0, column: "class")?.text == rule.evaluate("").displayName)
        #expect(h.coordinator.beginEditing(row: 0, column: "comment"))
        h.type("TVA 시험 OP 1")
        h.command(#selector(NSResponder.insertNewline(_:)))
        let classCell = try #require(h.cell(row: 0, column: "class"))
        #expect(classCell.text == rule.evaluate("TVA 시험 OP 1").displayName)
        #expect(classCell.showsDraftMark)
    }

    private func spoken(_ cell: TrackTextCell) -> String? {
        let value = cell.label.accessibilityValue()
        return value
    }
}

/// 곡 목록 표 + 조정자 + 창. 칸은 목록과 같은 이름으로 몇 개만 둔다.
@MainActor
final class ListHarness {
    let store: LibraryStore
    let undo = UndoManager()
    let coordinator: TrackListCoordinator
    let table = TrackListTableView()
    let window: NSWindow

    /// 시험마다 따로 둔 설정(`UserDefaults.standard`에 남겨 다른 시험의 기본 설정을 바꾸지 않게)
    static func store() -> LibraryStore {
        LibraryStore.test(settings: SettingsStore(defaults: SettingsStoreTests.freshDefaults(), persist: false),
                     resultHistory: WriteResultHistory(url: nil), saveTagDrafts: { _ in })
    }

    /// - Parameter extra: 기본 칸 뒤에 더할 칸(평점·곡 색 칸 시험, #65)
    init(rows: [TrackRow], selection: Set<TrackRow.ID>, hidden: Set<String> = [], store: LibraryStore? = nil, showKey: Bool = false,
         extra: [String] = []) {
        _ = NSApplication.shared
        self.store = store ?? Self.store()
        undo.groupsByEvent = false
        self.store.undoManager = undo
        coordinator = TrackListCoordinator(store: self.store, actions: .live(store: self.store))
        // 다시 누른 칸 고치기는 마우스를 놓은 뒤에만 시작한다. 실제 마우스 상태(사용자가 시험 중에 누르는 것 등)에 시험이 흔들리지 않게 뗀 상태로 둔다.
        coordinator.isMouseDown = { false }
        table.identifier = KeyRouter.trackListID
        table.coordinator = coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        for id in ["index", "title", "album", "artist", "bpm", "key", "comment", "class"] + extra {
            let column = NSTableColumn(identifier: .init(id))
            column.width = 110
            column.isHidden = hidden.contains(id) || (id == "key" && !showKey)
            table.addTableColumn(column)
        }
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 900, height: 300))
        scroll.documentView = table
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scroll)
        coordinator.table = table
        coordinator.update(rows: rows, edited: [], selection: selection, sortOrder: [], snapshotURL: nil, previewRevision: 0)
        window.makeFirstResponder(table)
    }

    func close() { window.close() }

    var editor: NSTextView? { window.firstResponder as? NSTextView }
    var field: NSTextField? { editor?.delegate as? NSTextField }

    func pressReturn() {
        press(keyCode: 36, characters: "\r")
    }

    /// 칸을 누른 것처럼: mouseDown과 같은 길(`noteClick(at:)`)로 누른 자리를 기억한 뒤 그 줄을 고른다(super.mouseDown의 순서).
    /// 진짜 마우스 이벤트는 추적 루프에 들어가 mouseUp을 기다리므로 쓰지 않는다.
    func click(row: Int, column: String) {
        guard let index = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == column }) else { return }
        let rect = table.frameOfCell(atColumn: index, row: row)
        table.noteClick(at: NSPoint(x: rect.midX, y: rect.midY))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func pressDown() { press(keyCode: 125, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!)) }
    func pressUp() { press(keyCode: 126, characters: String(UnicodeScalar(NSUpArrowFunctionKey)!)) }

    func press(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        table.keyDown(with: event)
    }

    /// 편집 칸은 처음에 글자 전체가 골라져 있다. 친 글자로 바꾼다.
    func type(_ text: String) {
        guard let editor else { return }
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    func command(_ selector: Selector) {
        editor?.doCommand(by: selector)
    }

    func cell(row: Int, column: String) -> TrackTextCell? {
        view(row: row, column: column) as? TrackTextCell
    }

    func view(row: Int, column: String) -> NSView? {
        guard let index = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == column }) else { return nil }
        return table.view(atColumn: index, row: row, makeIfNecessary: true)
    }
}
