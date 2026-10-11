import DJCDomain
import Foundation

/// DJCrate 초안(큐·그리드)을 이미 rekordbox 컬렉션에 있는 곡에 반영하는 계획·XML·검증.
///
/// rekordbox DB는 직접 고치지 않는다. rekordbox XML로 만들어 사용자가 "Import To Collection"하면
/// rekordbox가 그 곡의 큐 목록을 **통째로** XML 내용으로 바꾼다. 그래서 XML에는 초안에서 다루지 않은
/// 큐(자동 큐·루프)까지 원본 그대로 모두 넣는다. XML로 옮길 수 없는 정보(ActiveLoop·핫큐 색·Kind 4)가
/// 있는 곡은 잃지 않도록 계획 단계에서 막는다. 가져온 뒤에는 새 스냅샷과 비교해 검증한다.
/// 시각은 모두 rekordbox 시간축(초)이다.
public enum Reflection {
    /// 계획·검증의 값은 DJCDomain에 있다(반영 묶음 저장이 포트 뒤로 가도록)
    public typealias Mark = ReflectionXMLMark
    public typealias Plan = ReflectionXMLPlan
    public typealias Metadata = ReflectionXMLMetadata
    public typealias Check = ReflectionXMLCheck

    /// rekordbox Kind → XML Num(-1 = 메모리, 0…7 = A…H). 모르는 종류면 nil.
    public static func xmlNum(forKind kind: Int) -> Int? {
        switch kind {
        case 0: -1
        case 1, 2, 3: kind - 1
        case 5...9: kind - 2
        default: nil
        }
    }

    // MARK: - 계획

    /// 원본 큐 행 전부에 초안의 변경(삭제·이동·종류·이름·추가)만 얹는다. 초안에 없는 큐(자동 큐를 빼고 만든 옛 초안의 자동 큐 등)와
    /// 루프 끝은 원본 그대로 둔다(이동한 루프는 길이를 유지한다). 초안에 있는 자동 큐는 다른 큐와 같이 초안 값을 따른다(#145).
    public static func plan(track: Track, rawCues: [Cue], cueDraft: CueDraft?, gridDraft: GridDraft?) -> Plan {
        var blockers: [String] = []
        if track.isStreaming { blockers.append(String(ui: "스트리밍 곡은 XML로 만들 수 없습니다")) }
        if rawCues.contains(where: { $0.activeLoop > 0 }) {
            blockers.append(String(ui: "자동 루프(ActiveLoop) 표시가 있는 큐가 있습니다. XML로는 이 표시를 옮길 수 없습니다"))
        }
        if rawCues.contains(where: { !$0.isMemoryCue && ($0.colorTableIndex ?? 0) > 0 }) {
            blockers.append(String(ui: "색을 지정한 핫큐가 있습니다. rekordbox 색 번호와 XML 색의 대응을 확인하기 전이라 막아 둡니다"))
        }
        if rawCues.contains(where: { xmlNum(forKind: $0.kind) == nil }) {
            blockers.append(String(ui: "종류를 모르는 큐(Kind 4)가 있습니다"))
        }

        // 초안 큐: 원본에서 온 것은 sourceID(= djmdCue.ID)로 짝짓는다.
        let draftCues = cueDraft?.cues ?? []
        let draftBySource = Dictionary(draftCues.compactMap { cue in cue.sourceID.map { ($0, cue) } }, uniquingKeysWith: { a, _ in a })
        let baseSources = Set((cueDraft?.base ?? []).compactMap(\.sourceID))
        let beforeMarks = marks(from: rawCues)
        var marks: [Mark] = []
        for raw in rawCues.sorted(by: { $0.inMsec < $1.inMsec }) {
            guard let rawNum = xmlNum(forKind: raw.kind) else { continue }
            let start = Double(raw.inMsec) / 1000
            let end = raw.isLoop ? Double(raw.outMsec) / 1000 : nil
            var mark = Mark(name: raw.name, type: raw.isLoop ? 4 : 0, start: start, end: end, num: rawNum)
            if baseSources.contains(raw.id) {
                // 초안이 다루는 큐: 지웠으면 빼고, 바꿨으면 반영한다.
                guard let edited = draftBySource[raw.id] else { continue }
                let shift = edited.time - start
                mark.start = edited.time
                mark.end = end.map { $0 + shift }
                mark.num = xmlNum(for: edited.kind)
                mark.name = edited.name
            }
            marks.append(mark)
        }
        for added in draftCues where added.sourceID == nil {
            marks.append(Mark(name: added.name, type: added.loop == nil ? 0 : 4, start: added.time, end: added.loop?.end,
                              num: xmlNum(for: added.kind)))
        }
        marks.sort { ($0.start, $0.num) < ($1.start, $1.num) }

        let hotNums = marks.map(\.num).filter { $0 >= 0 }
        if Set(hotNums).count != hotNums.count { blockers.append(String(ui: "같은 핫큐 칸에 큐가 둘 이상 있습니다")) }
        if marks.contains(where: { $0.start < 0 || Double(track.lengthSeconds) + 1 < $0.start }) {
            blockers.append(String(ui: "곡 범위를 벗어난 큐가 있습니다"))
        }

        let cueChanged = !(cueDraft?.changes.isEmpty ?? true)
        let gridChanged = gridDraft?.hasChanges ?? false
        let tempos = gridChanged ? RekordboxXML.normalized(gridDraft?.segments ?? []) : nil
        if gridChanged, tempos?.isEmpty ?? true { blockers.append(String(ui: "그리드 초안이 비어 있습니다")) }
        return Plan(trackID: track.id, uuid: track.uuid, path: track.folderPath, title: track.title, marks: marks,
                    tempos: tempos, blockers: blockers, cueChanged: cueChanged, gridChanged: gridChanged,
                    before: Metadata(track), beforeMarks: beforeMarks)
    }

