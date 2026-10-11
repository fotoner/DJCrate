import Foundation

/// USB 분석 파일에 적을 큐 하나(로컬 `djmdCue` 행에서 읽은 값)
public struct UsbCueInput: Sendable, Hashable {
    public var id: String
    /// 0 메모리, 1–3 핫 A–C, 5–9 핫 D–H, 4 모름
    public var kind: Int
    public var inMsec: Int
    /// 루프가 아니면 inMsec 이하(보통 0 또는 -1)
    public var outMsec: Int
    /// NULL이면 빈 글자
    public var comment: String
    public var colorTableIndex: Int?
    public var color: Int?
    public var activeLoop: Int
    /// 상위 16비트 = 박 분자, 하위 = 분모(NULL이면 0)
    public var beatLoopSize: Int
    /// `createdAtRaw`를 시각으로 푼 값(풀지 못하면 nil)
    public var createdAt: Date?
    public var createdAtRaw: String
    /// InPointSeekInfo(FLAC "시작 샘플,바이트 위치,블록 크기")
    public var inSeek: UsbSeekInfo?
    public var outSeek: UsbSeekInfo?
    public var inMpegFrame: Int
    public var inMpegAbs: Int

    public init(id: String, kind: Int, inMsec: Int, outMsec: Int = -1, comment: String = "",
                colorTableIndex: Int? = nil, color: Int? = nil, activeLoop: Int = 0, beatLoopSize: Int = 0,
                createdAtRaw: String = "", inSeek: UsbSeekInfo? = nil, outSeek: UsbSeekInfo? = nil,
                inMpegFrame: Int = 0, inMpegAbs: Int = 0) {
        self.id = id
        self.kind = kind
        self.inMsec = inMsec
        self.outMsec = outMsec
        self.comment = comment
        self.colorTableIndex = colorTableIndex
        self.color = color
        self.activeLoop = activeLoop
        self.beatLoopSize = beatLoopSize
        self.createdAt = UsbCuePlacement.parseCreatedAt(createdAtRaw)
        self.createdAtRaw = createdAtRaw
        self.inSeek = inSeek
        self.outSeek = outSeek
        self.inMpegFrame = inMpegFrame
        self.inMpegAbs = inMpegAbs
    }

    public var traits: UsbCueTraits {
        UsbCueTraits(kind: kind, colorTableIndex: colorTableIndex, color: color, inMsec: inMsec, outMsec: outMsec,
                     activeLoop: activeLoop, beatLoopSize: beatLoopSize, inMpegFrame: inMpegFrame)
    }

    public var isLoop: Bool { outMsec > inMsec }

    /// 핫큐 번호(A=1 … H=8). 메모리 큐·Kind 4는 nil
    public var hotCueNumber: Int? { UsbCueRules.hotCueNumber(kind: kind) }
}

/// djmdCue의 InPointSeekInfo·OutPointSeekInfo("a,b,c")
public struct UsbSeekInfo: Sendable, Hashable {
    public var frame: UInt64
    public var offset: UInt64
    public var block: UInt32

    public init(frame: UInt64, offset: UInt64, block: UInt32) {
        self.frame = frame
        self.offset = offset
        self.block = block
    }

    /// "a,b,c" → 값. "0,0,0"·NULL·빈 글자·모양이 다른 글자는 nil(칸을 0으로 쓴다)
    public static func parse(_ text: String?) -> UsbSeekInfo? {
        guard let text else { return nil }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, let frame = UInt64(parts[0]), let offset = UInt64(parts[1]), let block = UInt32(parts[2]) else {
            return nil
        }
        if frame == 0 && offset == 0 && block == 0 { return nil }
        return UsbSeekInfo(frame: frame, offset: offset, block: block)
    }
}

/// 곡 하나의 큐를 USB 분석 파일의 큐 태그별로 나눈 것. 목록마다 순서가 정해져 있다.
public struct UsbCueLayout: Sendable, Hashable {
    /// .DAT PCOB(핫): 핫큐 A–C
    public var datHot: [UsbCueInput]
    /// .DAT PCOB(메모리): 메모리 큐 전부
    public var datMemory: [UsbCueInput]
    /// .EXT PCOB(핫): 핫큐 D–H
    public var extHot: [UsbCueInput]
    /// .EXT PCOB(메모리): 늘 비움
    public var extMemory: [UsbCueInput]
    /// .EXT PCO2(핫): 핫큐 A–H
    public var extAllHot: [UsbCueInput]
    /// .EXT PCO2(메모리): 메모리 큐 전부
    public var extAllMemory: [UsbCueInput]
    /// 어느 태그에도 넣지 않은 큐(Kind 4 등)
    public var dropped: [UsbCueInput]
}

