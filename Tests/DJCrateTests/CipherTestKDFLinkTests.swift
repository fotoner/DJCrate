import CipherTestKDF
import Foundation
import RekordboxFixtures
import Testing

/// 이 시험 묶음에도 시험 전용 장치(`CipherTestKDF`)가 링크돼 SQLCipher 기본 키 유도 반복 수가 낮춰졌는지 본다.
/// 장치가 빠지면 시험은 그대로 통과하고 시간만 다시 늘어난다(규칙은 RekordboxKitTests의 `CipherTestKDFTests`).
@Suite("시험 전용 키 유도 반복 수 링크")
struct CipherTestKDFLinkTests {
    @Test func 시험_프로세스의_기본_반복_수는_장치가_넣은_값이다() throws {
        // 실험·캡처 변수가 있으면 장치가 기본값을 그대로 둔다(rekordbox 사본·앱에 넘길 사본과 맞춘다)
        let keeps = djc_test_kdf_process_keeps_default() == 1
        #expect(djc_test_kdf_lowered() == (keeps ? 0 : 1))
        #expect(try CipherKDF.processDefaultIterations() == (keeps ? CipherKDF.productIterations : Int(DJC_TEST_KDF_ITER)))
    }
}
