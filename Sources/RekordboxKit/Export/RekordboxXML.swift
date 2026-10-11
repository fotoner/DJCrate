import DJCDomain
import Foundation

/// rekordbox XML(환경설정 › 고급 › rekordbox xml로 불러와 "Import To Collection"하는 형식).
///
/// 새로 추가한 곡을 직접 쓰기 대신 XML로 넘길 때 쓴다. 이 경로에서는 DB를 고치지 않고,
/// 가져오기는 rekordbox에서 사용자가 한다. 시각은 모두 rekordbox 시간축(초)이어야 한다.
public enum RekordboxXML {
    public struct Entry: Sendable {
        public var track: StagedTrack
        /// 템포 구간(rekordbox 시간축). 비어 있으면 TEMPO를 쓰지 않는다(rekordbox가 분석한다).
        public var tempos: [GridSegment]
        /// 메모리·핫큐(rekordbox 시간축)
        public var cues: [EditableCue]

        public init(track: StagedTrack, tempos: [GridSegment], cues: [EditableCue]) {
            self.track = track
            self.tempos = tempos
            self.cues = cues
        }
    }

    public static func document(entries: [Entry], playlistName: String, productVersion: String = "0.1") -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<DJ_PLAYLISTS Version="1.0.0">"#,
            #"  <PRODUCT Name="DJCrate" Version="\#(escape(productVersion))" Company=""/>"#,
            #"  <COLLECTION Entries="\#(entries.count)">"#,
        ]
        for (index, entry) in entries.enumerated() {
            lines.append(contentsOf: trackLines(entry, trackID: index + 1))
        }
        lines.append("  </COLLECTION>")
        lines.append("  <PLAYLISTS>")
        lines.append(#"    <NODE Type="0" Name="ROOT" Count="1">"#)
        lines.append(#"      <NODE Name="\#(escape(playlistName))" Type="1" KeyType="0" Entries="\#(entries.count)">"#)
        for index in entries.indices { lines.append(#"        <TRACK Key="\#(index + 1)"/>"#) }
        lines.append("      </NODE>")
        lines.append("    </NODE>")
        lines.append("  </PLAYLISTS>")
        lines.append("</DJ_PLAYLISTS>")
        return lines.joined(separator: "\n") + "\n"
    }

    static func trackLines(_ entry: Entry, trackID: Int) -> [String] {
        let track = entry.track
        let tempos = normalized(entry.tempos)
        var attributes: [(String, String)] = [
            ("TrackID", "\(trackID)"),
            ("Name", track.title),
            ("Artist", track.artist ?? ""),
            ("Composer", track.composer ?? ""),
            ("Album", track.album ?? ""),
            ("Genre", track.genre ?? ""),
            ("Kind", kind(forExtension: (track.path as NSString).pathExtension)),
        ]
        if let size = (try? FileManager.default.attributesOfItem(atPath: track.path))?[.size] as? NSNumber {
            attributes.append(("Size", size.stringValue))
        }
        attributes += [
            ("TotalTime", "\(Int(track.duration.rounded()))"),
            ("TrackNumber", "\(track.trackNumber ?? 0)"),
            ("Year", "\(track.year ?? 0)"),
        ]
        if let bpm = tempos.first?.bpm { attributes.append(("AverageBpm", String(format: "%.2f", bpm))) }
        attributes += [
            ("DateAdded", track.addedOn),
            ("Comments", track.comment),
            ("Location", location(forPath: track.path)),
        ]
        let open = "    <TRACK " + attributes.map { "\($0.0)=\"\(escape($0.1))\"" }.joined(separator: " ")
        var children: [String] = tempos.map { segment in
            #"      <TEMPO Inizio="\#(String(format: "%.3f", segment.start))" Bpm="\#(String(format: "%.2f", segment.bpm))" Metro="4/4" Battito="\#(segment.firstBeatNumber)"/>"#
        }
        for cue in entry.cues.sorted(by: { $0.time < $1.time }) where cue.time >= 0 {
            let number: Int
            switch cue.kind {
            case .memory: number = -1
            case let .hot(slot): number = slot
            }
            children.append(#"      <POSITION_MARK Name="\#(escape(cue.name))" Type="0" Start="\#(String(format: "%.3f", cue.time))" Num="\#(number)"/>"#)
        }
        return children.isEmpty ? [open + "/>"] : [open + ">"] + children + ["    </TRACK>"]
    }

    /// 첫 구간은 곡 시작 쪽 첫 박(0초 이상)부터 쓰고, 박 번호도 그만큼 되돌린다. BPM은 소수 둘째 자리.
    public static func normalized(_ segments: [GridSegment]) -> [GridSegment] { GridSegment.rekordboxNormalized(segments) }

    /// `file://localhost` + 퍼센트 인코딩 경로(rekordbox가 내보내는 모양과 같다).
    public static func location(forPath path: String) -> String {
        "file://localhost" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
    }

    public static func kind(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": "MP3 File"
        case "m4a", "mp4", "aac", "alac": "M4A File"
        case "wav": "WAV File"
        case "aif", "aiff": "AIFF File"
        case "flac": "FLAC File"
        default: "\(ext.uppercased()) File"
        }
    }

    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\n": out += "&#10;"
            case "\r": out += "&#13;"
            case "\t": out += "&#9;"
            default:
                // XML 1.0에서 허용하지 않는 제어 문자는 버린다.
                if scalar.value < 0x20 { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
