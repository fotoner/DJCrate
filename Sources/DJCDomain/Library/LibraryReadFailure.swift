import Foundation

/// 마지막 정상 목록의 유무와 실패한 읽기 단계를 함께 보존한다.
public struct LibraryReadFailure: Equatable, Sendable {
    public enum Stage: Sendable { case snapshotCreation, opening, contents }
    public let stage: Stage
    public let keepsPreviousLibrary: Bool

    public init(stage: Stage, keepsPreviousLibrary: Bool) {
        self.stage = stage
        self.keepsPreviousLibrary = keepsPreviousLibrary
    }

    public var message: String {
        switch (stage, keepsPreviousLibrary) {
        case (.snapshotCreation, false):
            String(ui: "스냅샷을 새로 만들지 못했으니 rekordbox를 종료하고 파일 접근 권한을 확인한 뒤 다시 불러오세요")
        case (.snapshotCreation, true):
            String(ui: "스냅샷을 새로 만들지 못해 이전 목록을 표시하며 최근 변경은 확인되지 않았으니 rekordbox를 종료하고 파일 접근 권한을 확인한 뒤 다시 불러오세요")
        case (.opening, false):
            String(ui: "라이브러리 사본을 열지 못했으니 사본과 파일 접근 권한을 확인한 뒤 다시 불러오세요")
        case (.opening, true):
            String(ui: "라이브러리 사본을 열지 못해 이전 목록을 표시하며 최근 변경은 확인되지 않았으니 사본과 파일 접근 권한을 확인한 뒤 다시 불러오세요")
        case (.contents, false):
            String(ui: "라이브러리 사본의 내용을 읽지 못했으니 사본 상태를 확인하고 새 사본을 만든 뒤 다시 불러오세요")
        case (.contents, true):
            String(ui: "라이브러리 사본의 내용을 읽지 못해 이전 목록을 표시하며 최근 변경은 확인되지 않았으니 사본 상태를 확인하고 새 사본을 만든 뒤 다시 불러오세요")
        }
    }
}
