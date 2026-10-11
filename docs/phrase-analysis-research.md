# 프레이즈·보컬·AI 특징 분석 조사

이슈: [#12](https://github.com/fotoner/DJCrate/issues/12) · 조사일: 2026-09-27

## 결론

- **[확인]** PSSI의 칸을 읽어 DJCrate 섹션 경계와 비교할 수 있다. 익명 표본 16개에서 같은 마디 경계의 F1은 **25.4%**, ±1마디 허용 F1은 **54.3%**였다.
  - 아래 수치는 rekordbox와의 일치도다. 음악적으로 옳은 경계를 판정한 정확도가 아니다.
- **[추정]** 현재 `PartAnalysis.sections`를 PSSI로 바로 내보내는 것은 보류하는 편이 낫다. 경계 차이 외에 다음 값을 정하는 규칙도 필요하다.
  - mood
  - kind
  - 변형
  - fill
  - Lighting bank

  파일을 포장할 수 있다는 사실과 rekordbox 수준의 분석을 만든다는 사실은 다르다.
- **[확인]** PVDI의 외곽 구조와 `.3EX`의 MessagePack 구조를 사본에서 관찰했다. **[추정]** 보컬 구간·추천 특징값 생성기를 대체할 근거는 부족하다. 그래서 두 형식의 쓰기도 보류한다.
- **[확인]** rekordbox의 자동 큐 분석은 프레이즈 정보를 필요로 한다. Collection/Streaming Radar는 추천 분석 데이터를 필요로 한다. **[추정]** DJCrate가 당장 필요한 범위는 자체 섹션 분석을 큐 후보로 쓰는 것이다. rekordbox 전용 기능의 누락 분석은 rekordbox에서 보충하는 흐름이다. [자동 큐 FAQ](https://rekordbox.com/en/support/faq/rekordbox7/#faq-70961), [Radar FAQ](https://rekordbox.com/en/support/faq/rekordbox7/#faq-70944)

이번 변경은 `djc lab phrase-eval`과 테스트다. 분석 파일·DB 쓰기 경로는 추가하지 않았다.

## 근거와 조사 범위

**[확인]** 설치한 rekordbox 버전은 `7.2.18.0311`이다. 이 버전을 실행한 환경에서 최신 기존 DB 스냅샷의 `djmdContent.AnalysisDataPath`와 `FolderPath`를 연결했다. 음원과 분석 파일은 별도 임시 코퍼스로 복사했다. 분석 파일 내용과 음원 분석은 그 사본에서만 읽었다. 각 분석 파일을 처음 생성한 rekordbox 버전은 확인하지 못했다.

**[확인]** 표본은 분석 경로순으로 고른 16개이며, 파일이 존재하고 PSSI가 있다. 음원 바이트 해시가 서로 다른 MP3 5개·M4A 11개이고, mood는 high 2개·mid 14개다. 이 수는 실험 표본 수다. 전체 개인 라이브러리의 크기가 아니다. 다음 항목을 확보한 표본이 아니므로 전체 곡에 일반화하지 않는다.

- low mood
- WAV
- FLAC
- 3박자
- 장르별 대표성

다음 정보는 이 문서나 저장소에 넣지 않았다.

- 곡명
- 원본 경로
- ID
- 해시
- DB
- 음원
- 원본 태그

rekordbox 실행 파일은 분석하지 않았다. 태그 제거 후 재생이나 화면 변화를 확인하는 조작도 하지 않았다. 아래에서 **[확인]**은 직접 측정·공식 설명이다. **[제3자]**는 한 공개 프로젝트의 형식 해석이다. **[추정]**은 그 근거를 연결한 판단이다.

## PSSI 형식

**[확인]** 표본 모두 `.EXT`의 PSSI에 헤더 32바이트, 엔트리 24바이트가 있었다. 전체 길이는 `32 + 24 × 엔트리 수`였다. 시작 박은 증가했다. 마지막 시작 박보다 `end_beat`가 컸다. **[제3자]** 칸 이름·해석은 MIT인 [pyrekordbox의 구조 정의](https://github.com/dylanljones/pyrekordbox/blob/f695541827cc488af267d6ca8a8e0052598d85a0/pyrekordbox/anlz/structs.py)와 아래 Deep Symmetry 문서를 참고했다. 다중 바이트 정수는 big-endian이다.

| 태그 시작 기준 | 크기 | 의미·근거 수준 |
|---|---:|---|
| `0x00` | 4 | `PSSI` 식별자 [확인] |
| `0x04`, `0x08` | 각각 4 | 헤더 길이 32, 태그 전체 길이 [확인] |
| `0x0C` | 4 | 엔트리 크기 24 [확인] |
| `0x10` | 2 | 엔트리 수 [확인] |
| `0x12` | 2 | mood: 1 high, 2 mid, 3 low [제3자]; 표본은 1·2만 관찰 [확인] |
| `0x14` | 6 | 의미 미확인 |
| `0x1A` | 2 | 마지막 프레이즈의 끝 박 `end_beat` [제3자] |
| `0x1C` | 2 | 의미 미확인 |
| `0x1E` | 1 | Lighting bank [제3자]; 본 명령은 원시 값만 읽음 |
| `0x1F` | 1 | 의미 미확인 |
| `0x20` 이후 | 각각 24 | 프레이즈 엔트리 [확인] |

**[제3자]** 엔트리 기준 위치는 다음과 같다.

- `+0x00`은 순번(u16)이다.
- `+0x02`는 시작 박(u16)이다.
- `+0x04`는 kind(u16)다.

다음 엔트리의 시작 박이 현재 프레이즈의 끝이다. 마지막 프레이즈는 헤더의 `end_beat`를 쓴다. 위치는 마디 번호가 아니다. 비교 명령은 시작 박 1을 PQTZ 첫 엔트리에 대응시킨다. [Song Structure Tag](https://djl-analysis.deepsymmetry.org/rekordbox-export-analysis/anlz.html#_song_structure_tag)

**[제3자]** `+0x07/+0x09/+0x13`의 k1/k2/k3는 high mood의 표시 변형을 결정한다. `+0x0B`의 b와 `+0x0C/+0x0E/+0x10`의 beat_2/3/4는 프레이즈 내부의 추가 위치다. `+0x15`는 fill 표시다. `+0x16`은 fill 시작 박(u16)이다.

나머지 바이트의 의미는 미확인이다. 내부 위치를 새 섹션 경계로 취급하지 않았다. [같은 문서](https://djl-analysis.deepsymmetry.org/rekordbox-export-analysis/anlz.html#_song_structure_tag)

**[제3자]** kind의 뜻은 mood에 따라 바뀐다. 아래는 큰 종류만 정리한 표다. DJCrate 라벨과의 변환표가 아니다.

| mood | kind 해석 |
|---|---|
| high (1) | 1 Intro, 2 Up, 3 Down, 5 Chorus, 6 Outro; k 플래그로 변형 구분 |
| mid (2) | 1 Intro, 2…7 Verse 1…6, 8 Bridge, 9 Chorus, 10 Outro |
| low (3) | 1 Intro, 2…4 Verse 1, 5…7 Verse 2, 8 Bridge, 9 Chorus, 10 Outro |

출처: [Deep Symmetry의 phrase labels](https://djl-analysis.deepsymmetry.org/rekordbox-export-analysis/anlz.html#phrase-labels). 표시 라벨을 직접 바꾼 전후 파일 비교는 이번에 하지 않았다.

**[제3자]** 내보낸 PSSI에는 `0x12`부터 XOR로 처리한 변형이 있다. DJCrate는 pyrekordbox처럼 mood가 1…3이 아니면 이 변형으로 본다. 그러면 19바이트 마스크에 엔트리 수를 더해 복원한다. 그 뒤 다음 항목을 다시 검사한다.

- 길이
- mood
- 순번
- 시작/끝 순서

**[확인]** 합성 고정 표본으로 복원을 시험했다. 이번 실음원 표본에서는 마스킹한 PSSI를 시험하지 않았다. 알 수 없는 형식을 억지로 생성하는 기능은 없다. 쓰는 기능도 없다. [pyrekordbox 읽기 구현](https://github.com/dylanljones/pyrekordbox/blob/f695541827cc488af267d6ca8a8e0052598d85a0/pyrekordbox/anlz/file.py)

## 섹션 경계 비교

**[확인]** `djc lab phrase-eval`은 다음 방법으로 집계한다.

1. `PartAnalyzer.analyze`를 캐시 키 없이 실행해 현재 DJCAnalysis의 `sections` 시작 시각을 얻는다. Apple MusicUnderstanding이 제공하는 별도 `phrases` 배열은 이번 비교 대상이 아니다.
2. 음원 시간에 `RekordboxTimeline.predictedOffset`을 더한다. PQTZ와 존재하는 PQT2의 실제 박 시각 사이를 보간한다. 그래서 곡 전체 BPM 한 값으로 시간을 나누지 않는다.
3. 두 결과를 동일한 4박 그리드의 가장 가까운 마디 시작으로 반올림한다. 아래 “같은 마디”는 밀리초나 박 단위 완전 일치가 아니다. 마디 안 위치 차이를 최대 반 마디 숨길 수 있다.
4. PSSI 첫 프레이즈 시작·마지막 끝과 DJCrate 첫 섹션 시작은 점수에서 뺀다. PSSI 시작…끝의 열린 구간 밖 예측 4개는 `outsideReference`로 세고 분모에서 뺀다. 끝점만 맞아 점수가 올라가는 것을 막으려는 평가 구간이다.
5. 내부 경계를 정렬한 순서로 최대 일대일 대응시킨다. 같은 마디로 반올림한 여러 예측도 별개로 센다. 그래서 한 정답을 여러 번 맞힌 것으로 세지 않는다.
   - 정밀도는 일치/예측, 재현율은 일치/PSSI다.
   - F1은 `2×일치/(예측+PSSI)`다.
   - 전체는 경계 수를 합친 micro 집계다.
   - 빈 분모는 JSON `null`이다.

| 허용 범위 | PSSI 경계 | DJCrate 경계 | 일치 | 정밀도 | 재현율 | F1 |
|---|---:|---:|---:|---:|---:|---:|
| 같은 마디 | 393 | 277 | 85 | 30.7% | 21.6% | 25.4% |
| ±1마디 | 393 | 277 | 182 | 65.7% | 46.3% | 54.3% |

**[확인]** 16/16 평가 성공, 명령 종료 코드 0이다. high 표본에서 같은 마디 일치는 20/39개 PSSI 경계였고 예측은 34개였다. mid에서는 65/354개였고 예측은 243개였다. **[추정]** 그룹별 차이는 표본 수와 선택 편향이 크다. 그래서 mood에 따른 분석 성능으로 단정할 수 없다. 경계의 희소성도 달라서, 한쪽 정밀도만으로 대체 가능성을 판단하면 안 된다.

**[확인]** `PartAnalysis`는 sections 외에 다음 값을 제공한다.

- phrases
- segments
- vocal
- drum
- loudness

`PartLabeler`는 활동량을 조합해 자체 라벨을 붙인다. rekordbox mood/kind를 예측하는 모델은 아니다. **[추정]** 재생 준비용 후보 구간에는 쓸 수 있다. PSSI 호환 분류에는 별도 정답·오류 분석이 필요하다.

### 재현

코퍼스 폴더 안에 `sample-001/audio.mp3` 같은 음원 사본 한 개와 `ANLZ0000.DAT`, `ANLZ0000.EXT`를 둔다. 각 sample 폴더는 별도 곡이다. 원본 경로가 남을 수 있는 분석 파일은 공개하지 않는다. 커밋도 하지 않는다. 음원 대응은 스냅샷 DB의 `AnalysisDataPath ↔ FolderPath`를 쓴다. PPTH는 현재 음원 경로와 다를 수 있다.

```sh
DJC_HOME=$(mktemp -d) .build/debug/djc lab phrase-eval \
  --corpus "$corpus" --limit 16 --out "$new_result_json"
swift test --filter PhraseEvaluationTests
```

`corpus`는 준비한 사본 폴더를 가리킨다. `new_result_json`은 아직 없는 결과 파일을 가리킨다. 출력은 다음 항목뿐이다.

- 표본 번호
- mood
- 경계 개수
- 일치 수
- 비율
- 정해진 실패 이유

경로·음원 메타데이터·태그 바이트는 출력하지 않는다. PSSI 누락이나 분석 실패는 행마다 남긴다. 하나라도 실패하면 종료 코드 1을 반환한다. 읽을 코퍼스와 양의 표본 상한을 검증한다. 기존 결과는 덮어쓰지 않는다.

## PVDI와 .3EX

### 사본에서 관찰한 범위

**[확인]** 같은 표본의 PVDI는 `.2EX` 안의 ANLZ 태그였고 헤더 길이는 24였다. `+0x0C` u32는 `0x00000400`이었다. `+0x10` u32는 `0x56220001`이었다. `+0x14` u32는 본문 바이트 수와 같았다. 본문 길이는 표본별로 달랐다. 다음 항목은 확인하지 않았다.

- 이 상수의 의미
- 시간 해상도
- 값과 보컬 구간의 대응
- 압축 여부

그러므로 DJCAnalysis의 vocal 값을 임계값으로 잘라 PVDI로 넣을 수 있다는 결론은 내리지 않는다.

**[확인]** `.3EX`는 이 표본에서 PMAI 태그 파일이 아니었다. 최상위 키 `embedding`을 가진 MessagePack map이었다. 표본 전체를 마지막 바이트까지 읽었다. 크기는 5,472…9,829바이트였다. 내부에는 `d2`…`d12` 키가 있었다.

- `d6`는 float 64개 배열이다.
- `d7`은 float 2개 배열이다.
- `d5`는 길이가 달라지는 중첩 배열이다.
- `d2/d3`는 문자열이다.
- 나머지는 수치였다.

벡터·문자열 값 자체는 보고에 넣지 않았다.

**[추정]** 이름과 수치 구조는 추천·프레이즈 특징 저장이라는 기존 가설에 부합한다. 그러나 다음 항목을 모르면 임의 임베딩이나 다른 모델의 64차원 벡터로 채울 수 없다.

- d 필드의 의미
- 모델
- 정규화
- 버전/검증 규칙

`.3EX`를 올바른 MessagePack으로 직렬화하는 것만으로는 호환 추천 결과가 보장되지 않는다.

### 기능 의존성과 확인의 한계

| 기능 | 확인된 의존성 | 아직 확인하지 않은 부분 |
|---|---|---|
| 프레이즈 표시·Lighting | [제3자] PSSI는 곡 구조 정보와 Lighting의 종류·위치를 담는다. [형식 문서](https://djl-analysis.deepsymmetry.org/rekordbox-export-analysis/anlz.html#_song_structure_tag) | PSSI만 제거한 사본을 rekordbox에 열었을 때 표시·재분석 동작 |
| Intelligent Cue Creation | [확인] 공식 FAQ는 자동 큐가 Phrase 분석 정보를 사용한다고 설명한다. 프레이즈 분석 불가 시 큐가 설정되지 않을 수 있다고도 설명한다. [FAQ](https://rekordbox.com/en/support/faq/rekordbox7/#faq-70961) | PSSI만 있으면 충분한지, .3EX의 추가 정보도 필요한지 |
| 보컬 위치 표시 | [확인] 공식 설명은 보컬 분석 결과를 전체 파형 위에 표시한다. 7.2.16부터 Free에서도 가능하다. [기능 설명](https://rekordbox.com/en/feature/overview/), [FAQ](https://rekordbox.com/en/support/faq/rekordbox7/#faq-q700012) | [추정] PVDI가 해당 저장소라는 가설은 태그 하나만 제거하는 비교로 확인해야 함; 표시·STEMS 분리는 별개 |
| Collection/Streaming Radar | [확인] 추천 분석 데이터가 없는 곡은 기준곡도 추천 후보도 될 수 없다. Add New Analysis Data로 보충하며 BPM/Grid 재분석은 필요 없다. [FAQ](https://rekordbox.com/en/support/faq/v7/#faq-70748) | [추정] .3EX가 그 핵심 저장소라는 가설; 공식 문서는 파일명을 명시하지 않아 단독 필요/충분 조건은 미확인 |
| DJCrate 기본 관리·파형·큐·그리드 | [확인] 현재 생성기는 세 결과를 만들지 않는다. 앱의 해당 경로는 이 분석 결과를 읽지 않는다. [기존 기록](rekordbox-internals.md) | 이번 조사에서 실제 UI·USB/CDJ의 태그 생략 호환성은 시험하지 않음 |

**[확인]** 기존 저장소 실험에는 Phrase만 분석하면 DJCrate 태그를 그대로 두고 PSSI를 추가한다는 기록이 있다. 이번에는 재실험하지 않았다. Vocal 분석·Add New Analysis Data도 기존 태그를 보존한다고 확대 해석하지 않는다. [기존 분석 기록](rekordbox-internals.md)

## 다음 실험과 구현 판단

1. **[추정]** PSSI 직접 생성의 우선순위는 낮게 유지한다. 먼저 같은 사본에서 `sections`, `phrases`, `segments`를 구분해 비교한다. 장르, mood, 길이, 템포 변화가 다른 표본을 확보해야 한다. 사람의 경계 표시도 확보해야 한다. 현재 16개로 모델이나 임계값을 튜닝한 뒤 같은 표본 점수를 성능으로 제시하면 안 된다.
2. **[추정]** 사용자가 rekordbox에서 mood/kind/fill/bank를 각각 한 번씩 편집한 전후 사본을 비교해야 한다. 그래야 표시 의미를 [확인]으로 올릴 수 있다. 실제 박·마디 번호와 맞는지도 화면에서 확인한다. 이번 결과는 새 쓰기 허용 근거가 아니다.
3. **[추정]** PVDI와 `.3EX`는 재분석 전후와 태그/파일을 하나씩 뺀 독립 라이브러리 사본을 비교해야 한다. 자동 재분석·캐시·DB 분석 상태도 함께 기록한다. “다시 만들어져서 표시된 것”을 필요성 증거와 혼동하지 않기 위해서다. 파일 제거·편집 실험은 아직 실행하지 않았다.
4. **[추정]** `.3EX`의 생성 모델을 공개하지 않는다면 호환 벡터 쓰기 대신 DJCrate 내부의 독립 추천 기능을 별도 과제로 판단할 수 있다. 이번 이슈에서는 추천 기능을 추가하지 않는다.

## 출처·라이선스

- **pyrekordbox**: [기준 커밋](https://github.com/dylanljones/pyrekordbox/tree/f695541827cc488af267d6ca8a8e0052598d85a0), [MIT LICENSE](https://github.com/dylanljones/pyrekordbox/blob/f695541827cc488af267d6ca8a8e0052598d85a0/LICENSE). PSSI 칸 배치·XOR 규칙에 사용했다. 이식 범위와 고지 원문은 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)에 있다.
- **Deep Symmetry / Crate Digger**: [문서 원본](https://github.com/Deep-Symmetry/crate-digger/blob/main/doc/modules/ROOT/pages/anlz.adoc), [LICENSE](https://github.com/Deep-Symmetry/crate-digger/blob/main/LICENSE), [README의 라이선스 설명](https://github.com/Deep-Symmetry/crate-digger#licenses). EPL-2.0 및 명시한 secondary license 조항을 확인했다. mood/kind/fill의 뜻을 비교 참고했다. 구현·생성 파서·문서 원문은 옮기지 않았다.
- **AlphaTheta / rekordbox 공식 FAQ·기능 설명**: 각 주장 옆 링크, 2026-09-27 확인. 저작권은 AlphaTheta에 있다. 오픈소스 구현 라이선스가 아니다. 기능의 공개 설명을 사실 확인에 사용했다. 코드·도표·원문은 복제하지 않았다.
- **직접 관찰**: 임시 사본의 PSSI/PVDI/.3EX와 현재 DJCAnalysis 실행 결과. 원본 데이터·개인 정보는 공개 산출물에서 제외했다. 라이선스를 확인하지 않은 외부 역공학 자료는 사용하지 않았다.

## 검증 기록

- `swift test --filter PhraseEvaluationTests`: 당시 **10개 통과**. 시험이 다룬 내용은 다음과 같다. 항목 수와 시험 수는 같지 않다.
  - PSSI 길이·순서 검증
  - XOR 고정 표본
  - 중복 경계 일대일 대응
  - 템포 변화·시간축 보정
  - 빈 분모
  - 인자 검증
  - 익명 코퍼스 집계, 입력 보존, 오류 익명화, 취소 전파
- #167에서 연구 도구의 알고리즘 시험은 빼고 **1개**만 남겼다. 남긴 시험 하나가 익명 코퍼스 집계, 누락 분리, 입력 ANLZ 보존, 오류 익명화를 다룬다.
- 실음원 사본 `djc lab phrase-eval`: **16개 성공, 종료 코드 0**, 위 집계 수치.
- `git fetch origin && git merge origin/dev`: `c38c57599e6d2c86a21b62d022b9506d2e24eba8`을 포함한 상태에서 확인했다.
- `scripts/check.sh`: **통과**. 디버그·릴리스 앱 빌드와 전체 **671개 테스트**가 통과했다. 테스트 수는 10 + 160 + 296 + 181 + 24다. 줄 커버리지는 다음과 같다.
  - 쓰기 **93.4%** (2,213/2,369)
  - 코어 **87.1%** (8,865/10,173)
  - 앱 **29.9%** (5,187/17,374)
- **미확인**: 다음 항목을 확인하지 못했다. 앱을 켜지도 종료하지도 않았다.
  - 실제 rekordbox 화면의 라벨 대응
  - 태그 생략 전후 UI
  - USB/CDJ
  - PVDI 본문
  - .3EX 필드 의미와 생성 모델
