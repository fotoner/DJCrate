import Foundation

/// 편집 창(곡 편집·Flip)을 열 때 덱에서 읽어 둔 원곡 상태. 창은 덱을 들고 있지 않고 이 값으로 편집할 수 있는지 정한다.
public struct EditSourceState: Sendable, Equatable {
    public var isStreaming: Bool
    /// 음원 파일이 있는지(열 때 메인 스레드 밖에서 확인한다)
    public var audioFileExists: Bool
    /// 덱이 재생할 수 없으면 그 이유(재생할 수 있으면 nil)
    public var playbackUnavailableReason: String?
    /// 덱의 그리드(템포 구간). 그리드 초안이 없으면 비어 있다.
    public var segments: [GridSegment]
    public var gridUnavailableReason: String?
    /// 원본 그리드를 읽지 못한 안내(분석 파일 없음 등)
    public var gridSourceNotice: String?
    /// 원본 그리드를 정확히 옮길 수 없어 편집을 막은 이유(다이내믹 그리드 등)
    public var gridEditBlockedReason: String?

    public init(isStreaming: Bool, audioFileExists: Bool, playbackUnavailableReason: String?, segments: [GridSegment],
                gridUnavailableReason: String?, gridSourceNotice: String?, gridEditBlockedReason: String?) {
        self.isStreaming = isStreaming
        self.audioFileExists = audioFileExists
        self.playbackUnavailableReason = playbackUnavailableReason
        self.segments = segments
        self.gridUnavailableReason = gridUnavailableReason
        self.gridSourceNotice = gridSourceNotice
        self.gridEditBlockedReason = gridEditBlockedReason
    }

    public static var streamingReason: String { String(ui: "스트리밍 곡은 편집할 수 없습니다. 파일로 된 곡을 고르세요") }
    public static var missingFileReason: String { String(ui: "음원 파일이 없습니다. 외장 드라이브가 연결됐는지 확인하세요") }
    public static var noGridReason: String {
        String(ui: "그리드에 템포 구간이 없으니 추정 그리드를 적용하거나 rekordbox에서 트랙 분석을 먼저 하세요")
    }
    public static var flipNoGridNotice: String {
        String(ui: "원곡에 그리드가 없어 그리드 없이 넣습니다. 추가한 곡에서 그리드를 추정하세요")
    }
    public static var flipGridBlockedNotice: String {
        String(ui: "원곡 그리드를 정확히 옮길 수 없어(다이내믹 그리드 등) 그리드 없이 넣습니다. 추가한 곡에서 그리드를 추정하세요")
    }

    /// 곡 편집 창: 막는 이유는 스트리밍 → 음원 없음 → 덱 재생 불가 → 그리드 없음 → 그리드 편집 막힘 → 마디 눈금 순서로 본다.
    public func trackEditOpening(duration: Double) -> EditOpening {
        if isStreaming { return .blocked(Self.streamingReason) }
        if !audioFileExists { return .blocked(Self.missingFileReason) }
        if let playbackUnavailableReason { return .blocked(playbackUnavailableReason) }
        if segments.isEmpty { return .blocked(gridUnavailableReason ?? gridSourceNotice ?? Self.noGridReason) }
        if let gridEditBlockedReason { return .blocked(gridEditBlockedReason) }
        do {
            return .ready(try BarLayout(grid: segments, duration: duration))
        } catch DJCError.editRefused(let reason) {
            return .blocked(reason)
        } catch {
            return .blocked(String(describing: error))
        }
    }

    /// Flip 결과는 음원 파일만 있으면 만든다(그리드가 없거나 옮길 수 없으면 그리드 없이 넣는다).
    public var flipBlockedReason: String? {
        isStreaming || !audioFileExists ? Self.missingFileReason : nil
    }

    /// Flip 출력 그리드와 그리드를 뺀 까닭
    public func flipGrid(_ flip: FlipEdit) -> (grid: [GridSegment], notice: String?) {
        if segments.isEmpty { return ([], Self.flipNoGridNotice) }
        if gridEditBlockedReason != nil { return ([], Self.flipGridBlockedNotice) }
        return (flip.outputGrid(segments), nil)
    }
}

/// 곡 편집 창을 열 때: 편집할 수 있으면 원곡 마디 눈금, 없으면 이유와 할 일
public enum EditOpening: Sendable, Equatable {
    case ready(BarLayout)
    case blocked(String)

    public var layout: BarLayout? {
        if case .ready(let layout) = self { layout } else { nil }
    }

    public var blockedReason: String? {
        if case .blocked(let reason) = self { reason } else { nil }
    }
}

/// 렌더한 편집본의 파일 이름
public enum EditOutputName {
    /// 제목을 파일 이름으로: 경로 글자(/ :)는 바꾸고, 숨김 파일이 되지 않게 앞 점을 뺀다.
    public static func fileName(for title: String) -> String {
        var name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Edit" : String(name.prefix(120))
    }

    /// 이미 있는 파일은 덮지 않고 " 2", " 3"… 을 붙인다. `exists`는 파일 있음(부르는 쪽이 메인 스레드 밖에서 본다).
    public static func available(in directory: URL, name: String, exists: (URL) -> Bool) -> URL {
        var candidate = directory.appending(path: "\(name).wav")
        var number = 2
        while exists(candidate) {
            candidate = directory.appending(path: "\(name) \(number).wav")
            number += 1
        }
        return candidate
    }
}

public extension TrackEdit {
    /// 이음새(`pieces[piece]`의 시작) 앞 2마디부터 뒤 2마디까지(조각이 짧으면 그 조각 안에서). 첫 조각·없는 조각이면 nil.
    func seamAudition(_ piece: Int) -> ClosedRange<Double>? {
        guard pieces.indices.contains(piece), piece > 0 else { return nil }
        let seam = pieces[piece].outputStart, span = 2 * layout.barLength
        return max(pieces[piece - 1].outputStart, seam - span)...min(pieces[piece].outputEnd, seam + span)
    }
}
