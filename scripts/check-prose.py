#!/usr/bin/env python3
"""문서 문장이 간결 기술 한국어 규칙(ASD-STE100을 한국어에 맞춘 것)을 얼마나 따르는지 잰다(#167).

규칙(등급: 오류 E는 고쳐야 통과, 경고 W는 지표에만, 정보 I는 --info에서만):
  E1 문장 25어절 이하               W1 설명 17어절·절차(번호 목록) 14어절 이하
  E2 한 문장 나열 3항목까지(·3개↑)   W2 대등 연결 어미(-고·-며·-면서·-지만·-는데·-거나)
  E3 괄호는 참조에만(묶음 2개↑·4어절↑) W3 명사 묶음 4어절↑(--morph, kiwipiepy가 있을 때만)
  E4 이중 피동·-되어야 한다          W4 구문 피동(명사+되다·-어지다·-받다)
  E5 용어표의 쓰지 않는 말           I1 지시 어미 섞임  I2 IMPORTANT 첫 문장  I3 인라인 코드 3개↑
  E6 문단·목록 항목당 6문장 이하
문장 뽑기: 머리·HTML 주석·코드 블록·제목은 뺀다. 인라인 코드·URL·경로는 낱말 하나(CODE)로 센다. 목록 항목·문단을
괄호 밖 `. ? !` 뒤 공백에서 나눈다. 표 칸과 한글 없는 문장은 길이 규칙(표 칸은 E5도)만 보고 지표에서 뺀다.
지표: A = 위반 0인 문장 비율, A' = 오류 0인 문장 비율, B = 100어절당 위반 수, B' = 100어절당 오류 수.

통과 기준: (1) 기준 rev 대비 더하거나 고친 줄에 걸친 문장에 오류가 없다. (2) 문서마다 A가 기준선
(scripts/prose-baseline.txt) 아래로, B가 위로 가지 않는다. A ≥ 80%인 문서는 기준선을 80으로 둔다. 기준선에 없는
문서는 A ≥ 80%여야 한다.
예외: 줄 끝 `<!-- prose: E3 W2 -->`는 그 줄에 걸친 문장의 그 규칙을, 파일 앞 10줄 안의 `<!-- prose: off -->`는 파일 전체를 뺀다.

사용:
  scripts/check-prose.py [--base <rev>|--no-diff] [--files <경로…>] [--all] [--info] [--morph]
  scripts/check-prose.py --report [--files <경로…>]          표만, 늘 종료 코드 0
  scripts/check-prose.py --write-baseline                    좋아진 값만 기준선에 적는다
  scripts/check-prose.py --preserve <옛 파일…> --to <새 파일…>  고쳐 쓴 전후 숫자·식별자·이슈 번호·부정어 비교
    (옛 파일은 `<rev>:<경로>`도 된다)
종료 코드: 0 통과, 1 위반(또는 정보가 빠짐), 2 인자 오류.
"""
import argparse
import difflib
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TERMS_FILE = "scripts/prose-terms.txt"
BASELINE_FILE = "scripts/prose-baseline.txt"
TARGET_GLOBS = ["AGENTS.md", "CLAUDE.md", ".claude/rules/**/*.md", ".claude/skills/**/*.md", ".claude/agents/**/*.md",
                "docs/*.md", "README.md", "CONTRIBUTING.md", "skills/djcrate/SKILL.md"]
GOAL = 80.0
LIMIT_ERROR, LIMIT_DESC, LIMIT_PROC = 25, 17, 14
LIMIT_EN_PROC = 20  # 영어 절차 문장(STE 20낱말)
MAX_SENTENCES = 6

NAMES = {"E1": "긴 문장", "E2": "긴 나열", "E3": "긴 괄호", "E4": "이중 피동", "E5": "쓰지 않는 말", "E6": "긴 문단",
         "W1": "긴 문장(권장)", "W2": "대등 연결", "W3": "명사 묶음", "W4": "구문 피동",
         "I1": "지시 어미 섞임", "I2": "경고 첫 문장", "I3": "식별자 많음"}
JUDGED = ["E1", "E2", "E3", "E4", "E5", "E6", "W1", "W2", "W3", "W4"]

FENCE = re.compile(r"^\s*(```|~~~)")
LIST = re.compile(r"^(\s*)([-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?(.*)$")
ORDERED = re.compile(r"^\s*\d+[.)]\s")
HEADING = re.compile(r"^\s{0,3}#{1,6}(\s|$)")
TABLE = re.compile(r"^\s*\|")
TABLE_RULE = re.compile(r"^\s*\|?[\s:|-]+\|?\s*$")
RULE_LINE = re.compile(r"^\s*([-*_])(\s*\1){2,}\s*$")
LINK_DEF = re.compile(r"^\s*\[[^\]]+\]:\s*\S+")
MARKER = re.compile(r"<!--\s*prose:\s*([^>]*?)\s*-->")
INLINE_CODE = re.compile(r"``[^`]+``|`[^`]+`")
IMAGE = re.compile(r"!\[[^\]]*\]\([^)]*\)")
LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
LINK_TARGET = re.compile(r"\]\([^)\s]*(?:\([^)\s]*\)[^)\s]*)*\)")
URL = re.compile(r"https?://[^\s()<>`]+(?:\([^\s()]*\)[^\s()<>`]*)*")
PATHLIKE = re.compile(r"(?<![\w가-힣])[~.\w-]*/[\w./*{}<>…-]+")
TAG = re.compile(r"</?[A-Za-z][^>]*>")
COMMENT_OR_CODE = re.compile(r"(``[^`\n]+``|`[^`\n]+`)|<!--.*?-->", re.S)
QUOTED = re.compile(r'"[^"]*"|“[^”]*”|「[^」]*」|『[^』]*』')
WORDCHAR = re.compile(r"[0-9A-Za-z가-힣]")
HANGUL = re.compile(r"[가-힣]")

