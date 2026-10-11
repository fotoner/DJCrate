---
paths:
  - "Sources/RekordboxKit/Database/**"
  - "Sources/djc/Lab/CipherLab.swift"
  - "Tests/djcTests/CipherColdOpen*"
  - "Tests/Support/Fixtures/RekordboxFixture.swift"
  - "Tests/Support/Fixtures/CipherKDF.swift"
  - "Tests/Support/CipherKDF/**"
---

# SQLCipher 열기를 고칠 때

rekordbox DB를 여는 코드와 그 시험을 고칠 때 지키는 규칙이다. 리뷰는 규칙을 ID로 가리킨다.

## 여는 길

- **CIP-1** DB는 `CipherDatabase`로만 연다. 그래야 `sqlite3_initialize`를 한 번 거친다.
- **CIP-2** 제품 코드와 `fixture.open()`은 늘 문자열 키로 연다. 제품 코드는 SQLCipher 암호 설정(`cipher_*`·`kdf_iter` 등)을 바꾸지 않는다.

이유: SQLCipher 4.7부터 처음 쓰는 순간에 초기화 경쟁이 있다.
여러 스레드가 겹치면 전역 초기화가 끝나기 전에 들어온 스레드가 실패한다.
그 스레드는 `PRAGMA key`에서 "sqlcipher not initialized"를 받는다.

## 시험

- **CIP-3** 새 프로세스에서 처음 여는 경쟁은 `djc lab cipher-cold-open`이 만든다. `Tests/djcTests/CipherColdOpenTests.swift`가 그 결과를 본다.
- **CIP-4** `CipherDatabase` 초기화·`CipherLab`·cold-open 경쟁을 바꾸면 `scripts/check.sh --stress`도 반드시 통과시킨다.
- **CIP-5** 수동 CI(`run_stress=true`)에서도 stress를 돌린다.
- **CIP-6** stress는 cold-open 경쟁 시험 1개를 돌린다. 같은 파일의 설정 계약 시험 3개도 함께 돈다.
- **CIP-7** 일반 회귀는 새 프로세스 4개, stress는 100개를 띄운다. 둘 다 32스레드와 동시 프로세스 4개 상한을 지킨다.
- **CIP-8** `DJC_CIPHER_STRESS` 값이 없음·`0`이면 일반, `1`이면 stress다. 그 밖의 값은 실패한다.
- **CIP-9** 픽스처의 키 유도 줄이기는 [`docs/ci.md` "테스트 준비 비용"](../../docs/ci.md#테스트-준비-비용)에 있다. 템플릿 DB 복사, 솔트별 원시 키, 시험 전용 반복 수가 그 방법이다.

## 시험 전용 키 유도 반복 수

- **CIP-10** 시험 전용 장치 `CipherTestKDF`(`Tests/Support/CipherKDF/`)는 시험 묶음이 올라올 때 SQLCipher 기본 키 유도 반복 수를 1로 낮춘다. 장치는 DB를 여는 시험 타깃 넷만 링크한다. 그 목록은 `Package.swift`에 있다. 제품 타깃(`Sources/**`)·앱·djc는 이 장치를 링크하지 않는다.
- **CIP-11** djc를 띄우는 시험은 djcTests에 둔다. djcTests는 장치를 링크하지 않는다. 장치가 있는 묶음이 만든 DB는 djc가 열지 못하기 때문이다. djcTests와 djc는 SQLCipher 4 기본값(256,000번)을 쓴다.
- **CIP-12** 두 가지 시험이 이 장치를 지킨다. `CipherTestKDFTests`·`CipherTestKDFLinkTests`는 장치가 켜졌는지 본다. 장치가 빠져도 다른 시험은 그대로 통과하기 때문이다. djcTests의 `CipherDefaultKDFTests`는 djc가 만든 OneLibrary가 256,000번으로 유도한 키로 열리는지 본다.
- **CIP-13** 환경에 시험 기본 변수 밖의 `DJC_` 변수가 있으면 장치는 기본값(256,000번)을 그대로 둔다. 실험 재현 시험은 rekordbox가 만든 사본을 읽는다. 캡처 시험은 앱·djc에 넘길 사본을 만든다. 두 시험은 각자의 `DJC_` 변수로 켜지므로 기본값으로 돈다.
- **CIP-14** 시험 기본 변수 목록은 `CipherTestKDF.m`에 있다. `DJC_HOME`·`DJC_REKORDBOX_DIR`·`DJC_LANG` 등이 그 목록에 든다. 새 기본 변수를 `scripts/check.sh`나 CI에 더하면 이 목록에도 더한다.
- **CIP-15** `scripts/check.sh`의 일상 검사(`--changed`·전체·`--coverage`)는 시험에 표지 `DJC_CHECK_TEST_KDF=1`을 준다. 장치가 꺼진 채 표지를 받으면 `CipherTestKDFTests`가 실패한다. 목록이 늦어 장치가 조용히 꺼지는 것을 잡는다. 실험·캡처는 `--quick`이나 `swift test`로 돌아 표지를 받지 않는다.

## 더 보기

- stress를 켜는 장치: [`docs/ci.md` "선택 실행 장치"](../../docs/ci.md#선택-실행-장치)
- 픽스처의 키 유도 비용: [`docs/ci.md` "테스트 준비 비용"](../../docs/ci.md#테스트-준비-비용)
