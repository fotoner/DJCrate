import AppKit
import DJCApplication
import DJCDomain
import SwiftUI

@MainActor
final class AppleMusicImportWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: AppleMusicImportModel?

    func open(store: LibraryStore) {
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let model = AppleMusicImportModel(staging: store.staging, appleMusic: store.useCases.appleMusic)
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
                Button(.ui("선택한 곡 추가")) { model.startAddSelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedTracks.isEmpty || !model.staging.allowsLibraryInteraction)
            }
        }
        .padding(20)
        .disabled(model.isBusy)
    }
}
