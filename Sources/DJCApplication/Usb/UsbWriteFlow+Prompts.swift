import DJCDomain
import Foundation

extension UsbWriteFlow {
    // MARK: - 창 문구

    /// 쓰기 전 확인 창·내보내기 시트의 볼륨 줄. 실물이면 이름·용량·형식과 "실물 USB입니다"를 보이고(이 줄을 보인 창·시트의 쓰기 버튼이 쓰기 동의다),
    /// 기기가 읽지 못할 수 있는 형식(exFAT·GPT)은 한 줄씩 알린다
    public static func volumeLines(_ volume: UsbVolumeInfo, isTestVolume: Bool) -> [String] {
        if isTestVolume { return [String(ui: "시험 볼륨(디스크 이미지)입니다")] }
        let capacity = volume.capacity.formatted(ByteCountFormatStyle(style: .file))
        let scheme = volume.partitionScheme == .gpt ? "GPT" : "MBR"
        var lines = [String(ui: "실물 USB입니다: \(volume.name) · \(capacity) · \(volume.fileSystem.displayName) · \(scheme)"),
                     String(ui: "쓰기 전 바꿀 파일을 Mac에 백업합니다. 기기에 꽂기 전에 결과를 확인하세요")]
        lines += UsbVolumePolicy.warnings(volume).map(\.message)
        return lines
    }

    /// CDJ에서 확인하지 않은 항목 줄(막지 않고 알리기만 한다). trackCount가 0보다 크면 곡 수로 적는다
    public nonisolated static func deviceCheckLines(_ rules: [(rule: UsbProvisionalRule, count: Int)], trackCount: Int) -> [String] {
        guard !rules.isEmpty else { return [] }
        var lines = [trackCount > 0 ? String(ui: "CDJ에서 확인하지 않은 항목이 있는 곡 \(trackCount)개:")
            : String(ui: "CDJ에서 확인하지 않은 항목 \(rules.count)개:")]
        lines += rules.map { $0.count > 0 ? "• \($0.rule.summary) (\($0.count))" : "• \($0.rule.summary)" }
        lines.append(String(ui: "쓰기는 막지 않습니다. 쓴 뒤 기기에서 확인하세요"))
        return lines
    }

    public static var journalUnreadableText: String {
        String(ui: "회복 기록 파일을 읽지 못했습니다. DJCrate 데이터 폴더의 usb-sessions를 확인하세요")
    }

    /// 쓰기 전 확인 창: 곡·목록 수, 대상·형식, 시험 볼륨, 공간, 빼고 쓰는 곡(이유별 수), CDJ에서 확인하지 않은 항목
    public static func confirmation(_ summary: UsbExportSummary, job: UsbExportJob) -> ReflectionPrompt {
        let formats = UsbFormat.allCases.filter(job.formats.contains).map(\.displayName).joined(separator: " · ")
        var details: [String] = []
        details += volumeLines(job.volume, isTestVolume: summary.isTestVolume)
        details.append(summary.spaceText)
        details += blockLines(summary)
        return ReflectionPrompt(title: String(ui: "곡 \(summary.trackCount)개·재생 목록 \(summary.playlistCount)개를 USB에 쓸까요?"),
                                text: String(ui: "\(job.volume.name)에 \(formats)로 씁니다. 쓰기 전에 Mac에 백업하고 쓴 뒤 USB에서 다시 읽어 확인합니다. 끝날 때까지 USB를 뽑지 마세요."),
                                confirm: String(ui: "USB에 쓰기"), details: details)
    }

