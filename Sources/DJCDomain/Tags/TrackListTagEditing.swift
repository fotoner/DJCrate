import Foundation

/// 곡 목록에서 바로 태그를 고치는 규칙(#88). 표(AppKit)와 나눠 시험한다.
///
/// - 시작: 이미 혼자 고른 줄의 태그 칸을 다시 한 번 누르고 잠깐 기다리기(Finder 이름 바꾸기처럼),
///   또는 곡을 고른 채 Return으로 보이는 첫 태그 칸. 더블클릭은 덱에 불러오기다(#93).
/// - 키·평점·곡 색 칸은 글자를 쓰지 않고 메뉴(없음·1A~12B, 없음·별 1~5개, 없음·rekordbox 여덟 색)로 고른다(#204·#65):
///   그 칸 더블클릭, 또는 그 칸을 누른 그 줄에서 Return. 글자 칸 흐름(다시 눌러 고치기·Return의 첫 칸·Tab)에는 끼지 않는다.
/// - Tab·⇧Tab: 확정하고 보이는 옆 태그 칸으로(끝이면 편집을 마친다) / Return: 확정 / Esc: 취소
/// - 고른 곡 안에서 고치면 고른 곡 모두에 적용한다(인스펙터 여러 곡 편집과 같다).
///   값이 서로 다르면 빈 칸으로 시작하고, 비운 채 나오면 그대로 둔다.
/// - 스트리밍 곡(파일 태그 없음)은 고치지 않는다. 저장은 초안·되돌리기 한 단위로만 한다.
///
/// 칸 이름과 고칠 수 있는지는 여기(순수 규칙), 표의 편집 흐름(대상 곡·칸 글자·클릭 판정)은 앱의 같은 이름 확장에 있다.
public enum TrackListTagEditing {
    /// 이 곡의 이 칸을 고칠 수 없는 이유(고칠 수 있으면 nil). 추가한 곡은 상태 칸이 없다.
    public static func unavailableReason(_ row: TrackRow, key: TagFields.Key?) -> String? {
        if row.isUsb { return String(ui: "USB 곡은 읽기 전용이니 로컬 라이브러리에서 태그를 편집하세요") }
        if row.track.isStreaming { return String(ui: "스트리밍 곡의 태그는 편집할 수 없으니 로컬 음원 파일이 있는 곡을 고르세요") }
        guard let key else { return String(ui: "이 칸은 읽기 전용이니 제목·아티스트·코멘트 같은 태그 칸을 고르세요") }
        // 칸마다 쓰기를 확인한 칸(평점·곡 색, #65): 추가한 곡은 넣은 뒤, 상태 0·256·257 밖의 곡은 쓰기와 같은 판단(`TagWriteScope`)으로 막는다(재생 목록에 든 곡은 R65로 열었다)
        guard TagWriteScope.byKey[key] != nil else { return nil }
        if row.isStaged { return String(ui: "추가한 곡의 \(key.label)은 rekordbox에 넣은 뒤 고치세요") }
        return TagWriteScope.blockReason(keys: [key], state: row.track.dataStatus, inPlaylist: row.inPlaylist)
    }

    /// 메뉴로 고르는 키 칸. 저장된 칸 배치·정렬 이름("key")을 그대로 두고 키 태그(musicalKey)에 잇는다.
    public static let keyColumn = "key"

    /// 목록 칸의 태그. 태그가 아닌 칸(BPM·분류 등)은 nil. 평점·곡 색 칸 이름은 태그 이름 그대로다("rating"·"color").
    public static func key(forColumn id: String) -> TagFields.Key? {
        id == keyColumn ? .musicalKey : TagFields.Key(rawValue: id)
    }

    /// 메뉴로 고르는 칸인지(키·평점·곡 색)
    public static func isMenuColumn(_ id: String) -> Bool { key(forColumn: id).map(TagChoice.keys.contains) ?? false }

    /// 칸 자리에 입력 칸을 띄워 고치는 태그 칸(키·평점·곡 색 칸은 메뉴라 빠진다)
    public static func isTextColumn(_ id: String) -> Bool { !isMenuColumn(id) && key(forColumn: id) != nil }

    /// Return으로 편집을 시작할 칸: 방금 누른 칸이 (보이는) 메뉴 칸(키·평점·곡 색)이면 그 메뉴, 아니면 보이는 첫 글자 칸.
    /// 글자 칸이 하나도 보이지 않아도 메뉴 칸을 누르지 않았으면 nil이다(메뉴는 누른 칸에서만 연다).
    /// `clicked`는 Return 대상 줄에서 누른 칸이어야 한다(다른 줄에서 누른 칸은 넘기지 않는다).
    public static func firstColumn(in visibleColumns: [String], clicked: String? = nil) -> String? {
        if let clicked, isMenuColumn(clicked), visibleColumns.contains(clicked) { return clicked }
        return visibleColumns.first(where: isTextColumn)
    }

    /// Tab(앞)·⇧Tab(뒤)으로 옮겨 갈 보이는 옆 글자 칸. 끝이면 nil(편집을 마친다). 메뉴 칸은 건너뛴다(메뉴가 Tab 흐름을 끊는다).
    public static func column(after id: String, forward: Bool, in visibleColumns: [String]) -> String? {
        let editable = visibleColumns.filter(isTextColumn)
        guard let index = editable.firstIndex(of: id) else { return nil }
        let next = index + (forward ? 1 : -1)
        return editable.indices.contains(next) ? editable[next] : nil
    }
}
