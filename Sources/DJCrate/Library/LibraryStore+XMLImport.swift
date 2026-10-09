import DJCApplication
import DJCDomain
import Foundation

/// 가져오기 차이 미리 보기 시트의 내용
struct XMLImportPreview: Identifiable, Sendable {
    let id = UUID()
    var fileName: String
    var comparison: XMLImportComparison
    var snapshot: URL { comparison.snapshot }
    var shareRoot: URL? { comparison.share }
    var xml: XMLLibrary { comparison.xml }
    var library: XMLLibrary { comparison.library }
    var diff: XMLLibraryDiff.Result { comparison.diff }
}

/// 파일 메뉴의 "rekordbox XML 가져오기…"(#72). 다른 도구가 만든 rekordbox XML을 메인 스레드 밖에서 읽어 지금 라이브러리와 비교하고,
/// 고른 차이를 초안으로만 만든다(유스케이스 `ImportXML`, CLI `xml-diff --draft`와 같은 규칙). rekordbox에는 쓰지 않는다.
extension LibraryStore {
    /// - Parameter shareRoot: 분석 파일 뿌리(읽기만, 없으면 저장소의 share). 시험은 합성 사본의 `share`를 준다. 없는 폴더면 그리드를 비교하지 않는다.
    func importRekordboxXML(from url: URL, shareRoot: URL? = nil) {
        guard let snapshot = snapshotURL else { return }
        let shareRoot = shareRoot ?? self.shareRoot
        cancelXMLImport()
        isReadingXMLImport = true
        let importer = useCases.importXML
        let share = importer.existingFolder(shareRoot)
        xmlImportTask = Task { [weak self] in
            let result = await Result { try await importer.compareInBackground(xml: url, snapshot: snapshot, share: share) }
            guard let self, !Task.isCancelled else { return }
            isReadingXMLImport = false
            xmlImportTask = nil
            switch result {
            case let .success(comparison): xmlImportPreview = XMLImportPreview(fileName: url.lastPathComponent, comparison: comparison)
            case .failure(is CancellationError): break
            case let .failure(error): stagingMessage = AppMessage(kind: .failure, text: Self.xmlImportFailure(error))
            }
        }
    }

    /// 읽는 중인 가져오기와 계획 중인 초안 만들기를 멈춘다(시트를 닫거나 새로 가져올 때). 저장을 시작한 초안은 끝까지 쓴다.
    func cancelXMLImport() {
        xmlImportTask?.cancel()
        xmlImportDraftTask?.cancel()
        isReadingXMLImport = false
    }

    static func xmlImportFailure(_ error: any Error) -> String {
        let reason = (error as? XMLReadError)?.reason ?? AppErrorMessage.message(for: error)
        return String(ui: "rekordbox XML을 가져오지 못했습니다: \(reason)")
    }

    /// 미리 보기 시트의 "초안으로 만들기". 닫으면 취소할 수 있게 작업을 들고 있는다.
    func startXMLImportDrafts(_ preview: XMLImportPreview, selection: XMLImportDrafts.Selection) {
        xmlImportDraftTask?.cancel()
        xmlImportDraftTask = Task { [weak self] in await self?.makeXMLImportDrafts(preview, selection: selection) }
    }

    /// 고른 차이를 초안으로 만든다. 저장 전 입력(메모리 태그 초안·저장하지 못한 큐·그리드)과 기존 초안 파일은 덮지 않고,
    /// 재생 목록은 메모리 초안에 편집을 덧붙여 저장한다. 덱에 올린 곡의 그리드 초안은 덱이 받는다(유스케이스 `ImportXML.makeDrafts`).
    @discardableResult
    func makeXMLImportDrafts(_ preview: XMLImportPreview, selection: XMLImportDrafts.Selection) async -> XMLImportDraftResult {
        isMakingXMLImportDrafts = true
        defer { isMakingXMLImportDrafts = false }
        let context = ImportXML.Context(
            existing: [.tag: Set(tagDrafts.keys)],
            playlists: ImportXML.PlaylistTarget(current: { [weak self] in self?.playlistDraft ?? PlaylistDraft() },
                                                save: { [weak self] draft in
                                                    guard let self else { return }
                                                    playlistDraft = draft
                                                    savePlaylistDraft()
                                                    refreshPlaylists()
                                                }),
            deck: ImportXML.DeckGrid(state: { [weak self] in self?.deckGridDraftState?() },
                                     adopt: { [weak self] in self?.adoptImportedGridDraft?($0) ?? false }))
        var result: XMLImportDraftResult
        do {
            result = try await useCases.importXML.makeDrafts(preview.comparison, selection: selection, context: context)
            if result.cues + result.grids + result.tags > 0 { await refreshExternalDrafts() }
        } catch let partial as ImportXML.PartialFailure {
            result = partial.result
            result.failure = String(ui: "초안을 만들지 못했습니다: \(AppErrorMessage.message(for: partial.error))")
        } catch {
            result = XMLImportDraftResult(failure: String(ui: "초안을 만들지 못했습니다: \(AppErrorMessage.message(for: error))"))
        }
        if xmlImportPreview?.id == preview.id { xmlImportResult = result }
        return result
    }
}