    /// 빼고 쓰는 곡·재생 목록(이유별 수)과 CDJ에서 확인하지 않은 항목 줄. 쓰기를 멈추는 막힘(볼륨·형식·파일)은 `stopping`으로만 보인다
    public static func blockLines(_ summary: UsbExportSummary) -> [String] {
        var lines: [String] = []
        let tracks = summary.blockCounts.filter { $0.kind == .track }
        if summary.blockedTrackCount > 0, !tracks.isEmpty {
            lines.append(String(ui: "빼고 쓰는 곡 \(summary.blockedTrackCount)개:"))
            lines += tracks.map { "• \($0.message) (\($0.count))" }
        }
        let playlists = summary.blockCounts.filter { $0.kind == .playlist }
        if summary.blockedPlaylistCount > 0, !playlists.isEmpty {
            lines.append(String(ui: "빼고 쓰는 재생 목록 \(summary.blockedPlaylistCount)개:"))
            lines += playlists.map { "• \($0.message) (\($0.count))" }
        }
        lines += deviceCheckLines(summary.rules.map { ($0.rule, $0.count) }, trackCount: summary.unverifiedTrackCount)
        return lines
    }

    /// 쓰지 못하는 까닭(볼륨 단위 막힘 → 공간 → 곡 없음)
    public static func stoppingText(_ summary: UsbExportSummary) -> String {
        if !summary.stopping.isEmpty { return summary.stopping.joined(separator: "\n") }
        if summary.isShortOfSpace { return String(ui: "USB 여유 공간이 모자랍니다. 곡을 줄이거나 공간이 더 있는 USB를 쓰세요") }
        return String(ui: "내보낼 곡이 없습니다. 막힌 곡의 이유를 확인한 뒤 다시 시도하세요")
    }

    /// 수정 쓰기 전 확인 창: 쓸 편집 수, 막힌 편집, 빼고 쓰는 곡, 형식별 결과, 지울 파일·미룸, CDJ에서 확인하지 않은 항목.
    /// draftChanged면 확인하는 동안 초안이 바뀌어 다시 묻는다는 것을 맨 앞에 알린다
    public static func editConfirmation(_ summary: UsbEditSummary, volume: UsbVolumeInfo, draftChanged: Bool = false) -> ReflectionPrompt {
        var details: [String] = []
        details += volumeLines(volume, isTestVolume: summary.isTestVolume)
        details += editLines(summary)
        let text = String(ui: "\(volume.name)의 rekordbox 라이브러리를 고칩니다. 쓰기 전에 Mac에 백업하고 쓴 뒤 USB에서 다시 읽어 확인합니다. 끝날 때까지 USB를 뽑지 마세요.")
        return ReflectionPrompt(title: String(ui: "USB에 편집 \(summary.writtenCount)건을 쓸까요?"),
                                text: draftChanged ? draftChangedText + "\n\n" + text : text,
                                confirm: String(ui: "USB에 쓰기"), details: details)
    }

    public static var draftChangedText: String {
        String(ui: "쓰기 대기가 그 사이 바뀌어 다시 계획했으니 바뀐 내용을 확인한 뒤 쓰세요")
    }

    /// 수정 요약 줄(확인 창·쓰기 대기 목록). blockedEdits가 거짓이면 막힌 편집 줄은 뺀다(대기 목록은 편집마다 보인다)
    public nonisolated static func editLines(_ summary: UsbEditSummary, blockedEdits: Bool = true) -> [String] {
        var lines: [String] = []
        if blockedEdits {
            let blocked = summary.outcomes.sorted { $0.key < $1.key }.compactMap { number, outcome -> String? in
                if case let .blocked(reason) = outcome { "• " + String(ui: "편집 \(number): \(reason)") } else { nil }
            }
            if !blocked.isEmpty {
                lines.append(String(ui: "막힌 편집 \(blocked.count)건(초안에 남깁니다):"))
                lines += blocked
            }
        }
        if summary.skippedTrackCount > 0 {
            lines.append(String(ui: "빼고 쓰는 곡 \(summary.skippedTrackCount)개:"))
            lines += summary.skipped.map { "• \($0.message) (\($0.count))" }
        }
        for result in summary.formats {
            if let reason = result.blocked {
                lines.append(String(ui: "\(result.format.displayName): 고치지 않음 — \(reason)"))
            } else if result.written {
                lines.append(String(ui: "\(result.format.displayName): 고침"))
            }
        }
        if summary.removals > 0 { lines.append(String(ui: "USB에서 지울 파일 \(summary.removals)개")) }
        lines += summary.deferred.map { String(ui: "파일 지우기를 미룸: \($0)") }
        if summary.formatDrift {
            lines.append(String(ui: "Device Library를 고치지 못해 두 형식의 곡이 달라집니다. 다음부터 이 USB를 고치려면 rekordbox에서 다시 내보내세요"))
        }
        lines += summary.notes.filter { !summary.deferred.contains($0) }
        lines += summary.warnings
        lines += deviceCheckLines(summary.rules.map { ($0, 0) }, trackCount: 0)
        return lines
    }

