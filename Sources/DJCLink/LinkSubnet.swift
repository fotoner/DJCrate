/// CDJ로 갈 인터페이스 고르기(#273). 같은 서브넷에 든 주소 가운데 마스크가 가장 좁은 것을 고른다.
/// 경로표는 169.254/16을 Wi‑Fi에도 두어 유선 CDJ를 Wi‑Fi로 보낼 수 있으므로 서브넷을 먼저 본다.
public enum LinkSubnet {
    /// 고른 후보의 자리. 같은 서브넷에 든 후보가 없으면 nil
    public static func pick(peer: [UInt8], among candidates: [(address: [UInt8], netmask: [UInt8])]) -> Int? {
        var best: (index: Int, bits: Int)?
        for (index, candidate) in candidates.enumerated() {
            guard candidate.address.count == 4, candidate.netmask.count == 4, peer.count == 4 else { continue }
            let bits = candidate.netmask.reduce(0) { $0 + $1.nonzeroBitCount }
            // 0.0.0.0 마스크는 모든 주소를 품으므로 고르지 않는다
            guard bits > 0, candidate.address != peer,
                  zip(zip(candidate.address, candidate.netmask), peer).allSatisfy({ $0.0 & $0.1 == $1 & $0.1 }) else { continue }
            if best.map({ bits > $0.bits }) ?? true { best = (index, bits) }
        }
        return best?.index
    }
}
