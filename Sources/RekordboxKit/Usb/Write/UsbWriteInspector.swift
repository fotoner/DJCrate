import DJCDomain
import Foundation

/// 쓰기 전 확인(A 단계)에 형식별 막힘을 더한다. 형식을 아는 세션(내보내기·수정)이 준다.
public protocol UsbWriteInspector: Sendable {
    func blocks(root: UsbRoot, changes: UsbChangeSet) throws -> [UsbBlock]
}