    public static func pendingPrompt(_ volume: UsbVolumeInfo) -> ReflectionPrompt {
        ReflectionPrompt(title: String(ui: "지난 USB 쓰기가 끝나지 않았습니다"),
                         text: String(ui: "\(volume.name)에 쓰다가 끊긴 기록이 있습니다. 회복하면 USB를 보고 마저 쓰거나 쓰기 전으로 되돌립니다. 되돌리기는 그 쓰기를 백업으로 되돌립니다. 기기에 꽂기 전에 하세요."),
                         confirm: String(ui: "회복하기"), alternate: String(ui: "되돌리기"), cancel: String(ui: "나중에"))
    }

    public static func discardDeviceChangesPrompt(_ volume: UsbVolumeInfo) -> ReflectionPrompt {
        ReflectionPrompt(title: String(ui: "USB를 쓰기 전으로 되돌릴까요?"),
                         text: String(ui: "\(volume.name)은 DJCrate가 쓴 뒤 기기에서 바뀌었습니다. 되돌리면 기기가 그 뒤에 쓴 내용을 잃습니다(재생 기록 등)."),
                         confirm: String(ui: "되돌리기"), critical: true, destructive: true)
    }

    // MARK: - 알림 문구(흐름과 시험이 같은 이름으로 가리킨다)

    public enum Text {
        public static var cancelledTitle: String { String(ui: "USB 쓰기를 취소했습니다") }
        public static var unchangedDetail: String { String(ui: "USB는 쓰기 전 그대로입니다.") }
        public static var rekordboxRunningTitle: String { String(ui: "rekordbox가 켜져 있어 USB에 쓰지 않았습니다") }
        public static var rekordboxRunningDetail: String { String(ui: "rekordbox와 rekordboxAgent를 완전히 종료한 뒤 다시 누르세요.") }
        public static var busyTitle: String { String(ui: "이 USB에 쓰는 중입니다") }
        public static var otherBusyTitle: String { String(ui: "다른 USB에 쓰는 중입니다") }
        public static var retryLaterDetail: String { String(ui: "쓰기가 끝난 뒤 다시 시도하세요.") }
        public static var ejectFailedTitle: String { String(ui: "USB를 꺼내지 못했습니다") }
        public static var recoveredTitle: String { String(ui: "USB 쓰기를 마저 끝냈습니다") }
        public static var restoredTitle: String { String(ui: "USB를 쓰기 전으로 되돌렸습니다") }
        public static var rolledBackInterruptedTitle: String { String(ui: "끊긴 USB 쓰기를 되돌렸습니다") }
        public static var nothingToRecoverTitle: String { String(ui: "회복할 USB 쓰기가 없습니다") }
        public static var cannotWriteTitle: String { String(ui: "USB에 쓸 수 없습니다") }
        public static var notWrittenTitle: String { String(ui: "USB에 쓰지 않았습니다") }
        public static var notRecoveredTitle: String { String(ui: "USB를 회복하지 않았습니다") }
        public static var notRestoredTitle: String { String(ui: "USB를 되돌리지 않았습니다") }
        public static var backupMissingText: String { String(ui: "이 쓰기의 백업을 찾지 못했습니다. USB를 다시 읽어 지금 상태를 확인하세요") }
        public static var migratedTitle: String { String(ui: "USB에 OneLibrary를 더했습니다") }
        public static var cannotMigrateTitle: String { String(ui: "OneLibrary를 더할 수 없습니다") }
        public static var previewFailedTitle: String { String(ui: "USB 미리 보기를 하지 못했습니다") }
        public static var nothingToWriteTitle: String { String(ui: "USB에 쓸 것이 없습니다") }
        public static func editWrittenTitle(count: Int) -> String { String(ui: "USB에 편집 \(count)건을 썼습니다") }
        public static var connectFirstDetail: String { String(ui: "USB를 연결한 뒤 쓰세요") }
        public static func writtenTitle(tracks: Int) -> String { String(ui: "곡 \(tracks)개를 USB에 썼습니다") }
    }

