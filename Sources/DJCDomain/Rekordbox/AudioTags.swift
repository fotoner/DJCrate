import Foundation

/// 음원 파일 태그(ID3·iTunes·Vorbis). rekordbox가 곡을 컬렉션에 넣을 때 읽는 칸만 모은다.
public struct AudioTags: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var composer: String?
    public var comment: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var isrc: String?
    public var lyricist: String?
    /// AVFoundation이 잰 길이(초). 인코더 지연은 빠진 값.
    public var duration: Double
    /// 내장 아트워크(ID3 APIC·iTunes covr·FLAC PICTURE) 원본 바이트. 여럿이면 첫 그림.
    public var artwork: Data?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil, genre: String? = nil,
                composer: String? = nil, comment: String? = nil, year: Int? = nil, trackNumber: Int? = nil, discNumber: Int? = nil,
                isrc: String? = nil, lyricist: String? = nil, duration: Double = 0, artwork: Data? = nil) {
        self.title = title; self.artist = artist; self.album = album; self.albumArtist = albumArtist; self.genre = genre
        self.composer = composer; self.comment = comment; self.year = year; self.trackNumber = trackNumber
        self.discNumber = discNumber; self.isrc = isrc; self.lyricist = lyricist; self.duration = duration
        self.artwork = artwork
    }
}