# W2: 대등 연결 어미로 끝나는 어절(마지막 어절 제외). 명사(경고·보고…), 인용(-다고), 보조 용언 앞(-고 있다)은 뺀다
COORD = re.compile(r"^[가-힣]*[가-힣](고|며|면서|지만|는데|은데|거나)[,]?$")
NOUN_GO = {"경고", "보고", "참고", "최고", "재고", "사고", "창고", "광고", "신고", "원고", "제고", "등고", "고고", "공고",
           "선고", "충고", "노고", "탈고", "투고", "기고", "회고"}
QUOTE_GO = re.compile(r"(다|라|자|냐|래)고[,]?$")
AUX_NEXT = re.compile(r"^(있|싶|나서|난|말|보|계시)")
# W4: 구문 피동(연구 §4.5 정규식, 형태소 판정 대비 정밀도 0.89). 바뀌다·보이다·막히다 같은 굳은 말은 걸리지 않는다
_JI = r"(진다|지는|진|져|졌|지면|지고|지므로|지게|질)"
PASSIVE = re.compile(r"[가-힣]{2,}(된다|되는|되어|돼|됐|되면|되고|되며|되므로|되지|될|된|받는다|받은|받아)"
                     r"|[가-힣](어|아|여|려|겨|쳐)" + _JI + r"|[가-힣](해|워|러)" + _JI)
# 피동이 아닌 굳은 말: 오래되다, 이어지다·켜지다·꺼지다(자동사), 느려지다(형용사), 알려진(굳은 말),
# 넘겨받다·이어받다(주고받는 동작)
NOT_PASSIVE = re.compile(r"오래되|오래된|(?:이어|느려|알려)(?:지|진|져|졌)|(?:넘겨|이어|물려)받")
# E4: 이중 피동(피동사 + -어지다, 되어지다)과 -되어야 한다. 알려지다·그려지다·옮겨지다처럼 능동사 + -어지다는 뺀다
_PASSIVE_TAIL = r"(?:지[는다고며면게기]|진|져|졌)"
DOUBLE_PASSIVE = re.compile(
    r"되어" + _PASSIVE_TAIL
    + r"|(?:잡|막|닫|읽|묻|박|먹|꽂|업|얹|밟|찍|씹|접|뽑|굽)혀" + _PASSIVE_TAIL
    + r"|(?:보|쓰|놓|쌓|섞|파|짜|덮)여" + _PASSIVE_TAIL
    + r"|(?:열|불|걸|팔|풀|밀|들|눌|뚫|잘|갈|털|빨|실)려" + _PASSIVE_TAIL
    + r"|(?:안|감|씻|담|끊|쫓|찢|뺏|빼앗|벗|잠)겨" + _PASSIVE_TAIL
    + r"|(?:바뀌|나뉘)어" + _PASSIVE_TAIL
    + r"|(?:되어야|돼야)\s*(?:한다|합니다|해|하며|하고)")
NEGATION = re.compile(r"않|없|못|금지|말고|말라|마라|아니|(?<![가-힣])안(?=\s)|\b(?:not|never|no)\b", re.I)
DIRECTIVE_END = re.compile(r"다$")
POLITE_END = re.compile(r"(니다|세요|십시오|습니까)$")
DESCRIPTIVE_END = re.compile(r"(이다|있다|없다|었다|았다|였다|된다)$")


# ── 용어표 ───────────────────────────────────────────────────

class Terms:
    def __init__(self, banned=(), terms=()):
        self.banned = list(banned)   # (쓰지 않는 말, 쓰는 말)
        self.terms = list(terms)
        self.banned_regex = [(re.compile(r"(?<![가-힣A-Za-z])" + r"\s+".join(map(re.escape, word.split()))), word, use)
                             for word, use in self.banned]


def load_terms(path):
    banned, terms, section = [], [], None
    path = Path(path)
    if not path.is_file():
        return Terms()
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        if section == "쓰지 않는 말" and "→" in line:
            word, use = (part.strip() for part in line.split("→", 1))
            banned.append((word, use))
        elif section == "용어":
            terms.append(line)
    return Terms(banned, terms)


# ── 문장 뽑기 ─────────────────────────────────────────────────

class Unit:
    """판정 단위 하나. kind: sentence(한국어 문장)·cell(표 칸)·english(한글 없는 문장)."""

    def __init__(self, kind, line, lines, raw, text, block, procedure, codes):
        self.kind, self.line, self.lines, self.raw, self.text = kind, line, lines, raw, text
        self.block, self.procedure, self.codes = block, procedure, codes
        self.words = len(eojeols(text))
        self.rules, self.info, self.excluded = [], [], []
        self.hint = {}

    @staticmethod
    def view(unit, skip):
        if not skip or not set(unit.rules) & set(skip):
            return unit
        copy = Unit.__new__(Unit)
        copy.__dict__.update(unit.__dict__, rules=[r for r in unit.rules if r not in skip])
        return copy


