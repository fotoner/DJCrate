import Foundation

/// 곡 편집 창에서 재생선이 있는 줄: 원곡 전체, 편집 결과
public enum EditLane: Sendable, Equatable {
    case source, output
}

/// 결과 타임라인의 클립(목록 순서 = 출력 순서)
public struct EditEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var range: BarRange

    public init(id: UUID, range: BarRange) {
        self.id = id
        self.range = range
    }
}

/// 누르기·끌기가 읽는 편집 창 상태(누를 때마다 창 모델이 만든다)
public struct EditPointerContext: Sendable {
    /// 원곡 마디 눈금(편집할 수 없는 곡이면 nil)
    public var layout: BarLayout?
    public var entries: [EditEntry]
    /// 결과 타임라인에 그린 클립 자리(목록 순서). 규칙에 맞지 않는 목록도 그린다.
    public var clips: [TrackEdit.Piece]
    /// 원곡 줄에서 끌어 고른 마디 구간
    public var selection: BarRange?
    /// 결과가 규칙에 맞는지(맞지 않으면 결과 재생선을 옮기지 않는다)
    public var hasEdit: Bool

    public init(layout: BarLayout?, entries: [EditEntry], clips: [TrackEdit.Piece], selection: BarRange?, hasEdit: Bool) {
        self.layout = layout
        self.entries = entries
        self.clips = clips
        self.selection = selection
        self.hasEdit = hasEdit
    }

    /// 원곡 시각이 고른 구간 안인지(그 안을 아래로 끌면 결과로 끌어 넣는다)
    public func selectionContains(_ time: Double) -> Bool {
        guard let selection, let layout else { return false }
        return time >= layout.start(ofBar: selection.first) && time <= layout.end(ofBar: selection.last)
    }

    /// 고른 구간을 결과 시각 `time`에 놓으면 들어갈 자리
    public func insertion(atOutput time: Double) -> EditInsertion? {
        selection.flatMap { clips.insertion(of: $0, atOutput: time) }
    }

    /// 클립 가장자리를 `seconds`만큼 끌면 될 구간(마디 줄에 붙인다). 곡 머리는 맨 앞, 끝에서 잘린 마디는 맨 뒤 클립만.
    public func trimmed(_ id: EditEntry.ID, edge: EditEdge, by seconds: Double) -> BarRange? {
        guard let layout, let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return layout.trimmed(entries[index].range, edge: edge, by: seconds, leading: index == 0, trailing: index == entries.count - 1)
    }
}

/// 누르기·끌기가 편집 창에 시키는 일. 창 모델이 차례로 한다.
public enum EditPointerAction: Sendable, Equatable {
    /// 스페이스바·←→가 움직일 줄
    case focus(EditLane)
    /// 재생선을 끄는 중(재생 중이면 멈춘다)
    case scrub(EditLane, to: Double)
    /// 재생선 끌기를 마침(멈춘 재생은 그 자리에서 잇는다)
    case endScrub
    /// 원곡에서 두 시각으로 마디 구간 고르기
    case select(from: Double, to: Double)
    /// 끌어 고르기를 마침(재생선을 고른 구간 처음에)
    case finishSelection
    /// 원곡에서 고른 구간을 놓을 자리(결과 줄에 표시, nil이면 지움)
    case preview(EditInsertion?)
    case insert(EditInsertion)
    case seek(EditLane, to: Double)
    case selectClip(EditEntry.ID?)
    case moveClip(EditEntry.ID, toOffset: Int)
    case trim(EditEntry.ID, to: BarRange)
}

/// 두 줄의 누르기·끌기를 편집 동작으로 바꾼다. 뷰의 DragGesture는 좌표를 시각으로 바꿔 넘기기만 한다.
/// 위 눈금은 재생선만(끄는 동안 소리를 멈췄다가 손을 떼면 잇는다), 원곡 파형은 누르기 = 재생선·옆으로 끌기 = 마디 구간 고르기,
/// 고른 구간 안을 아래로 끌기 = 결과의 원하는 자리에 넣기. 결과는 클립 누르기 = 고르기·재생선, 클립 끌기 = 순서 바꾸기,
/// 클립 가장자리 끌기 = 마디 줄에 붙여 다듬기(손을 뗄 때 한 번에 바꿔 실행 취소 하나).
public struct EditPointer: Sendable {
    public enum Mode: Sendable, Equatable {
        case scrub
        /// 누른 클립(결과 줄, 없으면 nil)
        case press(clip: Int?)
        case select
        case move(EditEntry.ID)
        case trim(EditEntry.ID, EditEdge)
        /// 원곡에서 고른 구간을 결과로 끌어 넣는 중
        case carry
    }

    /// 다듬는 클립과 새 구간(끄는 동안 결과 줄에 그린다)
    public struct Trim: Sendable, Equatable {
        public var id: EditEntry.ID
        public var clip: Int
        public var edge: EditEdge
        public var range: BarRange

