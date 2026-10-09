import AppKit
import DJCDomain
import Foundation

struct TrackColumn {
    let id: String
    let title: String
    let width: CGFloat
    var minWidth: CGFloat = 18
    var flexible = false
    /// nil이면 정렬하지 않는다.
    var sortKey: String?
    /// 머리글을 처음 눌렀을 때 오름차순인지(숫자·날짜는 큰 값부터가 쓸모 있다).
    var ascendingFirst = true
    var help = ""

    static let all: [TrackColumn] = [
        TrackColumn(id: "index", title: "#", width: 48, minWidth: 48, help: String(ui: "지금 목록에서 몇 번째 곡인지")),
        TrackColumn(id: "thumb", title: String(ui: "앨범아트"), width: 26, minWidth: 26, help: String(ui: "앨범아트")),
        TrackColumn(id: "edited", title: String(ui: "초안"), width: 18, minWidth: 18, help: String(ui: "DJCrate 초안이 있는 곡 (rekordbox·파일에 쓰기 전)")),
        TrackColumn(id: "title", title: String(ui: "제목"), width: 220, minWidth: 140, flexible: true, sortKey: "title"),
        TrackColumn(id: "preview", title: String(ui: "미리 보기"), width: 160, minWidth: 80,
                    help: String(ui: "곡 전체 파형과 핫큐·메모리 큐·루프 위치")),
        TrackColumn(id: "artist", title: String(ui: "아티스트"), width: 140, minWidth: 80, flexible: true, sortKey: "artist"),
        TrackColumn(id: "album", title: String(ui: "앨범"), width: 150, minWidth: 60, flexible: true, sortKey: "album"),
        TrackColumn(id: "albumArtist", title: String(ui: "앨범 아티스트"), width: 120, minWidth: 60, flexible: true, sortKey: "albumArtist"),
        TrackColumn(id: "composer", title: String(ui: "작곡가"), width: 110, minWidth: 60, flexible: true, sortKey: "composer"),
        TrackColumn(id: "year", title: String(ui: "연도"), width: 46, minWidth: 38, sortKey: "year", ascendingFirst: false),
        TrackColumn(id: "trackNumber", title: String(ui: "트랙 번호"), width: 60, minWidth: 40, sortKey: "trackNumber"),
        TrackColumn(id: "genre", title: String(ui: "장르"), width: 90, minWidth: 50, flexible: true, sortKey: "genre"),
        TrackColumn(id: "comment", title: String(ui: "코멘트"), width: 250, minWidth: 140, flexible: true, sortKey: "comment"),
        TrackColumn(id: "class", title: String(ui: "분류"), width: 52, minWidth: 40, sortKey: "class", help: String(ui: "코멘트 분류: 규칙·구형·잔재·크레딧·빈 값·기타")),
        TrackColumn(id: "bpm", title: "BPM", width: 44, minWidth: 34, sortKey: "bpm", ascendingFirst: false),
        TrackColumn(id: "key", title: String(ui: "키"), width: 36, minWidth: 30, sortKey: "key"),
        TrackColumn(id: "rating", title: String(ui: "평점"), width: ratingWidth, minWidth: ratingMinWidth, sortKey: "rating", ascendingFirst: false,
                    help: String(ui: "rekordbox 평점(별 1~5개). 더블클릭하면 고른다")),
        TrackColumn(id: "color", title: String(ui: "곡 색"), width: 70, minWidth: 30, sortKey: "color",
                    help: String(ui: "rekordbox 곡 색. 더블클릭하면 고른다")),
        TrackColumn(id: "length", title: String(ui: "길이"), width: 46, minWidth: 38, sortKey: "length", ascendingFirst: false, help: String(ui: "곡 전체 재생 시간")),
        TrackColumn(id: "format", title: String(ui: "형식"), width: 44, minWidth: 36, sortKey: "format", help: String(ui: "파일 확장자(MP3·M4A·FLAC·WAV 등)")),
        TrackColumn(id: "tempo", title: String(ui: "변속"), width: 90, minWidth: 44, sortKey: "tempo", ascendingFirst: false,
                    help: String(ui: "rekordbox 그리드에서 BPM이 바뀌는 곡의 흐름(예: 175→128→175)")),
        TrackColumn(id: "imported", title: String(ui: "임포트"), width: 86, minWidth: 70, sortKey: "imported", ascendingFirst: false),
        TrackColumn(id: "plays", title: String(localized: "library.column.plays", defaultValue: "재생", bundle: UIStrings.bundle), width: 42, minWidth: 34, sortKey: "plays", ascendingFirst: false),
        TrackColumn(id: "hotCues", title: String(ui: "핫큐"), width: 42, minWidth: 34, sortKey: "hotCues", ascendingFirst: false,
                    help: String(ui: "직접 찍은 핫큐 수(초록)")),
        TrackColumn(id: "memoryCues", title: String(ui: "메모리"), width: 50, minWidth: 40, sortKey: "memoryCues", ascendingFirst: false,
                    help: String(ui: "메모리 큐 수(빨강, rekordbox 자동 큐 포함). 자동 큐뿐이면 흐린 글자")),
        TrackColumn(id: usbSyncID, title: String(ui: "갱신 상태"), width: 96, minWidth: 60, sortKey: usbSyncID,
                    help: String(ui: "로컬 rekordbox 곡과 견준 USB 곡의 상태(USB 목록에서만 보인다)")),
    ]