def eojeols(text):
    return [w for w in text.split() if WORDCHAR.search(w)]


def mask(text):
    """문장 나누기용: 인라인 코드·링크 주소·URL을 같은 길이의 x로 가린다(줄 위치를 지키려고)."""
    def blank(match):
        return "x" * len(match.group(0))
    text = INLINE_CODE.sub(blank, text)
    text = LINK_TARGET.sub(lambda m: "]" + "x" * (len(m.group(0)) - 1), text)
    return URL.sub(blank, text)


def normalize(text):
    codes = len(INLINE_CODE.findall(text))
    text = INLINE_CODE.sub("CODE", text)
    text = IMAGE.sub("", text)
    text = LINK.sub(lambda m: m.group(1) or "CODE", text)
    text = URL.sub("CODE", text)
    text = TAG.sub("", text)
    text = PATHLIKE.sub("CODE", text)
    text = text.replace("**", "").replace("__", "").replace("\\|", "|")
    return re.sub(r"\s+", " ", text).strip(), codes


CLOSERS = "*_\"'”’」』"


def split_spans(masked):
    """괄호 밖 `. ? !` 뒤 공백(또는 끝)에서 나눈 (시작, 끝) 목록."""
    spans, start, depth = [], 0, 0
    for k, ch in enumerate(masked):
        if ch in "(（[":
            depth += 1
        elif ch in ")）]":
            depth = max(0, depth - 1)
        elif ch in ".?!" and depth == 0:
            end = k + 1
            while end < len(masked) and masked[end] in CLOSERS:  # **문장.** 다음, "인용." 다음
                end += 1
            if end == len(masked) or masked[end].isspace():
                spans.append((start, end))
                start = end
    spans.append((start, len(masked)))
    return spans


def strip_comments(text):
    """HTML 주석을 지운다(줄 수는 지킨다). 인라인 코드 안의 `<!-- … -->` 예시는 남긴다."""
    return COMMENT_OR_CODE.sub(lambda m: m.group(1) or "\n" * m.group(0).count("\n"), text)


def blocks(text):
    """(종류, [(줄 번호, 글)…]) 목록. 종류: para·list·olist·row. 표 줄은 row 하나씩."""
    lines = text.split("\n")
    start = 0
    if lines and lines[0].strip() == "---":
        for k in range(1, len(lines)):
            if lines[k].strip() == "---":
                start = k + 1
                break
    body = "\n".join(lines[start:])
    body = strip_comments(body)
    out, current, fence = [], None, None
    for number, line in enumerate(body.split("\n"), start + 1):
        found = FENCE.match(line)
        if found:
            if fence is None:
                fence = found.group(1)
            elif found.group(1) == fence:
                fence = None
            current = None
            continue
        if fence is not None:
            continue
        stripped = line.rstrip()
        if not stripped.strip() or HEADING.match(stripped) or RULE_LINE.match(stripped) or LINK_DEF.match(stripped):
            current = None
            continue
        if TABLE.match(stripped):
            if not TABLE_RULE.match(stripped):
                out.append(("row", [(number, stripped)]))
            current = None
            continue
        content = re.sub(r"^\s*(>\s?)+", "", stripped)
        item = LIST.match(content)
        if item:
            current = ("olist" if item.group(2)[0].isdigit() else "list", [(number, item.group(3))])
            out.append(current)
        elif current is not None:
            current[1].append((number, content.strip()))
        else:
            current = ("para", [(number, content.strip())])
            out.append(current)
    return out


def table_cells(row):
    masked = mask(row)
    cells, begin = [], None
    for k, ch in enumerate(masked):
        if ch == "|" and (k == 0 or masked[k - 1] != "\\"):
            if begin is not None:
                cells.append(row[begin:k])
            begin = k + 1
    if begin is not None and row[begin:].strip():
        cells.append(row[begin:])
    return cells


def units_of(text):
    units = []
    for block_id, (kind, pieces) in enumerate(blocks(text)):
        if kind == "row":
            number, row = pieces[0]
            for cell in table_cells(row):
                normal, codes = normalize(cell)
                if WORDCHAR.search(normal):
                    units.append(Unit("cell", number, {number}, cell.strip(), normal, block_id, False, codes))
            continue
        joined, offsets = "", []
        for number, piece in pieces:
            offsets.append((len(joined), number))
            joined += piece + " "
        for begin, end in split_spans(mask(joined)):
            raw = joined[begin:end]
            lead = len(raw) - len(raw.lstrip())
            raw = raw.strip()
            if not raw:
                continue
            first, last = begin + lead, begin + lead + len(raw) - 1
            # 문장이 걸친 줄: 첫 글자가 든 줄부터 끝 글자가 든 줄까지
            line = max(n for offset, n in offsets if offset <= first)
            lines = {n for offset, n in offsets if offset <= last and n >= line}
            normal, codes = normalize(raw)
            if not WORDCHAR.search(normal):
                continue
            unit_kind = "sentence" if HANGUL.search(normal) else "english"
            units.append(Unit(unit_kind, line, lines, raw, normal, block_id, kind == "olist", codes))
    return units


