import DJCDomain
import Foundation

/// Device Library를 고쳐 쓰기 전의 왕복 검사: 읽기 → 모델 → 쓰기 → 다시 읽기.
/// 작성기가 이 파일의 모든 알려진 칸을 다시 만들 수 있을 때만 통과한다.
public enum PdbRoundTrip {
    /// 읽기(`PdbReader`) → 모델 → 쓰기 → 다시 읽기. 알려진 표의 칸이 같고 상수 칸(bitmask 0x000C0700, u5 0x29, u7 3, 빈 문자열 칸 5·8·9·13·18)이
    /// 관찰값과 같고 참·거짓 문자열 칸 6·7이 "ON"·''여야 통과. 칸 비교는 `UsbLibraryDiff.Options(formats: [.deviceLibrary])`로 한다.
    /// 문제는 영어 고정 표기(표·id·칸 이름·수)만 넣고 글자 값은 넣지 않는다. 빈 배열 = 통과.
    /// - 원본의 구조 문제(먼 모양 My Tag 행 포함), 작성기가 막는 행(기록·모르는 표·My Tag 연결 등)도 문제로 남긴다.
    /// - 아티스트·앨범 먼 오프셋 행은 작성기가 쓰므로, 표마다 먼 모양 행 수가 다시 쓴 파일과 다를 때만 문제로 남긴다
    ///   (실험이 보지 못한 앨범 이름 끝 247에서 rekordbox와 다른 모양을 고른 경우).
    /// - 지운 행 id(`deadIDs`)는 다시 쓰면 사라지는 것이 정상이라 비교하지 않는다(ID를 다시 쓰지 않게 지키는 것은 편집 쪽 몫).
    /// - 작성기는 사람이 읽는 문자열을 NFC로 쓴다(#233). 글자 칸은 정규형으로 비교하고(Swift 문자열 비교), NFC로 바뀌어 달라지는
    ///   문자열 모양·먼 모양 행 수는 기대값을 NFC 철자 쪽으로 옮겨 비교한다(`expectingNFC`).
    /// - 파일 머리를 읽을 수 없으면 던진다.
    public static func check(export: Data, exportExt: Data?) throws -> [String] {
        let (read, report) = try PdbReader.read(export: export, exportExt: exportExt)
        var problems = report.issues.map { "structure \($0)" }
        let (model, farShapeRows) = expectingNFC(read, farShapeRows: report.farShapeRows)
        problems += constantProblems(model)
        let files: PdbFiles
        do {
            files = try PdbWriter.files(read, mode: .edit(previousExportSequence: report.exportHeader.sequence,
                                                         previousExtSequence: report.extHeader?.sequence ?? 0))
        } catch let UsbError.writeRefused(blocks) {
            return problems + blocks.map { "refused \($0.code)" }
        }
        let (reread, rereadReport) = try PdbReader.read(export: files.export, exportExt: files.exportExt)
        problems += rereadReport.issues.map { "reread structure \($0)" }
        for table in Set(farShapeRows.keys).union(rereadReport.farShapeRows.keys).sorted() {
            let before = farShapeRows[table] ?? 0, after = rereadReport.farShapeRows[table] ?? 0
            if before != after { problems.append("far_shape_rows \(table) \(before) -> \(after)") }
        }
        let differences = UsbLibraryDiff.compare(model, reread, options: .init(skipTables: ["deadIDs"], formats: [.deviceLibrary])).differences
        return problems + differences.map { "\($0.table) \($0.key) \($0.field)" }
    }

    /// 작성기가 NFC로 바꿔 쓰는 문자열(#233) 때문에 달라지는 기대값을 NFC 철자 쪽으로 옮긴다.
    /// - 트랙 문자열 모양: 원본 모양이 원래 철자로 작성기가 고를 모양과 같을 때만 NFC 철자의 모양으로 바꾼다
    ///   (드물게 NFC가 ASCII로 바꾸는 글자, 예: U+212A KELVIN SIGN → K). 원래도 다른 모양이면 그대로 둬 문제로 남긴다.
    /// - 아티스트·앨범 먼 모양 행 수: 원래 철자와 NFC 철자로 고른 모양이 다른 행만큼 옮긴다(풀어 쓴 한글은 NFC가 짧다).
    /// 글자 칸 자체는 정규형으로 비교해(Swift 문자열 비교) 옮길 것이 없다
    static func expectingNFC(_ model: UsbLibrary, farShapeRows: [String: Int]) -> (UsbLibrary, [String: Int]) {
        var model = model, farShapeRows = farShapeRows
        for track in model.tracks {
            guard var extras = model.trackRowExtras[track.id] else { continue }
            let values = PdbRowEncoder.trackStringValues(track)
            for index in PdbRowEncoder.trackTextStrings.sorted()
            where index < extras.stringKinds.count && UsbNameSpelling.changesUnderNFC(values[index])
                && extras.stringKinds[index] == PdbStringEncoder.encoded(values[index], longASCIIObserved: true).kind {
                extras.stringKinds[index] = PdbStringEncoder.encodedText(values[index], longASCIIObserved: true).kind
            }
            model.trackRowExtras[track.id] = extras
        }
        func shift(_ table: String, _ names: [String], header: Int) {
            var delta = 0
            for name in names where UsbNameSpelling.changesUnderNFC(name) {
                let raw = PdbStringEncoder.encoded(name, longASCIIObserved: true)
                let nfc = PdbStringEncoder.encodedText(name, longASCIIObserved: true)
                let before = PdbRowSize.isFarShape(nameEnd: PdbRowSize.nameEnd(raw, header: header))
                let after = PdbRowSize.isFarShape(nameEnd: PdbRowSize.nameEnd(nfc, header: header))
                delta += (after ? 1 : 0) - (before ? 1 : 0)
            }
            if delta != 0 { farShapeRows[table] = (farShapeRows[table] ?? 0) + delta }
        }
        shift("artists", model.artists.map(\.name), header: PdbRowEncoder.artistHeader)
        shift("albums", model.albums.map(\.name), header: PdbRowEncoder.albumHeader)
        return (model, farShapeRows)
    }

    /// 트랙 행 상수 칸이 작성기가 쓰는 관찰값과 다른 곡.
    /// 문자열 6·7은 모델이 참·거짓만 들고 있어 "ON"·''가 아닌 값은 모델이 같아도 다시 쓰면 바뀐다
    /// rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기)
    static func constantProblems(_ model: UsbLibrary) -> [String] {
        let observed = PdbWriter.observedExtras([])
        var problems: [String] = []
        for (id, extras) in model.trackRowExtras.sorted(by: { $0.key < $1.key }) {
            if extras.subtype != observed.subtype { problems.append(String(format: "content %d subtype 0x%04X", id, extras.subtype)) }
            if extras.bitmask != observed.bitmask { problems.append(String(format: "content %d bitmask 0x%08X", id, extras.bitmask)) }
            if extras.u5 != observed.u5 { problems.append(String(format: "content %d u5 0x%04X", id, extras.u5)) }
            if extras.u7 != observed.u7 { problems.append("content \(id) u7 \(extras.u7)") }
            for (index, value) in extras.unknownStrings.sorted(by: { $0.key < $1.key }) where !value.isEmpty {
                problems.append("content \(id) unknownString\(index) not empty")
            }
            for (index, value) in extras.flagStrings.sorted(by: { $0.key < $1.key })
            where value != PdbRowEncoder.flagString(true) && value != PdbRowEncoder.flagString(false) {
                problems.append("content \(id) string\(index) not ON or empty")
            }
        }
        return problems
    }
}