    /// 평점 칸 기본 폭: 별 다섯 칸(`TrackRating.stars`, 13pt에서 65.6pt)과 글자 자리 여백 4pt가 들어가고 조금 남는다.
    /// 좁은 폭·큰 글자 배율에서는 칸이 알아서 "5★"로 줄여 보인다(`TrackTextCell.set(compact:)`).
    static let ratingWidth: CGFloat = 76

    /// 평점 칸 최소 폭: 가장 큰 글자 배율(1.5배, 19.5pt)에서도 숫자 표기("5★", 31pt)와 글자 자리 여백 4pt가 들어간다.
    static let ratingMinWidth: CGFloat = 40

    /// 평점 칸의 옛 기본 폭. 별 다섯 칸이 안 들어가 "★★★…"로 잘려 3·4·5가 같아 보였고(#65), 이 폭으로 저장된 배치가 남아 있다.
    static let legacyRatingWidth: CGFloat = 66

    /// 저장된 평점 칸 폭이 옛 기본 폭 그대로면 새 기본 폭. 사용자가 끌어 바꾼 폭은 건드리지 않는다(nil).
    static func migratedRatingWidth(saved: CGFloat) -> CGFloat? {
        saved == legacyRatingWidth ? ratingWidth : nil
    }

    static let ratingWidthMigratedKey = "djc.trackList.ratingWidthMigrated"

    /// 저장된 배치를 읽은 직후 한 번만: 옛 기본 폭(66) 그대로인 평점 칸을 새 기본 폭으로 넓힌다(#65).
    /// 한 번 했다는 표시를 남기므로 그 뒤 사용자가 일부러 66으로 줄여도 덮어쓰지 않는다(좁아도 칸이 숫자로 줄여 보여 읽힌다).
    /// - Parameter remember: 했다는 표시를 남길지(성능 측정 때는 칸 배치를 저장하지 않으므로 남기지 않는다)
    @MainActor static func migrateRatingWidth(in table: NSTableView, defaults: UserDefaults = .standard, remember: Bool = true) {
        guard !defaults.bool(forKey: ratingWidthMigratedKey) else { return }
        if let column = table.tableColumns.first(where: { $0.identifier.rawValue == "rating" }),
           let width = migratedRatingWidth(saved: column.width) {
            column.width = width
        }
        if remember { defaults.set(true, forKey: ratingWidthMigratedKey) }
    }

    /// USB 갱신 상태 칸. USB 목록을 볼 때만 보이고 다른 목록에서는 숨긴다
    static let usbSyncID = "usbSync"

    /// USB 목록에서 보이는 칸: # 번호·제목·아티스트·BPM·키·갱신 상태. 나머지는 USB에서 읽지 않았거나(큐·그리드·미리 보기)
    /// 로컬 초안·분류에 쓰는 칸이라 숨긴다
    static let usbColumns: Set<String> = ["index", "title", "artist", "bpm", "key", usbSyncID]

