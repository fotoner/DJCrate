import DJCDomain
import Foundation

/// 보존한 기기 재생 기록 파일(피동 포트, #43). 실제 구현은 DJCAdapters가 DJCStorage `UsbHistoryStore`(DJC_HOME의 `usb-histories/`,
/// 기록마다 JSON 한 파일, 내구 쓰기)로 채운다. USB·rekordbox 라이브러리에는 쓰지 않는다. 메인 스레드 밖에서 부른다.
public struct UsbHistoryFiles: Sendable {
    /// 보존한 기록 전부(가져온 차례). 해석하지 못한 파일은 `damaged-drafts/usb-histories/`로 옮기고, 읽거나 옮기지 못한 파일은 그 자리에 둔다
    public var load: @Sendable () -> ArchivedHistoryLoad
    /// 기록 하나를 "<id>.json"으로 내구 쓰기한다. 저장할 수 없는 ID면 아무것도 쓰지 않고 던진다
    public var save: @Sendable (ArchivedHistory) throws -> Void
    /// 저장 오류 뒤 같은 ID의 파일 내용이 이 기록과 같은지 읽기만 해서 본다(rename 뒤 폴더 fsync만 실패했을 때)
    public var containsExact: @Sendable (ArchivedHistory) -> Bool

    public init(load: @escaping @Sendable () -> ArchivedHistoryLoad, save: @escaping @Sendable (ArchivedHistory) throws -> Void,
                containsExact: @escaping @Sendable (ArchivedHistory) -> Bool) {
        self.load = load
        self.save = save
        self.containsExact = containsExact
    }
}

/// 보존 기록 폴더를 읽은 결과
public struct ArchivedHistoryLoad: Sendable, Equatable {
    public var histories: [ArchivedHistory]
    /// 읽지 못해 damaged-drafts로 옮긴 파일 이름
    public var damaged: [String]
    /// 읽기·손상 보관에 실패해 그대로 둔 파일 이름. 폴더 열거 실패면 폴더 이름
    public var unreadable: [String]

    public init(histories: [ArchivedHistory] = [], damaged: [String] = [], unreadable: [String] = []) {
        self.histories = histories
        self.damaged = damaged
        self.unreadable = unreadable
    }
}
