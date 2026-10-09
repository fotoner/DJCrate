import DJCDomain
import Foundation

/// 미리 보기 요약(시트·확인 창이 보인다). 곡 제목·경로는 담지 않는다
public struct UsbExportSummary: Equatable, Sendable {
    /// 막힘 code 하나와 그 대상 수(같은 곡·목록은 한 번)
    public struct BlockCount: Equatable, Sendable {
        /// 무엇을 막는지: 곡·재생 목록은 빼고 쓰고, 그 밖(볼륨·형식·파일)은 쓰기를 멈춘다
        public enum Kind: Equatable, Sendable { case track, playlist, stopping }

        public var code: String
        public var message: String
        public var count: Int
        public var kind: Kind

        public init(code: String, message: String, count: Int, kind: Kind) {
            self.code = code
            self.message = message
            self.count = count
            self.kind = kind
        }
    }

    public struct RuleCount: Equatable, Sendable {
        public var rule: UsbProvisionalRule
        /// 규칙이 걸린 곡 수(곡 단위가 아니면 0)
        public var count: Int

        public init(rule: UsbProvisionalRule, count: Int) {
            self.rule = rule
            self.count = count
        }
    }

    public var trackCount: Int
    public var playlistCount: Int
    /// 빼고 쓰는 곡 수(같은 곡은 한 번)
    public var blockedTrackCount: Int
    /// 빼고 쓰는 재생 목록 수(같은 목록은 한 번)
    public var blockedPlaylistCount: Int
    /// 막힘 code별 수(처음 나온 순서)
    public var blockCounts: [BlockCount]
    /// 쓰기를 멈추는 막힘(볼륨·형식·파일 단위)의 문구
    public var stopping: [String]
    public var stoppingCodes: [String]
    /// CDJ에서 확인하지 않은 항목(`UsbProvisionalRule.needsDeviceCheck`, 이름 순). 쓰기를 막지 않고 알리기만 한다
    public var rules: [RuleCount]
    /// 그 항목이 하나라도 걸린 곡 수(같은 곡은 한 번)
    public var unverifiedTrackCount: Int
    public var requiredBytes: Int64
    public var availableBytes: Int64
    /// 준비한 변경 묶음이 있는지(막는 것이 없을 때만 있다)
    public var hasChanges: Bool
    /// 디스크 이미지(시험 볼륨)
    public var isTestVolume: Bool

    public init(trackCount: Int, playlistCount: Int, blocks: [UsbBlock], ruleCounts: [UsbProvisionalRule: Int], requiredRules: Set<UsbProvisionalRule>,
         requiredBytes: Int64, availableBytes: Int64, hasChanges: Bool, isTestVolume: Bool, unverifiedTrackCount: Int = 0) {
        self.trackCount = trackCount
        self.playlistCount = playlistCount
        var order: [String] = [], targets: [String: Set<UsbBlock.Scope>] = [:], messages: [String: String] = [:]
        var tracks: Set<String> = [], playlists: Set<String> = [], stopping: [String] = [], codes: [String] = []
        for block in blocks {
            if targets[block.code] == nil { order.append(block.code) }
            targets[block.code, default: []].insert(block.scope)
            if messages[block.code] == nil { messages[block.code] = block.message }
            switch block.scope {
            case let .track(id): tracks.insert(id)
            case let .playlist(id): playlists.insert(id)
            case .volume, .format, .file:
                if !stopping.contains(block.message) { stopping.append(block.message) }
                if !codes.contains(block.code) { codes.append(block.code) }
            }
        }
        blockCounts = order.map { code in
            let scopes = targets[code] ?? []
            // 한 code가 여러 단위에 걸리면 곡 → 재생 목록 → 멈춤 순으로 본다
            let kind: BlockCount.Kind = if scopes.contains(where: { if case .track = $0 { true } else { false } }) {
                .track
            } else if scopes.contains(where: { if case .playlist = $0 { true } else { false } }) {
                .playlist
            } else {
                .stopping
            }
            return BlockCount(code: code, message: messages[code] ?? "", count: scopes.count, kind: kind)
        }
        blockedTrackCount = tracks.count
        blockedPlaylistCount = playlists.count
        self.stopping = stopping
        stoppingCodes = codes
        rules = UsbProvisionalRule.deviceCheckRules(requiredRules).map { RuleCount(rule: $0, count: ruleCounts[$0] ?? 0) }
        self.unverifiedTrackCount = unverifiedTrackCount
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
        self.hasChanges = hasChanges
        self.isTestVolume = isTestVolume
    }

    public init(preview: UsbExportPreview, volume: UsbVolumeInfo) {
        self.init(trackCount: preview.plan.tracks.count, playlistCount: preview.plan.playlists.count, blocks: preview.blocks,
                  ruleCounts: preview.ruleCounts, requiredRules: preview.requiredRules, requiredBytes: preview.requiredBytes,
                  availableBytes: preview.availableBytes, hasChanges: preview.changes != nil, isTestVolume: volume.isDiskImage,
                  unverifiedTrackCount: preview.plan.tracks.filter { $0.rules.contains(where: \.needsDeviceCheck) }.count)
    }

    public var isShortOfSpace: Bool { stoppingCodes.contains("insufficientSpace") || requiredBytes > availableBytes }
    public var isPhysicalDisabled: Bool { stoppingCodes.contains("physicalDisabled") }
    public var canWrite: Bool { stopping.isEmpty && hasChanges && trackCount > 0 && !isShortOfSpace }

    /// "필요 공간 N MB · 여유 M MB"(필요는 올림, 여유는 내림 — 쓰기 절차의 용량 확인과 같은 쪽으로)
    public var spaceText: String {
        let megabyte: Int64 = 1024 * 1024
        return String(ui: "필요 공간 \((requiredBytes + megabyte - 1) / megabyte)MB · 여유 \(availableBytes / megabyte)MB")
    }
}
