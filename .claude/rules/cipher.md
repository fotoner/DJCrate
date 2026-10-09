---
paths:
  - "Sources/RekordboxKit/Database/**"
  - "Sources/djc/Lab/CipherLab.swift"
  - "Tests/djcTests/CipherColdOpen*"
  - "Tests/Support/Fixtures/RekordboxFixture.swift"
---

# SQLCipher 열기를 고칠 때

rekordbox DB를 여는 코드와 그 시험을 고칠 때 지키는 규칙이다. 리뷰는 규칙을 ID로 가리킨다.

## 여는 길

- **CIP-1** DB는 `CipherDatabase`로만 연다. 그래야 `sqlite3_initialize`를 한 번 거친다.
- **CIP-2** 제품 코드와 `fixture.open()`은 늘 문자열 키로 연다.

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
- **CIP-9** 픽스처의 키 유도 줄이기는 [`docs/ci.md` "테스트 준비 비용"](../../docs/ci.md#테스트-준비-비용)에 있다. 템플릿 DB 복사와 솔트별 원시 키가 그 방법이다.

## 더 보기

- stress를 켜는 장치: [`docs/ci.md` "선택 실행 장치"](../../docs/ci.md#선택-실행-장치)
- 픽스처의 키 유도 비용: [`docs/ci.md` "테스트 준비 비용"](../../docs/ci.md#테스트-준비-비용)