    /// USB 곡에서 읽지 않은 값의 칸(칸이 보이더라도 비운다 — 큐 없음·자동 같은 표시가 틀린 정보가 된다)
    static let usbUnreadColumns: Set<String> = ["hotCues", "memoryCues", "tempo"]

    /// 처음에 숨기는 칸(머리글 오른쪽 클릭으로 보인다). 태그 칸은 모두 목록에서 바로 고칠 수 있게 두되(#88) 자주 쓰지 않는 칸은 숨긴다.
    static let hiddenByDefault: Set<String> = ["preview", "albumArtist", "composer", "year", "trackNumber"]

    /// 초안 칸 머리글: 글자 '✎' 대신 pencil 심볼을 머리글 글자색·크기로 넣는다(칸이 좁아 '초안'이 들어가지 않는다).
    /// 제목 '초안'은 칸 메뉴와 VoiceOver에 쓴다.
    @MainActor static var draftHeader: NSAttributedString {
        symbolHeader("pencil", label: String(ui: "초안"))
    }

    // NSTableHeaderCell은 image를 직접 그리지 않아 초안 머리글처럼 글자 안에 심볼을 넣는다.
    @MainActor static var artworkHeader: NSAttributedString {
        symbolHeader("photo", label: String(ui: "앨범아트"))
    }