    /// USB에 손댄 뒤 끊긴 쓰기의 창(되돌림·되돌리지 못함·미룸·연결 끊김·볼륨 바뀜). 그 밖의 오류는 nil(일반 실패 창)
    public static func interruptedPrompt(_ error: UsbError) -> ReflectionPrompt? {
        switch error {
        case .writeRolledBack:
            ReflectionPrompt(title: String(ui: "USB에 쓴 결과를 확인하지 못해 쓰기 전으로 되돌렸습니다"),
                             text: String(ui: "USB는 쓰기 전 그대로입니다. USB를 다시 읽은 뒤 다시 시도하세요."), critical: true)
        case .restoreFailed:
            ReflectionPrompt(title: String(ui: "USB를 쓰기 전 상태로 되돌리지 못했습니다"),
                             text: String(ui: "USB를 기기에 꽂지 마세요. USB를 다시 연결하면 나오는 알림에서 회복하세요."), critical: true)
        case let .restorePending(reason):
            ReflectionPrompt(title: String(ui: "USB 복원을 미뤘습니다"),
                             text: String(ui: "\(reason). USB를 기기에 꽂지 말고, 이유를 푼 뒤 USB를 다시 연결하면 나오는 알림에서 회복하세요."),
                             critical: true)
        case .volumeLost:
            ReflectionPrompt(title: String(ui: "USB 연결이 끊겼습니다"),
                             text: String(ui: "USB를 기기에 꽂지 말고 다시 연결하세요. 다시 연결하면 나오는 알림에서 회복할 수 있습니다."),
                             critical: true)
        case .volumeChanged:
            ReflectionPrompt(title: String(ui: "쓰는 도중 USB가 바뀌어 멈췄습니다"),
                             text: String(ui: "지금 붙은 USB에는 쓰지 않았습니다. 처음 USB를 기기에 꽂지 말고 다시 연결하세요. 다시 연결하면 나오는 알림에서 회복할 수 있습니다."),
                             critical: true)
        default:
            nil
        }
    }

    /// 백업 폴더가 있을 때 끊긴 쓰기 창에 붙이는 단추
    public static func withBackupButtons(_ prompt: ReflectionPrompt) -> ReflectionPrompt {
        var shown = prompt
        shown.confirm = String(ui: "백업 폴더 열기")
        shown.cancel = String(ui: "닫기")
        return shown
    }

    /// 회복이 다시 계획하라고 했을 때
    public static var replanPrompt: ReflectionPrompt {
        ReflectionPrompt(title: String(ui: "USB 쓰기를 이어 하지 않았습니다"),
                         text: String(ui: "USB가 기기에서 바뀌어 이어 쓰지 않았습니다. 지금 USB 상태로 다시 미리 보기한 뒤 쓰세요"),
                         confirm: String(ui: "다시 미리 보기"), cancel: String(ui: "닫기"))
    }
}