        public init(id: EditEntry.ID, clip: Int, edge: EditEdge, range: BarRange) {
            self.id = id
            self.clip = clip
            self.edge = edge
            self.range = range
        }
    }

    /// 이만큼(포인트) 움직이면 누르기가 아니라 끌기다.
    public static let slop: Double = 4
    /// 클립 가장자리를 잡는 폭(포인트, 가장자리 양쪽)
    public static let edgeReach: Double = 5

    public private(set) var mode: Mode?
    /// 끄는 클립을 놓을 자리(옮기기 전 기준 앞 클립 수)
    public private(set) var dropOffset: Int?
    public private(set) var trimming: Trim?
    /// 누른 클립 가장자리(끌면 다듬기)
    private var pressedEdge: EditEdgeHit?
    /// 원곡에서 끌어 오는 구간을 놓을 자리(마지막으로 보여 준 자리)
    private var carried: EditInsertion?

    public init() {}

    public var dragging: EditEntry.ID? {
        if case .move(let id) = mode { id } else { nil }
    }

    /// 원곡 줄. `moved`·`rise`는 누른 자리에서 가로·세로로 움직인 거리(포인트), `output`은 포인터가 결과 줄 위에 있으면 그 결과 시각.
    public mutating func source(_ context: EditPointerContext, from start: Double, to time: Double, inRuler: Bool, moved: Double,
                                rise: Double = 0, output: Double? = nil) -> [EditPointerAction] {
        if mode == nil { mode = inRuler ? .scrub : .press(clip: nil) }
        if mode == .press(clip: nil) {
            // 고른 구간을 아래(결과 쪽)로 끌면 넣기, 옆으로 끌면 예전처럼 새로 고르기
            if rise > Self.slop, rise > moved, context.selectionContains(start) {
                mode = .carry
            } else if moved > Self.slop {
                mode = .select
            }
        }
        switch mode {
        case .scrub: return [.scrub(.source, to: time)]
        case .select: return [.select(from: start, to: time)]
        case .carry:
            carried = output.flatMap { context.insertion(atOutput: $0) }
            return [.preview(carried)]
        default: return [.focus(.source)]
        }
    }

    public mutating func endSource(at time: Double) -> [EditPointerAction] {
        defer {
            mode = nil
            carried = nil
        }
        switch mode {
        case .scrub: return [.endScrub]
        case .select: return [.finishSelection]
        case .carry: return (carried.map { [.insert($0)] } ?? []) + [.preview(nil)]
        default: return [.seek(.source, to: time)]
        }
    }

    /// 결과 줄. `secondsPerPoint`는 지금 확대에서 한 포인트의 길이(초, 가장자리를 잡는 폭을 시각으로 바꾼다).
    public mutating func output(_ context: EditPointerContext, from start: Double, to time: Double, inRuler: Bool, moved: Double,
                                secondsPerPoint: Double = 0) -> [EditPointerAction] {
        if mode == nil {
            mode = inRuler ? .scrub : .press(clip: context.clips.clipIndex(atOutput: start))
            pressedEdge = inRuler ? nil : context.clips.edge(atOutput: start, tolerance: Self.edgeReach * secondsPerPoint)
        }
        switch mode {
        case .scrub:
            return [.scrub(.output, to: time)]
        case .press where moved > Self.slop && pressedEdge.map { context.entries.indices.contains($0.clip) } == true:
            let hit = pressedEdge!
            mode = .trim(context.entries[hit.clip].id, hit.edge)
            trim(context, from: start, to: time)
            return []
        case .press(let index?) where moved > Self.slop && context.entries.indices.contains(index):
            mode = .move(context.entries[index].id)
            dropOffset = context.clips.dropOffset(atOutput: time)
            return []
        case .move:
            dropOffset = context.clips.dropOffset(atOutput: time)
            return []
        case .trim:
            trim(context, from: start, to: time)
            return []
        default:
            return [.focus(.output)]
        }
    }

    private mutating func trim(_ context: EditPointerContext, from start: Double, to time: Double) {
        guard case let .trim(id, edge) = mode, let clip = context.entries.firstIndex(where: { $0.id == id }),
              let range = context.trimmed(id, edge: edge, by: time - start) else { return }
        trimming = Trim(id: id, clip: clip, edge: edge, range: range)
    }

    public mutating func endOutput(_ context: EditPointerContext, at time: Double) -> [EditPointerAction] {
        defer {
            mode = nil
            dropOffset = nil
            trimming = nil
            pressedEdge = nil
        }
        switch mode {
        case .scrub:
            return [.endScrub]
        case .move(let id):
            return dropOffset.map { [.moveClip(id, toOffset: $0)] } ?? []
        case .trim(let id, _):
            return trimming.map { [.trim(id, to: $0.range)] } ?? []
        case .press(let index):
            let id = index.flatMap { context.entries.indices.contains($0) ? context.entries[$0].id : nil }
            return [.selectClip(id)] + (context.hasEdit ? [.seek(.output, to: time)] : [])
        case .select, .carry, nil:
            return []
        }
    }
}
