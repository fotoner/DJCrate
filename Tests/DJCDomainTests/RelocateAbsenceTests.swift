import DJCDomain
import Testing

/// 파일 없는 곡이 왜 없는지(#62): 외장 디스크가 연결되지 않아 없는 곡과, 디스크는 있는데 파일이 없는 곡을 나눈다.
/// 연결된 볼륨 목록은 넘겨받는다(여기는 입출력 없음).
@Suite("파일 없는 곡의 없는 이유")
struct RelocateAbsenceTests {
    @Test func 연결되지_않은_외장_디스크의_곡은_디스크_이름을_붙인다() {
        let absence = RelocateAbsence.of(path: "/Volumes/DJ SSD/Music/a.mp3", mountedVolumes: ["/", "/Volumes/USB A"])
        #expect(absence == .volumeNotMounted(name: "DJ SSD"))
        #expect(absence.unmountedVolumeName == "DJ SSD")
    }

    @Test func 연결된_디스크에서_없어진_곡은_파일_없음이다() {
        let absence = RelocateAbsence.of(path: "/Volumes/DJ SSD/Music/a.mp3", mountedVolumes: ["/", "/Volumes/DJ SSD"])
        #expect(absence == .fileMissing)
        #expect(absence.unmountedVolumeName == nil)
    }

    @Test func 시동_디스크의_곡은_볼륨_목록과_관계없이_파일_없음이다() {
        #expect(RelocateAbsence.of(path: "/Users/dj/Music/a.mp3", mountedVolumes: []) == .fileMissing)
        // 볼륨 이름까지만 있는 경로는 디스크 안의 곡이 아니다(`MissingFiles.volumeRoot`와 같은 기준)
        #expect(RelocateAbsence.of(path: "/Volumes/a.mp3", mountedVolumes: []) == .fileMissing)
    }

    @Test func 볼륨_목록의_끝_빗금과_유니코드_정규화_차이는_같은_디스크로_본다() {
        // NSWorkspace·FileManager는 "/Volumes/X/"처럼 끝 빗금을 붙여 줄 때가 있고, 이름이 NFD로 올 수 있다.
        let nfd = "/Volumes/\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}/"  // "한글" 자모 분해형
        #expect(RelocateAbsence.of(path: "/Volumes/한글/a.mp3", mountedVolumes: [nfd]) == .fileMissing)
        #expect(RelocateAbsence.of(path: "/Volumes/DJ SSD/a.mp3", mountedVolumes: ["/Volumes/DJ SSD/"]) == .fileMissing)
    }

    @Test func 이름이_앞부분만_같은_볼륨은_다른_디스크다() {
        #expect(RelocateAbsence.of(path: "/Volumes/DJ/a.mp3", mountedVolumes: ["/Volumes/DJ SSD"]) == .volumeNotMounted(name: "DJ"))
        #expect(RelocateAbsence.of(path: "/Volumes/DJ SSD/a.mp3", mountedVolumes: ["/Volumes/DJ"]) == .volumeNotMounted(name: "DJ SSD"))
    }

    @Test func 곡마다_한_번에_나눈다() {
        let targets = [
            RelocateTarget(id: "1", title: "a", artist: nil, oldPath: "/Volumes/Gone/a.mp3", lengthSeconds: nil, fileSize: nil),
            RelocateTarget(id: "2", title: "b", artist: nil, oldPath: "/Volumes/Here/b.mp3", lengthSeconds: nil, fileSize: nil),
            RelocateTarget(id: "3", title: "c", artist: nil, oldPath: "/Users/dj/c.mp3", lengthSeconds: nil, fileSize: nil),
        ]
        let absences = RelocateAbsence.classify(targets, mountedVolumes: ["/", "/Volumes/Here"])
        #expect(absences == ["1": .volumeNotMounted(name: "Gone"), "2": .fileMissing, "3": .fileMissing])
    }
}