# ── 판정 ──────────────────────────────────────────────────────

def paren_groups(text):
    groups, depth, start = [], 0, None
    for k, ch in enumerate(text):
        if ch in "(（":
            if depth == 0:
                start = k
            depth += 1
        elif ch in ")）" and depth:
            depth -= 1
            if depth == 0:
                groups.append(text[start + 1:k])
    return groups


def strip_parens(text):
    out, depth = [], 0
    for ch in text:
        if ch in "(（":
            depth += 1
        elif ch in ")）" and depth:
            depth -= 1
        elif depth == 0:
            out.append(ch)
    return "".join(out)


def paren_words(group):
    example = re.match(r"^\s*예\s*:\s*(.*)$", group, re.S)
    return len(eojeols(example.group(1) if example else group))


def reference_paren(group):
    """참조로 허용하는 괄호: 이슈 번호, 식별자·경로 하나, 예: 3어절 이하."""
    group = group.strip()
    if re.fullmatch(r"#\d+(?:\s*[,·]\s*#\d+)*", group) or group == "CODE":
        return True
    return bool(re.match(r"^예\s*:", group)) and paren_words(group) <= 3


def coordinate_count(body):
    words = [w for w in body.replace("·", ", ").replace("→", ", ").split() if WORDCHAR.search(w)]
    count = 0
    for k, word in enumerate(words[:-1]):
        bare = word.rstrip(",")
        if COORD.match(word) and bare not in NOUN_GO and not QUOTE_GO.search(word) and not AUX_NEXT.match(words[k + 1]):
            count += 1
    return count


class Morph:
    """kiwipiepy로 명사 묶음을 본다(W3). 용어표의 띄어 쓴 용어는 붙여 한 어절로 센다."""
    NOMINAL_END = {"NNG", "NNP", "NNB", "NR", "SL", "SN", "SH", "XSN", "ETN", "XR"}
    NOMINAL_START = {"NNG", "NNP", "NNB", "NR", "SL", "SN", "SH", "XPN", "XR", "NP"}
    # 부사처럼 쓰여 묶음을 끊는 명사("확인 창 대신 경고 알림"의 대신)
    BREAKS = {"대신", "때", "뒤", "전", "후", "중", "동안", "사이", "경우", "다음", "등", "말고"}

    def __init__(self, terms):
        from kiwipiepy import Kiwi
        self.kiwi = Kiwi()
        self.terms = sorted(terms.terms, key=len, reverse=True)

    def cluster(self, text):
        body = strip_parens(text).replace("·", ", ").replace("→", ", ")
        for term in self.terms:
            body = body.replace(term, term.replace(" ", ""))
        body = re.sub(r"\s+", " ", body).strip()
        if not body:
            return 0
        spans, position = [], 0
        for word in body.split(" "):
            spans.append((position, position + len(word), word))
            position += len(word) + 1
        per = [[] for _ in spans]
        index = 0
        for token in self.kiwi.tokenize(body):
            while index < len(spans) - 1 and token.start >= spans[index][1]:
                index += 1
            per[index].append(token.tag)
        best = run = 0
        for k, tags in enumerate(per):
            if not tags:
                run = 0
                continue
            word = spans[k][2]
            if word.rstrip(",.") in self.BREAKS:
                run = 0
                continue
            starts = tags[0] in self.NOMINAL_START or (tags[0] in ("VV", "VA") and "ETN" in tags)
            bare = (tags[-1] in self.NOMINAL_END and not re.search(r"[,.;:)\]]$", word) and "SP" not in tags
                    and not (len(tags) >= 2 and tags[-1] == "ETN" and tags[0] not in self.NOMINAL_START))
            if run and starts:
                best = max(best, run + 1)
            run = (run + 1 if run else 1) if bare and starts else 0
        return best


def judge(unit, terms, morph):
    text, rules = unit.text, unit.rules
    if unit.words > LIMIT_ERROR:
        rules.append("E1")
    if unit.kind == "cell":
        if "E1" not in rules and unit.words > LIMIT_DESC:
            rules.append("W1")
    elif unit.kind == "english":
        if "E1" not in rules and unit.procedure and unit.words > LIMIT_EN_PROC:
            rules.append("W1")
        return
    elif "E1" not in rules and unit.words > (LIMIT_PROC if unit.procedure else LIMIT_DESC):
        rules.append("W1")
    unquoted = QUOTED.sub("CODE", text)  # 따옴표 안은 rekordbox 화면 이름 같은 인용이라 E5에서 뺀다
    for pattern, word, use in terms.banned_regex:
        if pattern.search(unquoted):
            rules.append("E5")
            unit.hint["E5"] = f"{word} → {use}"
            break
    if unit.kind == "cell":
        return
    if text.count("·") >= 3:
        rules.append("E2")
    groups = paren_groups(text)
    counted = [g for g in groups if not reference_paren(g)]
    if len(counted) >= 2 or any(paren_words(g) >= 4 for g in groups):
        rules.append("E3")
    if DOUBLE_PASSIVE.search(text):
        rules.append("E4")
    body = strip_parens(text)
    if coordinate_count(body):
        rules.append("W2")
    if morph is not None and morph.cluster(text) >= 4:
        rules.append("W3")
    if "E4" not in rules and PASSIVE.search(NOT_PASSIVE.sub(" ", body)):
        rules.append("W4")
    if unit.codes > 2:
        unit.info.append("I3")