    @MainActor private static func symbolHeader(_ symbol: String, label: String) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: NSFont.smallSystemFontSize, weight: .regular))
        let text = NSMutableAttributedString(attachment: attachment)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        text.addAttributes([.foregroundColor: NSColor.headerTextColor, .paragraphStyle: paragraph],
                           range: NSRange(location: 0, length: text.length))
        return text
    }

    static func comparator(key: String, ascending: Bool) -> KeyPathComparator<TrackRow>? {
        let order: SortOrder = ascending ? .forward : .reverse
        switch key {
        case "title": return KeyPathComparator(\TrackRow.title, order: order)
        case "artist": return KeyPathComparator(\TrackRow.artist, order: order)
        case "genre": return KeyPathComparator(\TrackRow.genre, order: order)
        case "album": return KeyPathComparator(\TrackRow.album, order: order)
        case "albumArtist": return KeyPathComparator(\TrackRow.albumArtist, order: order)
        case "composer": return KeyPathComparator(\TrackRow.composer, order: order)
        case "year": return KeyPathComparator(\TrackRow.releaseYear, order: order)
        case "trackNumber": return KeyPathComparator(\TrackRow.trackNumber, order: order)
        case "comment": return KeyPathComparator(\TrackRow.comment, order: order)
        case "class": return KeyPathComparator(\TrackRow.commentClassName, order: order)
        case "bpm": return KeyPathComparator(\TrackRow.bpmValue, order: order)
        case "key": return KeyPathComparator(\TrackRow.keyName, order: order)
        case "rating": return KeyPathComparator(\TrackRow.ratingValue, order: order)
        case "color": return KeyPathComparator(\TrackRow.colorSortKey, order: order)
        case "length": return KeyPathComparator(\TrackRow.lengthSeconds, order: order)
        case "format": return KeyPathComparator(\TrackRow.formatName, order: order)
        case "tempo": return KeyPathComparator(\TrackRow.tempoChangeCount, order: order)
        case "imported": return KeyPathComparator(\TrackRow.importedOn, order: order)
        case "plays": return KeyPathComparator(\TrackRow.playCount, order: order)
        case "hotCues": return KeyPathComparator(\TrackRow.hotCueCount, order: order)
        case "memoryCues": return KeyPathComparator(\TrackRow.memoryCueCount, order: order)
        case usbSyncID: return KeyPathComparator(\TrackRow.usbSyncText, order: order)
        default: return nil
        }
    }

    /// 스토어의 정렬을 머리글 표시로 되돌린다.
    static func sortKey(of keyPath: PartialKeyPath<TrackRow>) -> String? {
        switch keyPath {
        case \TrackRow.title: "title"
        case \TrackRow.artist: "artist"
        case \TrackRow.genre: "genre"
        case \TrackRow.album: "album"
        case \TrackRow.albumArtist: "albumArtist"
        case \TrackRow.composer: "composer"
        case \TrackRow.releaseYear: "year"
        case \TrackRow.trackNumber: "trackNumber"
        case \TrackRow.comment: "comment"
        case \TrackRow.commentClassName: "class"
        case \TrackRow.bpmValue: "bpm"
        case \TrackRow.keyName: "key"
        case \TrackRow.ratingValue: "rating"
        case \TrackRow.colorSortKey: "color"
        case \TrackRow.lengthSeconds: "length"
        case \TrackRow.formatName: "format"
        case \TrackRow.tempoChangeCount: "tempo"
        case \TrackRow.importedOn: "imported"
        case \TrackRow.playCount: "plays"
        case \TrackRow.hotCueCount: "hotCues"
        case \TrackRow.memoryCueCount: "memoryCues"
        case \TrackRow.usbSyncText: usbSyncID
        default: nil
        }
    }

    // MARK: - 저장된 칸 배치

    /// 저장된 칸 배치에 없던 새 칸을 한 번만 제자리로 옮긴다(그 뒤로는 사용자가 옮긴 대로). 칸을 만든 직후 부른다.
    @MainActor static func placeNewColumns(in table: NSTableView) {
        // 저장된 칸 배치에는 새 "형식" 칸이 없어서 끝으로 밀린다. 한 번만 BPM 옆으로 옮긴다(그 뒤로는 사용자가 옮긴 대로).
        let indexKey = "djc.trackList.indexColumnPlaced"
        if !UserDefaults.standard.bool(forKey: indexKey),
           let from = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "index" }) {
            table.moveColumn(from, toColumn: 0)
            UserDefaults.standard.set(true, forKey: indexKey)
        }
        let albumKey = "djc.trackList.albumColumnPlaced"
        if !UserDefaults.standard.bool(forKey: albumKey),
           let from = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "album" }),
           let artist = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "artist" }) {
            table.moveColumn(from, toColumn: from > artist ? artist + 1 : artist)
            UserDefaults.standard.set(true, forKey: albumKey)
        }
        let tempoKey = "djc.trackList.tempoColumnPlaced"
        if !UserDefaults.standard.bool(forKey: tempoKey),
           let from = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "tempo" }),
           let bpm = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "bpm" }) {
            table.moveColumn(from, toColumn: from > bpm ? bpm + 1 : bpm)
            UserDefaults.standard.set(true, forKey: tempoKey)
        }
        let placedKey = "djc.trackList.formatColumnPlaced"
        if !UserDefaults.standard.bool(forKey: placedKey),
           let from = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "format" }),
           let bpm = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "bpm" }) {
            table.moveColumn(from, toColumn: from > bpm ? bpm + 1 : bpm)
            UserDefaults.standard.set(true, forKey: placedKey)
        }
        let previewKey = "djc.trackList.previewColumnPlaced"
        if !UserDefaults.standard.bool(forKey: previewKey),
           let from = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "preview" }),
           let title = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "title" }) {
            table.moveColumn(from, toColumn: from > title ? title + 1 : title)
            if !PerfProbe.enabled { UserDefaults.standard.set(true, forKey: previewKey) }
        }
        // 새 태그 칸(#88)도 저장된 배치에는 없어 끝으로 밀린다. 한 번만 앨범 옆으로 옮긴다(처음엔 숨김).
        let tagKey = "djc.trackList.tagColumnsPlaced"
        if !UserDefaults.standard.bool(forKey: tagKey) {
            var anchor = "album"
            for id in ["albumArtist", "composer", "year", "trackNumber"] {
                if let from = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }),
                   let to = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == anchor }) {
                    table.moveColumn(from, toColumn: from > to ? to + 1 : to)
                }
                anchor = id
            }
            UserDefaults.standard.set(true, forKey: tagKey)
        }
        // 평점·곡 색 칸(#65)도 저장된 배치에는 없어 끝으로 밀린다. 한 번만 키 칸 뒤로 옮긴다.
        let ratingKey = "djc.trackList.ratingColorColumnsPlaced"
        if !UserDefaults.standard.bool(forKey: ratingKey) {
            var anchor = "key"
            for id in ["rating", "color"] {
                if let from = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }),
                   let to = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == anchor }) {
                    table.moveColumn(from, toColumn: from > to ? to + 1 : to)
                }
                anchor = id
            }
            if !PerfProbe.enabled { UserDefaults.standard.set(true, forKey: ratingKey) }
        }
    }
}
