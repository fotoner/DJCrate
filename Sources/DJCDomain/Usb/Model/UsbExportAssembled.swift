import Foundation

/// 준비를 마친 내보내기: 변경 묶음과 검증기에 줄 기대 모델
public struct UsbExportAssembled: Sendable {
    public var changes: UsbChangeSet
    /// 계획 경고 + 분석 파일 변환 경고(같은 code·곡은 한 번)
    public var warnings: [UsbBlock]
    /// 빌더 모델(OneLibrary 검증 기대값)
    public var library: UsbLibrary
    /// Device Library 작성기가 실제로 쓴 모델(pdb 검증 기대값). Device Library를 쓰지 않으면 nil
    public var pdbWritten: UsbLibrary?
    /// 확인 안 된 규칙별 곡 수(계획 규칙 + pdb 트랙 문자열 규칙, 같은 곡은 한 번)
    public var ruleCounts: [UsbProvisionalRule: Int]
    /// 파일 크기 칸이 음원 파일과 다르게 쓰이는 곡(USB content id, `audioChangedSinceAnalysis`). 불변식 검증이 크기 비교를 뺀다
    public var audioSizeFromDatabase: Set<Int>

    public init(changes: UsbChangeSet, warnings: [UsbBlock], library: UsbLibrary, pdbWritten: UsbLibrary?,
                ruleCounts: [UsbProvisionalRule: Int], audioSizeFromDatabase: Set<Int> = []) {
        self.changes = changes
        self.warnings = warnings
        self.library = library
        self.pdbWritten = pdbWritten
        self.ruleCounts = ruleCounts
        self.audioSizeFromDatabase = audioSizeFromDatabase
    }
}