class Doc:
    def __init__(self, path, units, excluded, off):
        self.path, self.units, self.excluded, self.off = path, units, excluded, off

    def metrics(self, skip=()):
        """skip: 지표에서 뺄 규칙. 기준선은 W3을 빼고 잰다(kiwipiepy가 있는 기계와 없는 기계가 같은 값을 얻게)."""
        sentences = [Unit.view(u, skip) for u in self.units if u.kind == "sentence"]
        counts = Counter(rule for u in sentences for rule in u.rules)
        return {
            "path": self.path, "sentences": len(sentences), "words": sum(u.words for u in sentences),
            "clean": sum(1 for u in sentences if not u.rules),
            "clean_errors": sum(1 for u in sentences if not any(r.startswith("E") for r in u.rules)),
            "violations": sum(len(u.rules) for u in sentences),
            "errors": sum(1 for u in sentences for r in u.rules if r.startswith("E")),
            "counts": counts, "other": sum(len([r for r in u.rules if r not in skip]) for u in self.units
                                           if u.kind != "sentence"),
            "excluded": self.excluded, "off": self.off,
            **ratios(len(sentences), sum(u.words for u in sentences),
                     sum(1 for u in sentences if not u.rules),
                     sum(1 for u in sentences if not any(r.startswith("E") for r in u.rules)),
                     sum(len(u.rules) for u in sentences),
                     sum(1 for u in sentences for r in u.rules if r.startswith("E"))),
        }


def ratios(sentences, words, clean, clean_errors, violations, errors):
    return {"A": 100.0 * clean / sentences if sentences else 100.0,
            "A2": 100.0 * clean_errors / sentences if sentences else 100.0,
            "B": 100.0 * violations / words if words else 0.0,
            "B2": 100.0 * errors / words if words else 0.0}


def combine(items):
    """문서들의 지표를 문장 수(A)·어절 수(B)로 가중해 합친다."""
    keys = ("sentences", "words", "clean", "clean_errors", "violations", "errors", "other", "excluded")
    total = {key: sum(m[key] for m in items) for key in keys}
    total["counts"] = sum((m["counts"] for m in items), Counter())
    total.update(ratios(total["sentences"], total["words"], total["clean"], total["clean_errors"], total["violations"],
                        total["errors"]))
    total["path"] = "전체"
    total["off"] = False
    return total


def analyze(text, path, terms=None, morph=None):
    terms = terms or Terms()
    lines = text.split("\n")
    bare = [INLINE_CODE.sub("", line) for line in lines]  # 인라인 코드 안의 표시 예시는 표시가 아니다
    if any(found.group(1).strip() == "off" for line in bare[:10] for found in MARKER.finditer(line)):
        return Doc(path, [], 0, True)
    markers = {}
    for number, line in enumerate(bare, 1):
        for found in MARKER.finditer(line):
            markers.setdefault(number, set()).update(re.findall(r"[EWI]\d", found.group(1)))
    units = units_of(text)
    for unit in units:
        judge(unit, terms, morph)
    # E6: 문단·목록 항목 하나에 6문장 넘게. 넘친 문장마다 센다
    per_block = Counter(u.block for u in units if u.kind != "cell")
    seen = Counter()
    for unit in units:
        if unit.kind == "cell":
            continue
        seen[unit.block] += 1
        if per_block[unit.block] > MAX_SENTENCES and seen[unit.block] > MAX_SENTENCES and unit.kind == "sentence":
            unit.rules.append("E6")
    info_marks(units)
    excluded = 0
    for unit in units:
        allowed = set().union(*(markers.get(n, set()) for n in unit.lines))
        for rule in [r for r in unit.rules + unit.info if r in allowed]:
            (unit.rules if rule in unit.rules else unit.info).remove(rule)
            unit.excluded.append(rule)
            excluded += 1
    return Doc(path, units, excluded, False)


def ending(text):
    return re.sub(r"[\s.!?:\"'”’)\]」』…]+$", "", strip_parens(text))


def info_marks(units):
    sentences = [u for u in units if u.kind == "sentence"]
    kinds = {}
    for unit in sentences:
        end = ending(unit.text)
        kinds[id(unit)] = "polite" if POLITE_END.search(end) else "plain" if DIRECTIVE_END.search(end) else None
    tally = Counter(k for k in kinds.values() if k)
    if len(tally) == 2:
        minority = min(tally, key=tally.get)
        for unit in sentences:
            if kinds[id(unit)] == minority:
                unit.info.append("I1")
    firsts = {}
    for unit in sentences:
        firsts.setdefault(unit.block, unit)
    for unit in firsts.values():
        if re.match(r"^(IMPORTANT|중요)\s*:", unit.text):
            end = ending(unit.text)
            if not DIRECTIVE_END.search(end) or DESCRIPTIVE_END.search(end):
                unit.info.append("I2")


# ── 대상·기준선·diff ─────────────────────────────────────────

def git(root, *arguments, check=True):
    result = subprocess.run(["git", "-C", str(root), *arguments], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip())
    return result


