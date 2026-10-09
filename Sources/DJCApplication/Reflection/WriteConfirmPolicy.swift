import DJCDomain

/// 미리 보기 결과로 쓰기 전에 물을지 정한다(#210, #209 조사 1의 B칸).
/// rekordbox 쓰기는 쓰기 전 전체 백업·다시 읽기 검증·자동 복원이 있고 결과 토스트에서 쓰기 전으로 복원할 수 있다.
/// 그래서 막힘·제외·손실이 없고 백업을 만들 수 있으면 묻지 않고 바로 쓴다. 묻는 창에는 이 이유가 되는 항목만 보인다.
public enum WriteConfirmPolicy {
    public enum Reason: Equatable, Sendable {
        /// 쓰지 못하는 초안·곡이 있다(그 줄을 빼고 쓴다)
        case blocked
        /// 미리 보기 전에 빠진 초안이 있다(읽지 못한 초안 파일), 넣기는 분석·큐·키·앨범아트가 빠지는 곡이 있다
        case excluded
        /// 되돌려도 다른 곳의 변경까지 잃는 변경(중복 합치기는 곡을 컬렉션에서 뺀다)
        case loss
        /// 쓰기 전 백업 폴더에 쓸 수 없다
        case noBackup
    }

    /// 초안 쓰기(큐·그리드·분석·게인·태그·앨범아트·재생 목록·합치기)
    public static func reasons(_ report: RekordboxWriteReport, exclusions: [String], canBackUp: Bool) -> [Reason] {
        var reasons: [Reason] = []
        if !ReflectionPrompts.reasons(report).isEmpty { reasons.append(.blocked) }
        if !exclusions.isEmpty { reasons.append(.excluded) }
        if !report.mergeWritten.isEmpty { reasons.append(.loss) }
        if !canBackUp { reasons.append(.noBackup) }
        return reasons
    }

    /// 추가한 곡 넣기
    public static func addReasons(_ preview: TrackAddPreview, writesArtwork: Bool, canBackUp: Bool) -> [Reason] {
        var reasons: [Reason] = []
        if preview.report.added.contains(where: { !$0.written }) || !preview.unreadable.isEmpty { reasons.append(.blocked) }
        if !ReflectionPrompts.addShortfalls(preview, writesArtwork: writesArtwork).isEmpty { reasons.append(.excluded) }
        if !canBackUp { reasons.append(.noBackup) }
        return reasons
    }
}
