import DJCApplication
import DJCDomain
import SwiftUI
import UniformTypeIdentifiers

/// 창 아래 LINK 막대(#272). 네트워크에 Pro DJ Link 장치가 보이면 왼쪽에 LINK 단추가 뜨고, 누르면 오른쪽에 장치를 늘어놓는다.
/// 펼친 동안 DJCrate 라이브러리를 CDJ에 내어 주고(#273), 곡 목록의 곡을 플레이어 칸에 놓으면 그 플레이어에 싣는다(#274).
/// 장치가 없으면 아무것도 그리지 않아 창 높이를 차지하지 않는다. 이 막대만 모델을 읽어 장치가 바뀌어도 본문을 다시 계산하지 않는다.
struct LinkBar: View {
    let model: LinkBarModel

    var body: some View {
        if model.isVisible {
            VStack(spacing: 0) {
                Divider()
                // 장치는 막대 가운데에 둔다(rekordbox처럼). LINK 단추와 상태 글은 왼쪽 끝에 겹쳐 둔다
                ZStack(alignment: .leading) {
                    if model.showsDevices {
                        LinkDeviceRow(model: model)
                            .frame(maxWidth: .infinity)
                    } else if model.isExpanded, let reason = model.blockReason {
                        Text(verbatim: reason)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.leading, 64)
                    }
                    HStack(spacing: 8) {
                        LinkToggle(isOn: model.isExpanded, number: model.server?.deviceNumber, blockReason: model.blockReason,
                                   toggle: { model.toggle() })
                        if model.isExpanded, model.blockReason == nil, let text = model.connectionText {
                            Text(verbatim: text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: 90, alignment: .leading)
                        }
                    }
                }
                // 접어서 장치 줄이 없어도 단추가 가운데로 오지 않게 막대 폭을 채운다
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(height: 56)
            }
            .background(.bar)
        }
    }
}

/// 가운데 장치 줄: 앞쪽 플레이어 | 믹서 | 뒤쪽 플레이어·그 밖의 장치
private struct LinkDeviceRow: View {
    let model: LinkBarModel

    var body: some View {
        let arrangement = model.arrangement
        HStack(spacing: 8) {
            ForEach(arrangement.left) { tile($0) }
            ForEach(arrangement.mixers) { tile($0) }
            ForEach(arrangement.right) { tile($0) }
        }
    }

    private func tile(_ device: LinkDevice) -> some View {
        LinkDeviceTile(device: device, player: model.player(device), isMounted: model.isMounted(device),
                       onDrop: model.acceptsDrop(device) ? { @MainActor contentID in model.drop(contentID: contentID, on: device) } : nil)
    }
}

/// LINK 단추. 참여했으면 rekordbox처럼 참여 번호를 보인다. 쓸 수 없으면(rekordbox 켜짐) 흐리게 두고, 누르면 장치 대신 이유를 보인다.
private struct LinkToggle: View {
    let isOn: Bool
    /// 참여한 장치 번호
    let number: Int?
    let blockReason: String?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 1) {
                if isOn, let number {
                    Text(number, format: .number)
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                } else {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(.ui("LINK"))
                    .font(.system(size: 10, weight: .bold))
            }
            .frame(width: 48, height: 40)
            .foregroundStyle(isOn && blockReason == nil ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 6).fill(isOn && blockReason == nil ? Color.accentColor : Color.secondary.opacity(0.15)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .opacity(blockReason == nil ? 1 : 0.5)
        .help(blockReason ?? String(ui: "누르면 네트워크의 Pro DJ Link 장치를 보이고 DJCrate 라이브러리를 CDJ에 내어 줍니다"))
        .accessibilityLabel(Text(.ui("LINK")))
        .accessibilityValue(blockReason ?? (isOn ? String(ui: "펼침") : String(ui: "접힘")))
    }
}

/// 장치 하나. 플레이어는 번호·재생 상태·MASTER·SYNC와 실은 곡을 짧게 보이고, 내어 주는 동안 곡을 놓을 자리가 된다(#274).
/// 믹서·그 밖의 장치는 아이콘과 이름만 보인다.
struct LinkDeviceTile: View {
    let device: LinkDevice
    /// 재생 상태(서버를 켰을 때만 안다)
    var player: LinkPlayerState?
    /// DJCrate 라이브러리를 마운트했는지(곡을 실을 수 있는지)
    var isMounted = false
    /// 곡을 놓았을 때(rekordbox 곡 ID). nil이면 놓을 수 없다
    var onDrop: (@MainActor @Sendable (String) -> Void)?
    @State private var isTargeted = false

    private var isPlaying: Bool { player?.isPlaying ?? false }
    private var tint: Color { isPlaying ? .green : .secondary }

    var body: some View {
        HStack(spacing: 8) {
            LinkDeviceIcon(kind: device.kind, color: isPlaying ? .green : .secondary, size: 20)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.15)))
            if device.hasDeck {
                playerInfo
            } else {
                Text(verbatim: device.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: device.hasDeck ? 200 : nil, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(isTargeted ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(borderColor, lineWidth: isTargeted || isPlaying ? 2 : 1))
        .help(Text(verbatim: helpText))
        .accessibilityElement(children: .combine)
        .onDrop(of: [DeckDragType.track], delegate: LinkTrackDropDelegate(onDrop: onDrop, isTargeted: $isTargeted))
    }

    private var playerInfo: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(device.number, format: .number)
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                if let player {
                    Image(systemName: player.isPlaying ? "play.fill" : "pause.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(player.isPlaying ? Color.green : Color.orange)
                        .accessibilityLabel(Text(player.isPlaying ? .ui("재생 중") : .ui("멈춤")))
                }
                Spacer(minLength: 2)
                if let player {
                    LinkBadge(text: String(ui: "MASTER"), isOn: player.isMaster, color: .orange)
                    LinkBadge(text: String(ui: "SYNC"), isOn: player.isSync, color: .accentColor)
                }
                if isMounted {
                    Image(systemName: "link")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .help(String(ui: "DJCrate 라이브러리를 열었습니다"))
                }
            }
            // 실은 곡: DJCrate가 내어 준 곡이면 제목, 아니면(USB 등·모름) 장치 이름
            Text(verbatim: player?.title ?? device.name)
                .font(.system(size: 11))
                .foregroundStyle(player?.title == nil ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var borderColor: Color {
        if isTargeted { return .accentColor }
        return isPlaying ? Color.green.opacity(0.8) : Color.secondary.opacity(0.25)
    }

    private var helpText: String {
        var parts = [device.name, "\(device.number)", device.address]
        if let bpm = player?.bpm { parts.append(bpm.formatted(.number.precision(.fractionLength(2))) + " BPM") }
        return parts.joined(separator: " · ")
    }
}

/// MASTER·SYNC 표시. 켜지면 채우고, 꺼지면 흐린 테두리만 둔다(rekordbox처럼 자리는 늘 같다)
private struct LinkBadge: View {
    let text: String
    let isOn: Bool
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .foregroundStyle(isOn ? Color.white : Color.secondary.opacity(0.6))
            .background(RoundedRectangle(cornerRadius: 2).fill(isOn ? color : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(isOn ? Color.clear : Color.secondary.opacity(0.35), lineWidth: 1))
            .accessibilityHidden(!isOn)
    }
}
