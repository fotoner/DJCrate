import DJCDomain
import AppKit
import SwiftUI

extension TrackListCoordinator {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// 드래그로는 여러 곡을 고르지 않는다(클릭 한 곡, Shift = 범위, ⌘ = 하나씩 더하기·빼기).
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDragged,
              event.modifierFlags.intersection([.shift, .command]).isEmpty else { return proposed }
        return tableView.selectedRowIndexes
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        tableColumn?.identifier.rawValue == "title" ? rows[row].title : nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, rows.indices.contains(index) else { return nil }
        let cell: NSView = switch id {
        case "preview": reuse(tableView, "preview") { PreviewWaveformCell(cache: store.previewImages) }
        case "thumb": reuse(tableView, "thumb") { ThumbnailCell(thumbnails: store.thumbnails) }
        case "edited": reuse(tableView, "edited") { EditedMarkCell() }
        case "index": reuse(tableView, "index") { TrackIndexCell() }
        default: reuse(tableView, "text") { TrackTextCell() }
        }
        // 고치던 칸이 다른 자리로 다시 쓰이면(스크롤로 줄이 사라짐) 그 입력을 확정한다. 대상 곡은 편집을 시작할 때 정해 두었다.
        if let edit = inlineEdit, edit.cell === cell, edit.row != index || edit.column != id {
            Task { @MainActor [weak self] in self?.finishEditing(commit: true, restoreFocus: true) }
        }
        fill(cell, column: id, row: index)
        return cell
    }

    /// 칸 하나를 그 줄의 곡으로 채운다(새로 만들었거나 다시 쓴 칸, 목록이 바뀌어 제자리에서 다시 채우는 칸).
    func fill(_ view: NSView, column id: String, row index: Int) {
        let row = rows[index]
        switch view {
        case let cell as PreviewWaveformCell:
            // USB 곡은 음원에서 파형을 새로 만들지 않는다(USB를 오래 읽고 로컬 캐시를 채운다)
            cell.configure(url: row.track.analysisURL(in: store.shareRoot),
                           revision: "\(snapshotURL?.absoluteString ?? ""):\(previewRevision)", mode: waveformMode,
                           audioURL: row.track.isStreaming || row.isUsb ? nil : URL(filePath: row.track.folderPath), key: row.track.uuid,
                           cues: PerfProbe.previewCuesVisible ? PreviewCueMark.current(saved: row.cues, draft: previewCues[row.track.uuid]) : [],
                           duration: Double(row.track.lengthSeconds))
        case let cell as ThumbnailCell:
            cell.configure(track: row.track, shareRoot: store.shareRoot)
        case let cell as EditedMarkCell:
            cell.configure(edited: edited.contains(row.track.uuid))
        case let cell as TrackIndexCell:
            cell.configure(number: "\(row.historyTrackNumber ?? row.playlistTrackNumber ?? (index + 1))", font: fonts.digits,
                           deck: store.isDeckTrack(row, deckTrackID: deckTrackID) ? .init(playing: deckPlaying) : nil)
        case let cell as TrackTextCell:
            cell.fonts = fonts
            configure(cell, column: id, row: row, index: index)
        default: break
        }
    }

    func reuse<Cell: NSView>(_ table: NSTableView, _ identifier: String, make: () -> Cell) -> Cell {
        let id = NSUserInterfaceItemIdentifier(identifier)
        if let cell = table.makeView(withIdentifier: id, owner: nil) as? Cell { return cell }
        let cell = make()
        cell.identifier = id
        return cell
    }

    func configure(_ cell: TrackTextCell, column: String, row: TrackRow, index: Int) {
        if row.isUsb, TrackColumn.usbUnreadColumns.contains(column) {
            cell.set("", color: .secondaryLabelColor)
            return
        }
        if let key = TrackListTagEditing.key(forColumn: column) {
            configureTag(cell, key: key, row: row)
            return
        }
        switch column {
        case "class":
            // 코멘트 초안이 있으면 초안 코멘트로 다시 가른다(반영 전 값이라 초안 표식을 붙인다).
            let draft = store.tagDrafts[row.track.uuid]
            let evaluation = TrackListTagEditing.commentEvaluation(row, draft: draft, rule: commentPreset?.rule)
            cell.set(evaluation?.displayName ?? "", color: evaluation?.tone.nsTint ?? .secondaryLabelColor,
                     draft: draft.map { $0.base.comment != $0.fields.comment } ?? false)
        case "bpm": cell.set(row.bpmValue > 0 ? String(format: "%.0f", row.bpmValue) : "", color: .secondaryLabelColor, digits: true)
        case "length": cell.set(row.lengthText, color: .secondaryLabelColor, digits: true)
        case "format": cell.set(row.formatName, color: .secondaryLabelColor)
        case TrackColumn.usbSyncID:
            // 최신이 아니면(갱신 가능·기기에서 고침·로컬에 없음) 주의 색
            let settled = row.usbSync.map { if case .upToDate = $0 { true } else { false } } ?? true
            cell.set(row.usbSyncText, color: settled ? .secondaryLabelColor : UIColors.warning.nsColor)
        case "tempo": cell.set(row.tempoChangeText, color: UIColors.tempo.nsColor, digits: true)
        case "imported": cell.set(row.importedOn, color: .secondaryLabelColor, digits: true)
        case "plays": cell.set(row.playCount > 0 ? "\(row.playCount)" : "", color: .labelColor, digits: true)
        case "hotCues":
            let hot = cueCounts[row.track.uuid]?.hot ?? row.hotCueCount
            cell.set(hot > 0 ? "\(hot)" : "", color: UIColors.hot.nsColor, digits: true)
        case "memoryCues":
            // DJCrate에서 찍은 큐(초안)가 있으면 그 개수를 보여 준다(반영 전이라도).
            // 큐 없는 곡은 핫큐 칸처럼 비운다(사이드바 '큐 없음'으로 찾는다, #121). 자동 큐뿐이면 흐린 글자(#145).
            let label = row.memoryCueLabel(draft: cueCounts[row.track.uuid])
            let autoOnly = if case .autoOnly = label { true } else { false }
            cell.set(label.text, color: autoOnly ? .tertiaryLabelColor : UIColors.memory.nsColor, digits: true)
        default: cell.set("", color: .labelColor)
        }
    }

    /// 태그 칸: 초안 값이면 초안 색·모서리 표식·VoiceOver "초안"으로 보인다(태그 시트와 같다, #34).
    func configureTag(_ cell: TrackTextCell, key: TagFields.Key, row: TrackRow) {
        if key == .rating || key == .color {
            // 평점은 별, 곡 색은 색 점과 rekordbox 이름. 초안이면 초안 색·표식·VoiceOver "초안"(다른 태그 칸과 같다)
            let (value, edited) = TrackListTagEditing.text(row, key, draft: store.tagDrafts[row.track.uuid])
            let colors = store.trackColors
            let text = TagChoice.display(key, value, colors: colors)
            // 별 다섯 칸이 안 들어가는 폭에서는 "5★"로 줄인다(잘린 "★★★…"은 3·4·5가 같아 보인다, #65)
            cell.set(text, color: edited ? UIColors.draft.nsColor : .secondaryLabelColor, draft: edited,
                     swatch: key == .color ? TagChoice.swatchImage(value) : nil, spoken: TagChoice.spoken(key, value, colors: colors),
                     compact: key == .rating ? TrackRating.compact(value) : nil)
            if let reason = TrackListTagEditing.unavailableReason(row, key: key) { cell.toolTip = reason }
            return
        }
        if key == .musicalKey {
            let edited = store.isTagEdited(row, key)
            // 키를 고치지 않은 추가 곡은 다른 태그 초안이 있어도 음원 태그·추정 제안을 그대로 보인다(#5).
            let estimated = !edited && row.keyEstimated
            cell.set(edited ? store.tagCell(row, key) : row.keyName,
                     color: edited ? UIColors.draft.nsColor : estimated ? UIColors.suggestion.nsColor : .secondaryLabelColor,
                     draft: edited, estimated: estimated)
            if let reason = KeyPicker.unavailableReason(row) { cell.toolTip = reason }
            return
        }
        let (text, edited) = TrackListTagEditing.text(row, key, draft: store.tagDrafts[row.track.uuid])
        // 스트리밍 곡은 제목 앞 아이콘과 흐린 글자로 로컬 곡과 구분한다(사이드바 '스트리밍'과 같은 아이콘, #121).
        // 파일이 없는 곡도 흐린 글자에 경고 아이콘을 붙인다(#126).
        let streaming = key == .title && row.track.isStreaming
        let missing = key == .title && row.fileMissing
        let color: NSColor = switch key {
        case .title: streaming || missing ? .secondaryLabelColor : .labelColor
        case .comment: row.commentEvaluation?.isMatch == true ? .labelColor : .secondaryLabelColor
        default: .secondaryLabelColor
        }
        if key == .comment, text.isEmpty {
            cell.set("—", color: edited ? UIColors.draft.nsColor : .tertiaryLabelColor, draft: edited)
        } else {
            cell.set(text, color: edited ? UIColors.draft.nsColor : color,
                     digits: key == .year || key == .trackNumber, draft: edited,
                     symbol: streaming ? LibraryFilter.streaming.systemImage : missing ? WarningMark.symbol : nil,
                     symbolLabel: streaming ? String(ui: "스트리밍 곡") : missing ? String(ui: "파일을 찾지 못한 곡") : nil,
                     symbolColor: missing ? UIColors.warning.nsColor : nil)
        }
        if let reason = TrackListTagEditing.unavailableReason(row, key: key) { cell.toolTip = reason }
    }
}