/// 로컬 큐 → USB 분석 파일 큐 태그 배치. rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기).
public enum UsbCuePlacement {
    public static func layout(_ cues: [UsbCueInput]) -> UsbCueLayout {
        let memory = cues.filter { $0.kind == 0 }
        let hot = cues.filter { $0.hotCueNumber != nil }
        let dropped = cues.filter { $0.kind != 0 && $0.hotCueNumber == nil }
        return UsbCueLayout(
            datHot: ordered(hot.filter { (1...3).contains($0.kind) }),
            datMemory: ordered(memory),
            extHot: ordered(hot.filter { (5...9).contains($0.kind) }),
            extMemory: [],
            extAllHot: ordered(hot),
            extAllMemory: ordered(memory),
            dropped: dropped)
    }

    /// 목록 안 순서: created_at 내림차순, 같으면 InMsec 내림차순. 그래도 같으면 받은 순서.
    /// created_at을 하나라도 풀지 못하면 그 목록은 글자로 비교한다(형식이 섞이면 글자 순서가 시각 순서와 어긋난다).
    static func ordered(_ cues: [UsbCueInput]) -> [UsbCueInput] {
        let byDate = cues.allSatisfy { $0.createdAt != nil }
        return cues.enumerated().sorted { a, b in
            if byDate {
                let x = a.element.createdAt!, y = b.element.createdAt!
                if x != y { return x > y }
            } else if a.element.createdAtRaw != b.element.createdAtRaw {
                return a.element.createdAtRaw > b.element.createdAtRaw
            }
            if a.element.inMsec != b.element.inMsec { return a.element.inMsec > b.element.inMsec }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// "YYYY-MM-DD HH:MM:SS.fff +00:00" → 시각. 밀리초·시간대를 뺀 형식도 받는다(시간대가 없으면 UTC).
    /// 날짜와 시각 사이는 빈칸이나 "T", 시간대는 "+HH:MM"·"+HHMM"·"Z"(앞에 빈칸이 있어도 된다).
    public static func parseCreatedAt(_ raw: String) -> Date? {
        let text = Array(raw.trimmingCharacters(in: .whitespaces).utf8)
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= text.count else { return nil }
            var value = 0
            for byte in text[range] {
                guard (0x30...0x39).contains(byte) else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }
        func byte(_ index: Int) -> UInt8? { index < text.count ? text[index] : nil }
        guard let year = number(0..<4), byte(4) == UInt8(ascii: "-"), let month = number(5..<7), byte(7) == UInt8(ascii: "-"),
              let day = number(8..<10), byte(10) == UInt8(ascii: " ") || byte(10) == UInt8(ascii: "T"),
              let hour = number(11..<13), byte(13) == UInt8(ascii: ":"), let minute = number(14..<16),
              byte(16) == UInt8(ascii: ":"), let second = number(17..<19),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
        var p = 19
        var fraction = 0.0
        if byte(p) == UInt8(ascii: ".") {
            p += 1
            let start = p
            while let digit = byte(p), (0x30...0x39).contains(digit) { p += 1 }
            guard p > start, p - start <= 9, let digits = number(start..<p) else { return nil }
            // 정수로 모은 뒤 한 번에 나눠 ".500" 같은 값이 정확히 떨어지게 한다.
            fraction = Double(digits) / pow(10, Double(p - start))
        }
        if byte(p) == UInt8(ascii: " ") { p += 1 }
        var offset = 0
        if let sign = byte(p) {
            if sign == UInt8(ascii: "Z") {
                p += 1
            } else {
                guard sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-"), let hours = number(p + 1..<p + 3) else { return nil }
                var q = p + 3
                if byte(q) == UInt8(ascii: ":") { q += 1 }
                guard let minutes = number(q..<q + 2), hours < 24, minutes < 60 else { return nil }
                offset = (hours * 3_600 + minutes * 60) * (sign == UInt8(ascii: "-") ? -1 : 1)
                p = q + 2
            }
        }
        guard p == text.count else { return nil }
        let seconds = daysFromCivil(year: year, month: month, day: day) * 86_400 + hour * 3_600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    /// 그레고리력 날짜 → 1970-01-01부터 날 수
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