def targets(root, files):
    if files:
        out = []
        for name in files:
            path = Path(name)
            path = path if path.is_absolute() else root / path
            if not path.is_file():
                raise SystemExit(usage_error(f"없는 파일: {name}"))
            out.append(path)
        return [rel(root, p) for p in out]
    seen, out = set(), []
    for pattern in TARGET_GLOBS:
        for path in sorted(root.glob(pattern)):
            name = rel(root, path)
            # 링크를 거친 자리(.claude/skills/djcrate → skills/djcrate)는 빼고 실제 자리 이름으로 한 번만 센다
            if not path.is_file() or path.resolve() != root / name or name in seen:
                continue
            seen.add(name)
            out.append(name)
    return out


def rel(root, path):
    path = Path(path)
    try:
        return (path if path.is_absolute() else Path.cwd() / path).relative_to(root).as_posix()
    except ValueError:
        return path.as_posix()


def usage_error(message):
    print(f"check-prose: {message}", file=sys.stderr)
    return 2


def resolve_base(root, base):
    """기준 rev. 주면 그대로(트리 해시도 된다), 없으면 scripts/check.sh --changed와 같은 규칙(dev와의 merge-base)."""
    if base is not None:
        if git(root, "rev-parse", "--verify", "--quiet", base + "^{tree}", check=False).returncode != 0:
            return None, f"기준을 찾지 못했습니다: {base}"
        return base, None
    if git(root, "rev-parse", "--git-dir", check=False).returncode != 0:
        return None, None
    for candidate in ("dev", "origin/dev", "main"):
        result = git(root, "merge-base", "HEAD", candidate, check=False)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip(), None
    return None, None


def changed_lines(root, base, paths):
    """기준 대비 작업 트리(스테이지·추적 안 된 파일 포함)에서 더하거나 고친 줄."""
    changed = {}
    # 접두사를 고정한다(사용자 설정 diff.noprefix·mnemonicPrefix가 바꾼다). 파일 머리는 hunk 앞에서만 읽는다
    # (-U0에서 `++`로 시작하는 본문 줄을 더하면 `+++ …`로 찍힌다).
    diff = git(root, "diff", "-U0", "--no-color", "--no-ext-diff", "-M", "--src-prefix=a/", "--dst-prefix=b/",
               base, "--", *paths).stdout
    current, in_header = None, False
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            current, in_header = None, True
        elif in_header and line.startswith("+++ "):
            name = line[4:]
            current = name[2:] if name.startswith("b/") else None
            if current:
                changed.setdefault(current, set())
        elif line.startswith("@@"):
            in_header = False
            if current:
                found = re.search(r"\+(\d+)(?:,(\d+))?", line)
                begin, count = int(found.group(1)), int(found.group(2) or "1")
                changed[current].update(range(begin, begin + count))
    # 추적 안 된 파일: 기준에 같은 경로가 있으면(작업 트리 전체를 담은 트리 해시 기준) 그 내용과 비교한다
    others = git(root, "ls-files", "--others", "--exclude-standard", "--", *paths).stdout.splitlines()
    for name in others:
        text = (root / name).read_text(encoding="utf-8", errors="replace")
        old = git(root, "show", f"{base}:{name}", check=False)
        if old.returncode != 0:
            changed[name] = set(range(1, text.count("\n") + 2))
            continue
        lines = set()
        matcher = difflib.SequenceMatcher(None, old.stdout.splitlines(), text.splitlines(), autojunk=False)
        for tag, _, _, begin, end in matcher.get_opcodes():
            if tag in ("replace", "insert"):
                lines.update(range(begin + 1, end + 1))
        changed[name] = lines
    return changed


def read_baseline(path):
    values = {}
    if not path.is_file():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        fields = dict(part.split("=", 1) for part in parts[1:] if "=" in part)
        values[parts[0]] = (float(fields.get("A", "0")), float(fields.get("B", "100")))
    return values


BASELINE_HEAD = """# scripts/check-prose.py 기준선: 문서마다 A(위반 0인 문장 %)와 B(100어절당 위반 수).
# A가 이 값 아래로, B가 이 값 위로 가면 실패한다. 좋아지면 `python3 scripts/check-prose.py --write-baseline`으로 고친다
# (나빠진 값은 적지 않는다). A ≥ 80%인 문서는 A를 80으로 둔다. 손으로 값을 나쁘게 고치지 않는다.
"""


def write_baseline(path, values):
    body = "".join(f"{name}\tA={a:.1f}\tB={b:.1f}\n" for name, (a, b) in sorted(values.items()))
    path.write_text(BASELINE_HEAD + body, encoding="utf-8")


def pinned(a):
    return min(round(a, 1), GOAL)


# ── 출력 ──────────────────────────────────────────────────────

def quote(unit):
    text = unit.raw.replace("\n", " ")
    return text[:40] + ("…" if len(text) > 40 else "")


def violation_line(mark, name, unit, rule):
    hint = f" ({unit.hint[rule]})" if rule in unit.hint else ""
    return f"{mark} {name}:{unit.line}: {rule} {NAMES[rule]} — \"{quote(unit)}\"{hint}"


def number(value):
    return f"{value:.1f}"


