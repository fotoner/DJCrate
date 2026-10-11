import Foundation

/// 로컬 곡 하나의 갱신 횟수(djmdContent의 TrackInfoUpdated·AnalysisUpdated·CueUpdated 문자열 그대로, NULL은 nil)
public struct LocalTrackCounters: Sendable, Hashable {
    public var information: String?
    public var analysis: String?
    public var cue: String?

    public init(information: String?, analysis: String?, cue: String?) {
        self.information = information
        self.analysis = analysis
        self.cue = cue
    }
}

/// 로컬 라이브러리(스냅샷 사본)의 짝짓기 키. `UsbTrackMatch`·`UsbSyncStatus` 입력.
/// 값만 둔다. 사본에서 읽는 일(SQL)은 RekordboxKit `LocalLibraryKeysReader`, 유스케이스는 포트 `LocalLibraryKeysSource`로 받는다
public struct LocalLibraryKeys: Sendable {
    /// djmdProperty.DBID
    public var localDBID: Int64
    /// ContentID·MasterSongID·FileNameL·FolderPath
    public var tracks: [UsbLocalTrackKey]
    /// 로컬 ContentID → 갱신 횟수
    public var counters: [String: LocalTrackCounters]
    /// 로컬 ContentID → 그 행의 MasterDBID. 다른 라이브러리에서 가져온 곡은 이 라이브러리 DBID와 다르다.
    /// 내보내기·쓰기 계획은 이 값으로 USB 곡과 잇는다. 없으면 이 라이브러리 DBID로 본다
    public var masterDBIDs: [String: Int64] = [:]

    public init(localDBID: Int64, tracks: [UsbLocalTrackKey], counters: [String: LocalTrackCounters], masterDBIDs: [String: Int64] = [:]) {
        self.localDBID = localDBID
        self.tracks = tracks
        self.counters = counters
        self.masterDBIDs = masterDBIDs
    }

    public func masterDBID(of contentID: String) -> Int64 { masterDBIDs[contentID] ?? localDBID }
}
