import AppKit
import DJCApplication
import DJCDomain
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppleMusicImportWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: AppleMusicImportModel?

    func open(store: LibraryStore) {
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let model = AppleMusicImportModel(store: store)
        let window = NSWindow(contentViewController: NSHostingController(rootView: AppleMusicImportView(model: model)))
        window.title = String(ui: "Apple Music XML 가져오기")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 820, height: 600))
        window.contentMinSize = NSSize(width: 680, height: 480)
        window.center()
        self.window = window
        self.model = model
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { model?.isBusy != true }
}

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
        Task { await load(url) }
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

private struct AppleMusicImportView: View {
    @Bindable var model: AppleMusicImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.ui("Music의 파일 › 보관함 › 보관함 내보내기에서 XML을 저장하세요. 재생 목록 내보내기에서 XML을 골라도 됩니다."))
            Text(.ui("로컬 음원만 ‘추가한 곡’에 넣습니다. ‘재생 목록도 만들기’를 켜면 컬렉션에 넣은 뒤 원래 소속과 순서로 목록 초안을 만듭니다."))
                .font(.callout).foregroundStyle(.secondary)
            Toggle(.ui("재생 목록도 만들기"), isOn: $model.createPlaylists)
                .toggleStyle(.checkbox)
            if model.createPlaylists {
                Text(.ui("목록은 맨 위에 만듭니다. 같은 이름은 ‘ (2)’, ‘ (3)’을 붙여 새로 만들고, 같은 출처는 기존 연결에 이어 넣습니다. 목록 초안은 ‘rekordbox에 쓰기’로 저장합니다."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(.ui("XML 파일 선택…")) { model.chooseXML() }
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Text(.ui("선택한 곡 \(model.selectedTracks.count)개"))
            }
            if let library = model.library {
                Picker(.ui("재생 목록"), selection: $model.playlistID) {
                    Text(.ui("보관함 전체")).tag("")
                    ForEach(library.playlists) { playlist in
                        Text(playlist.name).tag(playlist.id)
                    }
                }
                HStack {
                    Button(.ui("표시한 곡 선택")) { model.selectVisible(true) }
                    Button(.ui("표시한 곡 해제")) { model.selectVisible(false) }
                    Spacer()
                    Text(.ui("제외된 곡 \(model.visibleTracks.filter { $0.exclusion != nil }.count)개"))
                        .foregroundStyle(.secondary)
                }
                List(model.visibleTracks) { track in
                    Toggle(isOn: Binding(get: { model.selected.contains(track.id) }, set: {
                        if $0 { model.selected.insert(track.id) } else { model.selected.remove(track.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title)
                            if !track.artist.isEmpty { Text(track.artist).font(.caption).foregroundStyle(.secondary) }
                            if let reason = track.exclusion {
                                Text(reason.message).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(track.exclusion != nil)
                }
            } else {
                Spacer()
                Text(.ui("XML을 열면 곡과 재생 목록을 고를 수 있습니다."))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
            if let message = model.message { Text(message).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(.ui("선택한 곡 추가")) { Task { await model.addSelected() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedTracks.isEmpty || !model.store.writeLockPolicy.allowsLibraryInteraction)
            }
        }
        .padding(20)
        .disabled(model.isBusy)
    }
}
