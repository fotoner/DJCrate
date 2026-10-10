---
paths:
  - "Sources/DJCrate/**/*View*.swift"
  - "Sources/DJCrate/**/*Model*.swift"
  - "Sources/DJCrate/**/*Window*.swift"
  - "Sources/DJCrate/**/*Sheet*.swift"
---

# 화면 모델·뷰를 고칠 때

규칙의 예와 이유는 `docs/mvvm.md`에 있다. 리뷰는 아래 ID로 가리킨다.

- `MVVM-1`: 화면(창·시트·주요 패널)마다 화면 모델 하나를 둔다. 이름은 `…Model`이다.
- `MVVM-2`: 화면 모델은 유스케이스를 부른다. 결과를 화면 상태로 바꾼다. 규칙은 DJCDomain에 둔다.
  - 유스케이스에는 화면 상태(`@Observable`)를 두지 않는다. 관찰은 화면 모델이 한다(본보기 `UsbSync` → `UsbSyncModel`).
- `MVVM-3`: 잎 뷰에는 값과 클로저만 넘긴다. 화면 모델 전체를 넘기지 않는다.
- `MVVM-4`: 뷰 본문에서 유스케이스나 `Task`를 시작하지 않는다. 화면 모델의 메서드를 부른다.
  - 검사는 `scripts/check-imports.py`의 `view-task`다. 뷰 파일의 `Task` 시작과 `await`를 센다.
  - 허용 꼴은 `.task { await model.method(args) }` 한 줄뿐이다. 받는 쪽은 `self`가 아니다. 인자에 클로저와 `await`가 없다.
  - 옛 위반은 2026-10-10에 모두 갚았다. 새 위반은 그 자리에서 고친다.
- `MVVM-5`: 화면 모델은 `Tests/DJCrateTests`에서 가짜 포트로 시험한다. 잎 뷰는 값만 넣어 시험한다.
- `MVVM-6`: 예외는 덱 재생 경로와 공유 핵심 `LibraryStore`뿐이다. 덱 재생 경로에서는 `DeckModel`이 엔진 포트를 직접 부른다.
  - 핵심은 화면 여럿이 함께 보는 상태만 든다. 기능 하나는 기능 조각(`…Store`), 화면 하나는 화면 모델(`…Model`)이 든다.
- 지금 코드에 남은 빚은 `docs/mvvm.md` "남은 빚"에 있다. 손대는 화면부터 갚는다.
