import AppKit
import DJCApplication
import DJCDomain
import Foundation
import Observation
import UniformTypeIdentifiers

/// Apple Music XML 가져오기 창의 화면 모델. 창의 단추는 동기 메서드만 부르고, 일(`Task`)과 그 손잡이는 이 모델이 든다(MVVM-4).
@MainActor
@Observable
final class AppleMusicImportModel {
    let store: LibraryStore
    var library: AppleMusicLibrary?
    var selected = Set<Int>()
    var playlistID = ""
    var createPlaylists = false
    var isBusy = false
    var message: String?

    /// 단추가 마지막으로 시작한 일(XML 열기·곡 추가). 창을 닫아도 끝까지 간다. 시험은 이것을 기다린다
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(store: LibraryStore) { self.store = store }

    var visibleTracks: [AppleMusicLibrary.Track] {
        guard let library else { return [] }
        guard let playlist = library.playlists.first(where: { $0.id == playlistID }) else { return library.tracks }
        let byID = Dictionary(uniqueKeysWithValues: library.tracks.map { ($0.id, $0) })
        // 같은 곡이 여러 번 들어 있어도 선택 줄은 한 번만 보여 준다. 출처에는 원래 순서를 모두 보관한다.
        var seen = Set<Int>()
        return playlist.trackIDs.compactMap { seen.insert($0).inserted ? byID[$0] : nil }
    }

    var selectedTracks: [AppleMusicLibrary.Track] { library?.selectedTracks(trackIDs: selected) ?? [] }

    func chooseXML() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.prompt = String(ui: "보관함 열기")
        panel.message = String(ui: "Music 또는 iTunes에서 내보낸 보관함·재생 목록 XML을 고르세요.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        task = Task { await load(url) }
    }

    func load(_ url: URL) async {
        isBusy = true
        message = nil
        library = nil
        selected = []
        playlistID = ""
        defer { isBusy = false }
        do {
            self.library = try await store.useCases.appleMusic.open(url)
        } catch {
            message = String(ui: "XML을 열지 못했습니다. Music에서 보관함을 XML로 다시 내보내고 파일 접근 권한을 확인하세요.")
        }
    }

    func selectVisible(_ select: Bool) {
        let ids = Set(visibleTracks.filter { $0.exclusion == nil }.map(\.id))
        if select { selected.formUnion(ids) } else { selected.subtract(ids) }
    }

    func startAddSelected() { task = Task { await addSelected() } }

    func addSelected() async {
        guard !isBusy, store.writeLockPolicy.allowsLibraryInteraction, let library else { return }
        let candidates = selectedTracks
        guard !candidates.isEmpty else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        var urls: [URL] = []
        var origins: [String: [AppleMusicOrigin]] = [:]
        var rejected = 0
        for track in candidates {
            guard let url = track.fileURL else { continue }
            // XML을 내보낸 뒤 파일이 바뀌었거나 보호 표시가 빠진 경우도 실제 파일에서 막는다.
            if let reason = await store.useCases.appleMusic.exclusion(for: url) {
                if let index = self.library?.tracks.firstIndex(where: { $0.id == track.id }) {
                    self.library?.tracks[index].exclusion = reason
                }
                selected.remove(track.id)
                rejected += 1
                continue
            }
            urls.append(url)
            origins[url.path.precomposedStringWithCanonicalMapping, default: []].append(library.origin(for: track.id))
        }
        // 파일 검사 중 시작된 반영과 곡 추가가 겹치지 않게 다시 확인한다.
        guard store.writeLockPolicy.allowsLibraryInteraction else {
            message = String(ui: "rekordbox 쓰기가 끝난 뒤 선택한 곡을 다시 추가하세요.")
            return
        }
        if !urls.isEmpty {
            await store.addFiles(urls, appleMusicOrigins: origins, createPlaylists: createPlaylists)
            message = store.stagingMessage?.text
        }
        if rejected > 0 {
            let warning = String(ui: "\(rejected)곡은 파일을 확인하지 못해 제외했습니다. 각 곡의 안내를 확인하세요.")
            message = [message, warning].compactMap { $0 }.joined(separator: " · ")
        }
    }
}
