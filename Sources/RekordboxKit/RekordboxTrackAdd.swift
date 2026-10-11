import DJCDomain
import Foundation

/// 곡 추가 계획 만들기(값은 DJCDomain `TrackAddPlan`, #167): 형식 번호·날짜 글자·파일과 태그에서 계획 만들기.
extension TrackAddPlan {
    /// rekordbox 파일 형식 번호(라이브러리 7천 곡에서 확인). 다른 형식은 아직 넣지 않는다.
    public static let fileTypes: [String: Int] = ["mp3": 1, "mp4": 3, "m4a": 4, "flac": 5, "wav": 11]

    public static func dateText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 파일과 태그로 계획을 만든다. 형식을 모르거나 파일을 읽지 못하면 이유와 함께 던진다.
    public static func make(url: URL, tags: AudioTags, now: Date = .now) throws -> TrackAddPlan {
        let path = url.path.precomposedStringWithCanonicalMapping
        let fileName = url.lastPathComponent.precomposedStringWithCanonicalMapping
        guard var fileType = fileTypes[url.pathExtension.lowercased()] else {
            throw DJCError.writeRefused(String(ui: "\(fileName): 이 형식은 아직 rekordbox에 직접 넣지 않습니다"))
        }
        // 2026-09-27 ALAC 실험: 같은 M4A 컨테이너라도 ALAC은 6, AAC는 기존 번호다.
        if [3, 4].contains(fileType), RekordboxTimeline.packetInfo(url: url)?.formatID == "alac" { fileType = 6 }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? Int, let inode = attributes[.systemFileNumber] as? Int else {
            throw DJCError.writeRefused(String(ui: "\(fileName): 파일 정보를 읽지 못했습니다"))
        }
        let created = attributes[.creationDate] as? Date ?? now
        return TrackAddPlan(
            path: path, fileName: fileName,
            title: tags.title ?? url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping,
            artist: tags.artist, album: tags.album, albumArtist: tags.albumArtist, genre: tags.genre, composer: tags.composer,
            comment: tags.comment ?? "", year: tags.year ?? 0, trackNumber: tags.trackNumber ?? 0, discNumber: tags.discNumber ?? 0,
            isrc: tags.isrc ?? "", lyricist: tags.lyricist ?? "", fileType: fileType, fileSize: size, fileID: String(inode),
            length: Int(tags.duration.rounded()), duration: tags.duration, dateCreated: dateText(created), stockDate: dateText(now),
            artwork: tags.artwork)
    }
}