def table(items, morph):
    head = ["문서", "문장", "어절", "A", "A'", "B", "B'"] + JUDGED + ["표·영어", "예외"]
    rows = ["| " + " | ".join(head) + " |", "|---" + "|--:" * (len(head) - 1) + "|"]
    for m in items + [combine(items)]:
        name = f"**{m['path']}**" if m["path"] == "전체" else m["path"]
        if m.get("off"):
            rows.append(f"| {name} | 뺌(prose: off) |" + " |" * (len(head) - 2))
            continue
        cells = [name, str(m["sentences"]), str(m["words"]), number(m["A"]), number(m["A2"]), number(m["B"]),
                 number(m["B2"])]
        cells += ["—" if rule == "W3" and not morph else str(m["counts"].get(rule, 0)) for rule in JUDGED]
        cells += [str(m["other"]), str(m["excluded"])]
        rows.append("| " + " | ".join(cells) + " |")
    return "\n".join(rows)


# ── 정보 보존 ─────────────────────────────────────────────────

def read_source(root, name):
    path = Path(name)
    if not path.is_absolute():
        path = root / path
    if path.is_file():
        return path.read_text(encoding="utf-8")
    if ":" in name:
        result = git(root, "show", name, check=False)
        if result.returncode == 0:
            return result.stdout
    raise SystemExit(usage_error(f"읽을 수 없는 파일: {name}"))


def facts(text):
    """숫자·식별자(인라인 코드와 코드 블록 줄)·이슈 번호·부정어 수."""
    code_lines, prose, fence = [], [], None
    for line in text.split("\n"):
        found = FENCE.match(line)
        if found:
            fence = None if fence == found.group(1) else (fence or found.group(1))
            continue
        (code_lines if fence else prose).append(line)
    prose_text = "\n".join(prose)
    identifiers = [m.strip("`").strip() for m in INLINE_CODE.findall(prose_text)]
    bare = INLINE_CODE.sub(" ", prose_text)
    bare = re.sub(r"^\s*(?:[-*+]|\d+[.)])\s+", " ", bare, flags=re.M)
    bare = re.sub(r"<!--.*?-->", " ", bare, flags=re.S)
    bare = URL.sub(" ", bare)
    issues = re.findall(r"(?<![\w&/])#\d+\b", bare)
    bare = re.sub(r"(?<![\w&/])#\d+\b", " ", bare)
    numbers = re.findall(r"(?<![A-Za-z_\d.])\d+(?:[.,:]\d+)*", bare)
    return {"숫자": Counter(numbers), "식별자": Counter(identifiers),
            "코드 블록 줄": Counter(line.strip() for line in code_lines if line.strip()),
            "이슈 번호": Counter(issues), "부정어": len(NEGATION.findall(bare))}


def preserve(root, old_names, new_names):
    old = [facts(read_source(root, name)) for name in old_names]
    new = [facts(read_source(root, name)) for name in new_names]
    lost = []
    for kind in ("숫자", "식별자", "코드 블록 줄", "이슈 번호"):
        missing = sum((f[kind] for f in old), Counter()) - sum((f[kind] for f in new), Counter())
        for item, count in sorted(missing.items()):
            lost.append(f"  {kind}: {'`' + item + '`' if kind == '식별자' else item}" + (f" ×{count}" if count > 1 else ""))
    before, after = sum(f["부정어"] for f in old), sum(f["부정어"] for f in new)
    if after < before:
        lost.append(f"  부정어(않·없·못·금지·말고·아니·안): {before}개 → {after}개. 금지·부정 문장이 빠졌는지 보세요")
    if lost:
        print("빠진 것(옛 글에 있고 새 글에 없음. 뜻이 그대로인지 사람이 확인한다):")
        print("\n".join(lost))
        return 1
    print(f"✔ 정보 보존: 숫자·식별자·이슈 번호가 모두 남았고 부정어 {before}개 → {after}개")
    return 0


# ── 실행 ──────────────────────────────────────────────────────

class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        print(f"check-prose: {message}", file=sys.stderr)
        sys.exit(2)