    /// rekordbox 큐 행 → XML 표시(알 수 없는 종류는 뺀다).
    public static func marks(from cues: [Cue]) -> [Mark] {
        cues.compactMap { cue -> Mark? in
            guard let num = xmlNum(forKind: cue.kind) else { return nil }
            return Mark(name: cue.name, type: cue.isLoop ? 4 : 0, start: Double(cue.inMsec) / 1000,
                        end: cue.isLoop ? Double(cue.outMsec) / 1000 : nil, num: num)
        }.sorted { ($0.start, $0.num) < ($1.start, $1.num) }
    }

    /// 두 큐 목록이 같은가(위치 ±2ms). 다르면 (빠진 것, 남는 것).
    static func difference(expected: [Mark], actual: [Mark]) -> (missing: [Mark], extra: [Mark]) {
        var remaining = actual
        var missing: [Mark] = []
        for mark in expected {
            if let i = remaining.firstIndex(where: { same($0, mark) }) { remaining.remove(at: i) } else { missing.append(mark) }
        }
        return (missing, remaining)
    }

    static func xmlNum(for kind: EditableCue.Kind) -> Int {
        switch kind {
        case .memory: -1
        case let .hot(slot): slot
        }
    }

    // MARK: - XML

    /// 반영용 XML. 곡 정보는 지금 rekordbox 값을 그대로 넣는다(가져오기가 곡 정보를 바꾸지 않게).
    public static func document(plans: [Plan], playlistName: String) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<DJ_PLAYLISTS Version="1.0.0">"#,
            #"  <PRODUCT Name="DJCrate" Version="0.1" Company=""/>"#,
            #"  <COLLECTION Entries="\#(plans.count)">"#,
        ]
        for (index, plan) in plans.enumerated() {
            let m = plan.before
            var attributes: [(String, String)] = [
                ("TrackID", "\(index + 1)"), ("Name", m.title), ("Artist", m.artist), ("Composer", m.composer),
                ("Album", m.album), ("Genre", m.genre),
                ("Kind", RekordboxXML.kind(forExtension: (plan.path as NSString).pathExtension)),
            ]
            if let size = (try? FileManager.default.attributesOfItem(atPath: plan.path))?[.size] as? NSNumber {
                attributes.append(("Size", size.stringValue))
            }
            attributes.append(("TotalTime", "\(m.lengthSeconds)"))
            if let n = m.trackNumber { attributes.append(("TrackNumber", "\(n)")) }
            if let y = m.year { attributes.append(("Year", "\(y)")) }
            if let bpm = plan.tempos?.first?.bpm ?? m.bpm { attributes.append(("AverageBpm", String(format: "%.2f", bpm))) }
            if !m.importedOn.isEmpty { attributes.append(("DateAdded", m.importedOn)) }
            attributes += [("Comments", m.comment)]
            if !m.key.isEmpty { attributes.append(("Tonality", m.key)) }
            attributes.append(("Location", RekordboxXML.location(forPath: plan.path)))
            lines.append("    <TRACK " + attributes.map { "\($0.0)=\"\(RekordboxXML.escape($0.1))\"" }.joined(separator: " ") + ">")
            for tempo in plan.tempos ?? [] {
                lines.append(#"      <TEMPO Inizio="\#(String(format: "%.3f", tempo.start))" Bpm="\#(String(format: "%.2f", tempo.bpm))" Metro="4/4" Battito="\#(tempo.firstBeatNumber)"/>"#)
            }
            for mark in plan.marks {
                var line = #"      <POSITION_MARK Name="\#(RekordboxXML.escape(mark.name))" Type="\#(mark.type)" Start="\#(String(format: "%.3f", mark.start))""#
                if let end = mark.end { line += #" End="\#(String(format: "%.3f", end))""# }
                line += #" Num="\#(mark.num)"/>"#
                lines.append(line)
            }
            lines.append("    </TRACK>")
        }
        lines += [
            "  </COLLECTION>",
            "  <PLAYLISTS>",
            #"    <NODE Type="0" Name="ROOT" Count="1">"#,
            #"      <NODE Name="\#(RekordboxXML.escape(playlistName))" Type="1" KeyType="0" Entries="\#(plans.count)">"#,
        ]
        for index in plans.indices { lines.append(#"        <TRACK Key="\#(index + 1)"/>"#) }
        lines += ["      </NODE>", "    </NODE>", "  </PLAYLISTS>", "</DJ_PLAYLISTS>"]
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 검증

    /// 새 스냅샷의 곡 상태와 계획을 비교한다.
    public static func verify(_ plan: Plan, track: Track, cues: [Cue], grid: BeatGrid?) -> Check {
        var problems: [String] = []
        let actual = marks(from: cues)
        let (missing, extra) = difference(expected: plan.marks, actual: actual)
        if !missing.isEmpty { problems.append(String(ui: "들어가지 않은 큐 \(missing.count)개(예: \(describe(missing[0])))")) }
        if !extra.isEmpty { problems.append(String(ui: "의도하지 않은 큐 \(extra.count)개(예: \(describe(extra[0])))")) }
        let cuesUnchanged = difference(expected: plan.beforeMarks, actual: actual) == ([], [])

        // 그리드
        var gridMatched = true
        if let tempos = plan.tempos, !tempos.isEmpty {
            if let grid, !grid.beats.isEmpty {
                let intended = GridDraft(trackUUID: "", base: [], segments: tempos).grid(duration: Double(track.lengthSeconds) + 1)
                var worst = 0.0
                for beat in grid.beats where beat.time > 5 && beat.time < Double(track.lengthSeconds) - 5 {
                    let i = intended.firstIndex(atOrAfter: beat.time)
                    let near = [i - 1, i].filter { intended.beats.indices.contains($0) }.map { abs(intended.beats[$0].time - beat.time) }
                    worst = max(worst, near.min() ?? 1)
                }
                if worst > 0.003 {
                    gridMatched = false
                    problems.append(String(ui: "그리드가 최대 \(worst * 1000, specifier: "%.0f")ms 다릅니다"))
                }
            } else {
                gridMatched = false
                problems.append(String(ui: "rekordbox 그리드를 읽지 못했습니다(분석 전?)"))
            }
        }

        // 곡 정보는 바뀌면 안 된다
        let now = Metadata(track)
        var metadataChanged = false
        for (label, a, b) in [(String(ui: "제목"), plan.before.title, now.title), (String(ui: "아티스트"), plan.before.artist, now.artist),
                              (String(ui: "앨범"), plan.before.album, now.album), (String(ui: "장르"), plan.before.genre, now.genre),
                              (String(ui: "작곡가"), plan.before.composer, now.composer), (String(ui: "코멘트"), plan.before.comment, now.comment),
                              (String(ui: "키"), plan.before.key, now.key)] where a != b {
            metadataChanged = true
            problems.append(String(ui: "\(label)이 바뀌었습니다(\(a) → \(b))"))
        }

        if problems.isEmpty { return Check(result: .matched, problems: []) }
        // 큐가 보내기 전 그대로이고 곡 정보도 그대로면 아직 가져오지 않은 것이다.
        let untouched = cuesUnchanged && !metadataChanged && (plan.cueChanged || !gridMatched)
        return Check(result: untouched ? .notYet : .mismatched, problems: problems)
    }

    static func same(_ a: Mark, _ b: Mark) -> Bool {
        a.num == b.num && a.type == b.type && abs(a.start - b.start) <= 0.002
            && abs((a.end ?? -1) - (b.end ?? -1)) <= 0.002 && a.name == b.name
    }

    static func describe(_ mark: Mark) -> String {
        let kind = mark.num < 0 ? String(ui: "메모리") : String(ui: "핫큐 \(String(UnicodeScalar(UInt8(65 + mark.num))))")
        let loop = mark.end.map { String(ui: "~\($0, specifier: "%.3f") 루프") } ?? ""
        return String(ui: "\(kind) \(mark.start, specifier: "%.3f")초\(loop)")
    }
}
