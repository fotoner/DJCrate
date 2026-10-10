import CipherTestKDF
import Foundation
import RekordboxFixtures
import RekordboxKit
import Testing

/// 시험 전용 장치(`CipherTestKDF`)가 이 시험 프로세스의 SQLCipher 기본 키 유도 반복 수를 낮췄는지 본다.
/// 장치가 조용히 빠지면 시험은 그대로 통과하고 시간만 다시 늘어나므로 따로 확인한다.
@Suite("시험 전용 키 유도 반복 수")
struct CipherTestKDFTests {
    /// 이 프로세스에서 기대하는 기본 반복 수. 실험·캡처 변수가 있으면 장치가 기본값을 그대로 둔다.
    static var expectedIterations: Int {
        djc_test_kdf_process_keeps_default() == 1 ? CipherKDF.productIterations : Int(DJC_TEST_KDF_ITER)
    }

    static func keepsDefault(_ entries: [String]) -> Bool {
        var pointers = entries.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return djc_test_kdf_keeps_default(&pointers) == 1
    }

    @Test func 시험_프로세스의_기본_반복_수는_장치가_넣은_값이다() throws {
        #expect(Int(djc_test_kdf_iterations()) == Int(DJC_TEST_KDF_ITER))
        #expect(Int(DJC_TEST_KDF_ITER) < CipherKDF.productIterations)
        #expect(try CipherKDF.processDefaultIterations() == Self.expectedIterations)
        #expect(djc_test_kdf_lowered() == (Self.expectedIterations == Int(DJC_TEST_KDF_ITER) ? 1 : 0))
    }

    @Test func 시험_기본_환경에서만_낮추고_실험·캡처_변수가_있으면_기본값을_둔다() {
        #expect(!Self.keepsDefault([]))
        #expect(!Self.keepsDefault(["PATH=/usr/bin", "DJC_HOME=/t/home", "DJC_REKORDBOX_DIR=/t/rb", "DJC_LANG=ko",
                                    "DJC_TEST_DEFAULTS_PREFIX=djc-test-", "DJC_CIPHER_STRESS=1", "DJC_CHECK_VERBOSE=1",
                                    "DJC_SIGN_IDENTITY=-"]))
        // rekordbox가 만든 사본을 읽는 실험 재현, 앱·djc에 넘길 사본을 만드는 캡처
        for name in ["DJC_GRID_EXPERIMENT", "DJC_HISTORY_SELFTEST_FIXTURE", "DJC_USB_PARSER_FIXTURE", "DJC_LAYOUT_BENCHMARK_DB"] {
            #expect(Self.keepsDefault(["DJC_HOME=/t/home", "\(name)=/t/copy"]), "\(name)")
        }
        // 이름 전체가 맞아야 시험 기본 변수다
        #expect(Self.keepsDefault(["DJC_HOMEX=/t"]))
        #expect(Self.keepsDefault(["DJC_HOM=/t"]))
    }

    @Test func 제품이_만든_DB와_픽스처_DB는_프로세스_기본_반복_수를_쓴다() throws {
        let iterations = Self.expectedIterations, other = iterations == CipherKDF.productIterations ? Int(DJC_TEST_KDF_ITER) : CipherKDF.productIterations
        let oneLibrary = try OneLibraryFixture()
        oneLibrary.close()
        let passphrase = try RekordboxKey.oneLibrary()
        #expect(try CipherKDF.opens(path: oneLibrary.url.path, passphrase: passphrase, iterations: iterations))
        #expect(try !CipherKDF.opens(path: oneLibrary.url.path, passphrase: passphrase, iterations: other))

        let fixture = try RekordboxFixture()
        #expect(try CipherKDF.opens(path: fixture.database.path, passphrase: RekordboxKey.derive(), iterations: iterations))
        _ = try fixture.localUpdateCount()
        #expect(fixture.passphraseFallbacks == 0)
    }
}
