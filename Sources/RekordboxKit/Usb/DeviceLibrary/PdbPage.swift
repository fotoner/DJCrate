import DJCDomain
import Foundation

/// 쪽 머리(0x00–0x27). 데이터 쪽과 인덱스 쪽이 같은 자리를 쓴다.
public struct PdbPageHeader: Sendable, Hashable {
    public var pageIndex: UInt32
    public var type: UInt32
    /// 데이터 쪽: 다음 쪽(마지막이면 빈 후보), 인덱스 쪽: 첫 데이터 쪽
    public var nextPage: UInt32
    /// 그 쪽을 마지막으로 고친 순번
    public var sequence: UInt32
    public var u2: UInt32
    /// 할당한 행 자리 수(nro, 0x18–0x1A의 아래 13비트)
    public var rowSlots: Int
    /// 산 행 수(nr, 위 11비트)
    public var liveRows: Int
    /// 0x24 지운 행 없음, 0x34 지운 행 있음, 0x64 인덱스 쪽
    public var flags: UInt8
    public var freeSize: UInt16
    /// 힙 할당 바이트 합(죽은 행 포함)
    public var usedSize: UInt16
    public var txRowCount: UInt16
    public var txRowIndex: UInt16
    public var u6: UInt16
    /// 인덱스 쪽: 인덱스 항목 수
    public var u7: UInt16

    /// 인덱스 쪽(행이 없고 본문이 지운 행이 있는 쪽 목록)
    public var isIndex: Bool { flags & 0x40 != 0 }
}

/// 행 인덱스의 자리 하나
public struct PdbRowSlot: Sendable, Hashable {
    public var index: Int
    /// 힙 시작(0x28) 기준
    public var offset: Int
    /// presence 비트
    public var isLive: Bool
    public var inTransaction: Bool
}

/// 4096바이트 쪽 하나. 행 인덱스는 쪽 끝에서 거꾸로 16자리씩 묶인다.
public struct PdbPage: Sendable {
    public static let size = 4096
    public static let heapStart = 0x28
    /// 16자리 묶음 하나의 크기(tx u16 + presence u16 + 오프셋 u16 × 16)
    static let groupSize = 0x24

    public let header: PdbPageHeader
    public let data: Data
    public let slots: [PdbRowSlot]
    /// 자리마다 행 끝(힙 기준): 힙에서 그 행 뒤 가장 가까운 다른 행 오프셋, 없으면 used
    private let ends: [Int]

    /// 쪽 머리와 행 인덱스를 읽는다. 행 인덱스가 힙 시작까지 넘치면 `UsbError.readFailed`.
    public init(data: Data) throws {
        guard data.count == Self.size else { throw UsbError.readFailed(detail: "pdb page size \(data.count)") }
        let data = Data(data)
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * $1) } }
        let counts = Self.unpackRowCounts(data[0x18..<0x1B])
        let header = PdbPageHeader(pageIndex: u32(0x04), type: u32(0x08), nextPage: u32(0x0C), sequence: u32(0x10), u2: u32(0x14),
                                   rowSlots: counts.slots, liveRows: counts.live, flags: bytes[0x1B],
                                   freeSize: u16(0x1C), usedSize: u16(0x1E), txRowCount: u16(0x20), txRowIndex: u16(0x22),
                                   u6: u16(0x24), u7: u16(0x26))
        // 인덱스 쪽은 행이 없다(본문은 지운 행이 있는 쪽 목록)
        let slotCount = header.isIndex ? 0 : header.rowSlots
        guard Self.heapStart + Self.indexSize(slots: slotCount) <= Self.size else {
            throw UsbError.readFailed(detail: "pdb page \(header.pageIndex) row index overflows (\(slotCount) slots)")
        }
        var slots: [PdbRowSlot] = []
        slots.reserveCapacity(slotCount)
        for index in 0..<slotCount {
            let base = Self.size - (index / 16) * Self.groupSize, bit = index % 16
            slots.append(PdbRowSlot(index: index, offset: Int(u16(base - 6 - 2 * bit)),
                                    isLive: u16(base - 4) >> bit & 1 == 1, inTransaction: u16(base - 2) >> bit & 1 == 1))
        }
        let used = Int(header.usedSize)
        let offsets = Set(slots.map(\.offset)).sorted()
        ends = slots.map { slot in
            let next = offsets.first { $0 > slot.offset } ?? used
            return min(next, used)
        }
        self.header = header
        self.data = data
        self.slots = slots
    }

    /// 이 행 바이트(힙에서 다음 행 오프셋 또는 used까지). 오프셋이 힙 밖이면 빈 값
    public func row(_ slot: PdbRowSlot) -> Data {
        guard slots.indices.contains(slot.index) else { return Data() }
        let start = Self.heapStart + slot.offset, end = Self.heapStart + ends[slot.index]
        guard start < end, end <= data.count else { return Data() }
        return Data(data[start..<end])
    }

    /// 행 오프셋이 힙 안인지(used보다 앞, 행 인덱스보다 앞)
    public func isInsideHeap(_ slot: PdbRowSlot) -> Bool {
        slot.offset < Int(header.usedSize) && Self.heapStart + slot.offset < heapLimit
    }

    /// 힙이 넘지 말아야 할 끝(행 인덱스 시작)
    var heapLimit: Int { Self.size - Self.indexSize(slots: slots.count) }

    /// 0x18–0x1A: `nro + (nr << 13)`, 24비트 little-endian
    public static func packRowCounts(slots: Int, live: Int) -> Data {
        let packed = (slots & 0x1FFF) | (live & 0x7FF) << 13
        return Data([UInt8(packed & 0xFF), UInt8(packed >> 8 & 0xFF), UInt8(packed >> 16 & 0xFF)])
    }

    public static func unpackRowCounts(_ bytes: Data) -> (slots: Int, live: Int) {
        let raw = [UInt8](bytes)
        guard raw.count == 3 else { return (0, 0) }
        let packed = Int(raw[0]) | Int(raw[1]) << 8 | Int(raw[2]) << 16
        return (packed & 0x1FFF, packed >> 13)
    }

    /// 행 인덱스가 차지하는 바이트: 자리마다 오프셋 2, 16자리 묶음마다 presence·tx 4
    public static func indexSize(slots: Int) -> Int {
        2 * slots + 4 * ((slots + 15) / 16)
    }

    /// 쪽 머리 free 칸 = 4096 − 0x28 − used − 행 인덱스
    public static func freeSize(used: Int, slots: Int) -> Int {
        size - heapStart - used - indexSize(slots: slots)
    }
}