def main(argv):
    parser = Parser(description="문서 문장 규칙(간결 기술 한국어) 검사", add_help=True)
    parser.add_argument("--root", default=None, help="저장소 폴더(시험용)")
    parser.add_argument("--files", nargs="+", help="대상 파일(없으면 정해진 문서 전체)")
    parser.add_argument("--base", help="diff 규칙의 기준 rev(트리 해시도 된다). 없으면 dev와의 merge-base")
    parser.add_argument("--no-diff", action="store_true", help="더한 줄 규칙을 보지 않는다(기준선만)")
    parser.add_argument("--report", action="store_true", help="표만 내고 늘 종료 코드 0")
    parser.add_argument("--all", action="store_true", help="고치지 않은 줄의 위반도 모두 줄로 낸다")
    parser.add_argument("--info", action="store_true", help="정보 규칙(I1~I3) 줄도 낸다(--all과 함께)")
    parser.add_argument("--morph", action="store_true", help="kiwipiepy가 있으면 명사 묶음(W3)도 본다")
    parser.add_argument("--write-baseline", action="store_true", help="좋아진 값을 기준선에 적는다")
    parser.add_argument("--preserve", nargs="+", metavar="옛", help="고쳐 쓰기 전 파일(<rev>:<경로>도 된다)")
    parser.add_argument("--to", nargs="+", metavar="새", help="--preserve와 함께: 고쳐 쓴 뒤 파일")
    args = parser.parse_args(argv)
    root = Path(args.root).resolve() if args.root else ROOT
    if args.preserve or args.to:
        if not (args.preserve and args.to):
            return usage_error("--preserve <옛 파일…> --to <새 파일…>를 함께 주세요")
        return preserve(root, args.preserve, args.to)
    if args.base is not None and args.no_diff:
        return usage_error("--base와 --no-diff는 함께 쓸 수 없습니다")

    terms = load_terms(root / TERMS_FILE)
    morph, notes = None, []
    if args.morph:
        try:
            morph = Morph(terms)
        except ImportError:
            notes.append("kiwipiepy가 없어 명사 묶음(W3)은 판정하지 않았습니다(pip install kiwipiepy)")
    names = targets(root, args.files)
    docs = [analyze((root / name).read_text(encoding="utf-8"), name, terms, morph) for name in names]
    items = [d.metrics() for d in docs]
    judged = [d.metrics(skip=("W3",)) for d in docs] if morph else items
    if args.report:
        print(table(items, morph))
        for note in notes:
            print("· " + note)
        return 0

    failures, warnings, extra = [], [], []
    # 1. 더하거나 고친 줄에 걸친 문장의 오류
    base = None
    if not args.no_diff:
        base, problem = resolve_base(root, args.base)
        if problem:
            return usage_error(problem)
        if base is None:
            notes.append("기준 rev를 정하지 못해 더한 줄 규칙을 건너뜀(--base <rev>)")
        else:
            changed = changed_lines(root, base, names)
            for doc in docs:
                lines = changed.get(doc.path, set())
                if not lines:
                    continue
                touched_blocks = {u.block for u in doc.units if u.lines & lines}
                for unit in doc.units:
                    touched = unit.lines & lines
                    for rule in unit.rules:
                        # 긴 문단(E6)은 넘친 문장이 아니라 그 문단의 어느 줄을 고쳐도 본다
                        if touched or (rule == "E6" and unit.block in touched_blocks):
                            if rule.startswith("E"):
                                failures.append(violation_line("✘", doc.path, unit, rule))
                            elif touched:
                                warnings.append(violation_line("!", doc.path, unit, rule))
    if args.all:
        for doc in docs:
            for unit in doc.units:
                for rule in unit.rules + (unit.info if args.info else []):
                    line = violation_line("!" if rule[0] != "I" else "·", doc.path, unit, rule)
                    if line.replace("!", "✘", 1) not in failures and line not in warnings:
                        extra.append(line)
    # 2. 기준선
    baseline_path = root / BASELINE_FILE
    baseline = read_baseline(baseline_path)
    improved, updated = [], dict(baseline)
    for m in judged:
        name, a, b = m["path"], round(m["A"], 1), round(m["B"], 1)
        if m["off"]:
            updated.pop(name, None)
            continue
        if name not in baseline:
            if a < GOAL:
                failures.append(f"✘ {name}: 기준선에 없음 — A {a:.1f} < {GOAL:.1f}. 새 문서는 80% 이상으로 쓰세요"
                                f"(옛 문서를 옮겼으면 {BASELINE_FILE}의 그 줄 이름을 새 경로로 고칩니다)")
            else:
                improved.append(f"{name}: 새 문서 A {a:.1f}, B {b:.1f}")
                updated[name] = (pinned(a), b)
            continue
        base_a, base_b = baseline[name]
        worse = []
        if a < base_a:
            worse.append(f"A {a:.1f} < {base_a:.1f}")
        if b > base_b:
            worse.append(f"B {b:.1f} > {base_b:.1f}")
        if worse:
            failures.append(f"✘ {name}: 기준선보다 나빠짐 — {', '.join(worse)}. 고친 문장을 규칙에 맞추세요"
                            "(--all --files로 위반 줄을 봅니다)")
        new_a, new_b = max(base_a, pinned(a)), min(base_b, b)
        if (new_a, new_b) != (base_a, base_b):
            improved.append(f"{name}: A {base_a:.1f} → {new_a:.1f}, B {base_b:.1f} → {new_b:.1f}")
            updated[name] = (new_a, new_b)
    if not args.files:
        for name in sorted(set(baseline) - {m["path"] for m in items}):
            improved.append(f"{name}: 대상에 없음(기준선에서 지움)")
            updated.pop(name)
    if args.write_baseline and updated != baseline:
        write_baseline(baseline_path, updated)
        notes.append(f"기준선을 고쳤습니다: {BASELINE_FILE} ({len(improved)}곳)")
    elif improved:
        notes.append("기준선보다 좋아짐 — `python3 scripts/check-prose.py --write-baseline`으로 고치세요: "
                     + "; ".join(improved[:8]) + (" …" if len(improved) > 8 else ""))

    for line in failures + warnings + extra:
        print(line)
    total = combine(items)
    if failures:
        print(table(items, morph))
    for note in notes:
        print("· " + note)
    if failures:
        print(f"✘ check-prose: 실패 {len(failures)}개(문서 {len(items)}개, 문장 {total['sentences']}개, "
              f"A {total['A']:.1f}%, B {total['B']:.1f})")
        return 1
    print(f"✔ check-prose: 문서 {len(items)}개, 문장 {total['sentences']}개, A {total['A']:.1f}%, "
          f"B {total['B']:.1f}, 예외 {total['excluded']}" + ("" if base or args.no_diff else ", 더한 줄 규칙 건너뜀")
          + (f", 경고 {len(warnings)}" if warnings else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
