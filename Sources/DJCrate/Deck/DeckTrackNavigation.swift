import DJCDomain

enum DeckTrackNavigation {
    static func adjacentRows<Rows: Sequence>(in rows: Rows, currentUUID: String?) -> (previous: TrackRow?, next: TrackRow?) where Rows.Element == TrackRow {
        var first: TrackRow?
        var previous: TrackRow?
        var foundCurrent = false
        for row in rows where !row.track.isStreaming {
            if foundCurrent { return (previous, row) }
            if first == nil { first = row }
            if row.track.uuid == currentUUID {
                foundCurrent = true
            } else {
                previous = row
            }
        }
        // 목록 밖의 곡은 이전=끝·다음=첫 곡, 마지막 곡은 다음 이웃이 없다.
        return (previous, foundCurrent ? nil : first)
    }
}
