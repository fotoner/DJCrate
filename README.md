# DJCrate

[![빌드·테스트](https://github.com/fotoner/DJCrate/actions/workflows/check.yml/badge.svg?branch=dev)](https://github.com/fotoner/DJCrate/actions/workflows/check.yml) [![라이선스: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

DJCrate는 rekordbox 7 라이브러리를 고치는 macOS 앱이다. 고칠 때 rekordbox를 켤 필요가 없다. 공연용이 아니라 라이브러리 관리 도구다. 명령줄 도구 `djc`도 함께 있다. 화면은 한국어·영어·일본어로 볼 수 있다. English summary: [below](#english).

![DJCrate 덱과 곡 목록 화면(합성 시험 데이터)](docs/images/deck-library.png)

## 안전 원칙

- 편집은 모두 초안으로 쌓인다. "rekordbox에 쓰기"(⇧⌘E)를 누를 때만 rekordbox에 쓴다.
- rekordbox나 rekordboxAgent가 켜져 있으면 쓰지 않는다.
- 확인한 버전(7.2.x)과 DB 구조가 아니면 쓰지 않는다.
- 쓰기 전에 라이브러리 전체를 백업한다. 한 트랜잭션으로 쓴 뒤 다시 읽어 검증한다.
- "쓰기 전으로 복원…"으로 되돌릴 수 있다.
- rekordbox에서 직접 편집한 결과와 칸 단위로 같은지 확인한 쓰기만 한다. 나머지는 막는다. 막은 이유는 화면에 보여 준다.

## 설치와 실행

필요한 것은 아래와 같다.

- macOS 27 이상
- Swift 6.2 이상(Xcode)
- rekordbox 7.2.x(7.2.18에서 확인)

```bash
git clone https://github.com/fotoner/DJCrate.git && cd DJCrate
scripts/build-app.sh --install        # /Applications/DJCrate.app
swift build -c release --product djc  # .build/release/djc
```

1. 툴바 ⟳로 라이브러리 사본(스냅샷)을 뜬다. rekordbox가 켜져 있어도 된다.
2. 덱·목록에서 고친다. 고친 곡에는 쓰기 대기 표시가 붙는다.
3. rekordbox를 완전히 끈다.
4. "rekordbox에 쓰기"(⇧⌘E)를 누른다. DJCrate는 사본에 미리 써 본다. 막힌 것이 없으면 확인 없이 바로 쓴다.
5. 되돌리려면 결과 알림의 "쓰기 전으로 복원"을 누른다.

사본·초안·백업은 `~/Library/Application Support/DJCrate/`에 있다. 여기에는 클라우드 토큰이 들어 있으니 공유하지 않는다.

## 기능

| 영역 | 기능 |
|---|---|
| 라이브러리 | 재생 목록 트리, 필터(큐 없음·그리드 없음·파일 없음 등), 중복 곡 합치기, 곡 넣기·빼기, iTunes 동기화 목록 |
| 덱 | 3밴드 파형, CUE·핫큐·메모리 큐, 샘플 단위 루프, 퀀타이즈, 메트로놈, 오토게인, 큐·그리드·게인·키 제안 |
| 편집 | 큐, 그리드·BPM(변속 곡 포함), 태그, 평점·곡 색, 앨범아트. 분석 전 곡은 분석 파일을 만들어 붙인다 |
| 곡 편집·Flip(시험) | 마디 단위로 잘라 붙인 편집본, 핫큐 점프·루프 연주를 옮긴 편집본을 WAV로 만들어 넣는다 |
| 재생 목록 | 만들기·이름 바꾸기·옮기기·곡 넣고 빼기·순서 바꾸기 |
| XML | rekordbox로 가져오는 연동 XML, 라이브러리 전체 XML 내보내기(읽기만) |
| USB(시험) | OneLibrary·Device Library 읽기·내보내기·편집. 실물 USB는 볼륨 이름·용량을 보인 내보내기 시트나 쓰기 확인 창에서 쓰기를 누를 때만 쓴다(쓰기 전 백업·쓴 뒤 검증) |
| 실험실 | 인텔리전트 재생 목록 보기(읽기만) 등. 설정 › 실험실에서 켠다 |
| CLI·에이전트 | `djc`로 라이브러리를 찾아보고 큐·태그 초안을 만든다. Claude Code·Codex용 [스킬](skills/djcrate/SKILL.md) |

## 문서

| 문서 | 내용 |
|---|---|
| [docs/features.md](docs/features.md) | 기능 자세히, 한계, XML 경로, 단축키 |
| [docs/cli.md](docs/cli.md) | `djc` 명령과 JSON |
| [docs/rekordbox-internals.md](docs/rekordbox-internals.md) | 실험으로 확인한 rekordbox 쓰기 규칙 |
| [docs/usb-internals.md](docs/usb-internals.md) | USB 형식과 쓰기 규칙 |
| [docs/architecture.md](docs/architecture.md) | 구조와 설계 결정 |
| [CONTRIBUTING.md](CONTRIBUTING.md) · [AGENTS.md](AGENTS.md) · [docs/issues.md](docs/issues.md) | 빌드·검증, 작업 규칙, [GitHub 이슈](https://github.com/fotoner/DJCrate/issues) 규칙 |

## English

DJCrate is a macOS app for editing a rekordbox 7 library (cues, beat grids, Auto Gain, tags, playlists, adding and removing tracks) without launching rekordbox. Every edit stays a draft until you choose Write to rekordbox (⇧⌘E). It never writes while rekordbox or rekordboxAgent is running, only writes to rekordbox 7.2.x with a verified database layout, backs up the whole library first and verifies the result. USB support is experimental; physical USBs are written only after you confirm the write dialog. Requires macOS 27+, Swift 6.2+ (Xcode); install with `scripts/build-app.sh --install`. The app UI is available in English, Japanese and Korean (others fall back to English); docs, the `djc` CLI and issues are in Korean.

## 라이선스

- 라이선스는 [MIT](LICENSE)다. 제3자 고지는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)에 있다.
- rekordbox는 AlphaTheta의 상표다. 이 앱은 AlphaTheta와 관계없는 독립 프로젝트다.
- rekordbox DB 키는 [pyrekordbox](https://github.com/dylanljones/pyrekordbox)(MIT)와 같은 방식으로 푼다.
