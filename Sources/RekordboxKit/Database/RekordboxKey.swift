import DJCDomain
import Foundation

/// rekordbox 6/7 `master.db`와 USB OneLibrary(`exportLibrary.db`)의 SQLCipher 키.
///
/// pyrekordbox(MIT)와 같은 방식으로 난독화된 상수를 푼다:
/// base85(RFC 1924) 디코드 → 고정 키 XOR → zlib 해제.
/// 키는 이 파일 한 곳에만 둔다. 고지: THIRD_PARTY_NOTICES.md
public enum RekordboxKey {
    static let blob = "PN_Pq^*N>(JYe*u^8;Yg76HuZ<mR13S?=>)b9;DpoTXV(6ItkU`}8*m6tx_I{Solh_N#dfe{v="
    /// pyrekordbox `devicelib_plus/database.py`의 `BLOB` 상수
    static let oneLibraryBlob = "PN_1dH8$oLJY)16j_RvM6qphWw`476>;C1cWmI#se(PG`j}~xAjlufj?`#0i{;=glh(SkW)y0>n?YEiD`l%t("
    static let xorKey = Array("657f48f84c437cc1".utf8)

    /// 로컬 `master.db` 키(16진수)
    public static func derive() throws -> String {
        try derive(blob: blob) { $0.hasPrefix("402fd") && $0.allSatisfy(\.isHexDigit) }
    }

    /// OneLibrary(exportLibrary.db) 문자열 키. pyrekordbox(MIT) devicelib_plus BLOB을 같은 방법으로 푼다.
    /// 64자 영숫자이고 16진수만으로 되어 있지 않아야 한다(`PRAGMA key`에 문자열 그대로 넣는 키).
    public static func oneLibrary() throws -> String {
        try derive(blob: oneLibraryBlob) { key in
            key.count == 64 && key.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
                && !key.allSatisfy(\.isHexDigit)
        }
    }

    /// base85 → XOR(xorKey) → zlib. 결과가 `validate`를 통과하지 않으면 던진다.
    static func derive(blob: String, validate: (String) -> Bool) throws -> String {
        let decoded = try Base85.decode(blob)
        let xored = Data(decoded.enumerated().map { $0.element ^ xorKey[$0.offset % xorKey.count] })
        let inflated = try Zlib.inflate(xored)
        guard let key = String(data: inflated, encoding: .utf8), validate(key) else { throw DJCError.keyDerivationFailed }
        return key
    }
}

/// Python `base64.b85decode`와 같은 RFC 1924 알파벳 디코더.
enum Base85 {
    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~".utf8)
    static let table: [UInt8: UInt32] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, UInt32($0.offset)) })

    static func decode(_ text: String) throws -> [UInt8] {
        var chars = Array(text.utf8)
        let padding = (5 - chars.count % 5) % 5
        chars += Array(repeating: UInt8(ascii: "~"), count: padding)
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 5 * 4)
        for chunk in stride(from: 0, to: chars.count, by: 5) {
            var acc: UInt64 = 0
            for c in chars[chunk..<chunk + 5] {
                guard let v = table[c] else { throw DJCError.keyDerivationFailed }
                acc = acc * 85 + UInt64(v)
            }
            guard acc <= UInt64(UInt32.max) else { throw DJCError.keyDerivationFailed }
            out += [UInt8(acc >> 24 & 0xff), UInt8(acc >> 16 & 0xff), UInt8(acc >> 8 & 0xff), UInt8(acc & 0xff)]
        }
        return Array(out.dropLast(padding))
    }
}

/// zlib 스트림(헤더 2바이트 + raw DEFLATE + adler32) 해제.
/// Foundation의 `.zlib`은 raw DEFLATE만 다루므로 헤더와 트레일러를 떼고 넘긴다.
enum Zlib {
    static func inflate(_ data: Data) throws -> Data {
        guard data.count > 6 else { throw DJCError.keyDerivationFailed }
        let deflate = data.subdata(in: 2..<(data.count - 4))
        do {
            return try (deflate as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw DJCError.keyDerivationFailed
        }
    }
}
