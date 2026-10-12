import DJCDomain
import SwiftUI

/// 설정 › 업데이트(#59). 확인·받기·설치 창은 Sparkle 표준 창이 띄운다.
struct UpdateSettingsView: View {
    @Bindable var model: UpdateSettingsModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.automaticallyChecks) {
                    Text(.ui("새 버전 자동 확인"))
                    Text(.ui("하루 한 번 GitHub Releases에서 새 버전을 찾아 알립니다."))
                }
                .disabled(!model.isAvailable)
                Toggle(isOn: $model.automaticallyDownloads) {
                    Text(.ui("자동으로 받아 설치"))
                    Text(.ui("새 버전을 뒤에서 받아 두고 앱을 끌 때 설치합니다."))
                }
                .disabled(!model.canChangeAutomaticDownloads)
            } footer: {
                Text(.ui("업데이트는 DJCrate 서명을 확인한 뒤에만 설치합니다. rekordbox·USB에 쓰는 중이면 쓰기가 끝난 뒤 설치합니다."))
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(.ui("지금 버전")) {
                    Text(verbatim: model.versionText)
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                LabeledContent(.ui("마지막 확인")) {
                    Text(verbatim: model.lastCheckText)
                        .monospacedDigit()
                }
                HStack {
                    if let reason = model.unavailableReason {
                        Text(reason)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(.ui("지금 확인")) { model.checkNow() }
                        .disabled(!model.canCheck)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 400)
    }
}

/// 앱 메뉴의 "업데이트 확인…"(DJCrate 정보 아래)
struct UpdateCommands: Commands {
    let model: UpdateSettingsModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(.ui("업데이트 확인…")) { model.checkNow() }
                .disabled(!model.canCheck)
        }
    }
}
