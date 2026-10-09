#!/usr/bin/env python3
"""지침·규칙·스킬 문서가 저장소와 어긋나지 않았는지 몇 초 안에 본다(#167 하네스, 낡은 지침 잡기).

본다:
  1. 지침(AGENTS.md·CLAUDE.md·.claude/rules·.claude/skills·.claude/agents)의 `…`·코드 블록 안 저장소 경로
     (Sources/·Tests/·scripts/·docs/·.claude/·.github/·skills/ 등)가 실제로 있는지. 글롭(*)은 파일 하나 이상에 맞아야 한다
  2. 지침·docs의 `djc <명령>`·`djc lab <명령>`(`.build/debug/djc …`처럼 경로를 붙인 것 포함)이 Sources/djc의 명령 등록(Command("…"))에 있는지
  3. .claude/rules/*.md 머리(frontmatter)가 읽히고 paths 글롭마다 파일이 하나 이상 맞는지(머리가 깨지면 규칙이 늘 실린다)
  4. .claude/skills/*/SKILL.md 머리(name = 폴더 이름, description)와 본문 500줄 미만, .claude/agents/*.md 머리(name·description)
  5. 지침·docs/*.md·README.md·CONTRIBUTING.md의 상대 링크([글](경로#제목))가 있는 파일·제목을 가리키는지
  6. AGENTS.md 크기: 16KiB 넘으면 실패, 12KiB 넘으면 경고

통과하면 아무것도 찍지 않는다(경고만 있으면 경고 줄만). 실패는 `✘ 파일:줄: 이유`와 종료 코드 1.
사용: scripts/check-docs.py [--root <저장소 폴더>]
"""
import re
import sys
from pathlib import Path

AGENTS_FAIL_BYTES = 16 * 1024
AGENTS_WARN_BYTES = 12 * 1024
SKILL_MAX_LINES = 500

# 지침에서 저장소 경로로 보는 머리. 이 밖(~/Library/…, share/PIONEER/…, .build/…)은 저장소 경로가 아니라 보지 않는다.
PATH_HEADS = ("Sources/", "Tests/", "scripts/", "docs/", ".claude/", ".github/", "skills/", "Assets/", ".agents/")
ROOT_FILES = ("AGENTS.md", "CLAUDE.md", "README.md", "CONTRIBUTING.md", "Package.swift", "Package.resolved",
              "THIRD_PARTY_NOTICES.md", "LICENSE")
# 없을 수도 있는 파일: 외부 패키지가 생기면 SwiftPM이 만든다(--changed 넓히기 조건으로 적는다)
OPTIONAL = {"Package.resolved"}
# 명령 등록 밖이지만 djc가 받는 이름
EXTRA_COMMANDS = {"lab", "compat", "draft"}

PATH_TOKEN = re.compile(r"(?<![\w./~-])((?:%s)[^\s`'\"()\[\]<>{}|,;]*|(?:%s)(?![\w.]))" % (
    "|".join(re.escape(h) for h in PATH_HEADS), "|".join(re.escape(f) for f in ROOT_FILES)))
# `djc …`, `.build/debug/djc …`, `./.build/release/djc …`처럼 경로를 붙여 부른 것도 본다
DJC_COMMAND = re.compile(r"(?<![\w./$-])(?:[\w.-]*/)*djc[ \t]+(lab[ \t]+)?([a-z][a-z0-9-]*)")
LINK = re.compile(r"(?<!\!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)|\!\[[^\]]*\]\(([^)\s]+)\)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
FENCE = re.compile(r"^\s*(```|~~~)")


class Report:
    def __init__(self, root):
        self.root = root
        self.failures = []
        self.warnings = []

    def fail(self, path, line, message):
        self.failures.append(f"✘ {self.rel(path)}:{line}: {message}")

    def warn(self, path, message):
        self.warnings.append(f"! {self.rel(path)}: {message}")

    def rel(self, path):
        try:
            return Path(path).relative_to(self.root).as_posix()
        except ValueError:
            return str(path)


def guidance_files(root):
    files = [root / "AGENTS.md", root / "CLAUDE.md"]
    files += sorted((root / ".claude/rules").glob("*.md"))
    files += sorted((root / ".claude/skills").glob("*/*.md"))
    files += sorted((root / ".claude/agents").glob("*.md"))
    return [f for f in files if f.is_file()]


def doc_files(root):
    files = sorted((root / "docs").glob("*.md")) + [root / "README.md", root / "CONTRIBUTING.md"]
    return [f for f in files if f.is_file()]


def expand_braces(pattern):
    match = re.search(r"\{([^{}]*)\}", pattern)
    if not match:
        return [pattern]
    head, tail = pattern[:match.start()], pattern[match.end():]
    return [p for option in match.group(1).split(",") for p in expand_braces(head + option + tail)]


def glob_matches(root, pattern):
    for expanded in expand_braces(pattern.rstrip("/")):
        if any(True for _ in root.glob(expanded)):
            return True
    return False


def path_exists(root, token):
    if any(ch in token for ch in "*?[{"):
        return glob_matches(root, token)
    return (root / token.rstrip("/")).exists()


def clean_path(token):
    token = re.sub(r":\d+(?:-\d+)?$", "", token)  # 파일:줄
    token = re.sub(r"#.*$", "", token)              # 링크 앵커
    return token.rstrip(".,:;…")


def text_spans(text):
    """`…` 코드 조각과 코드 블록 줄을 (줄 번호, 글) 로 낸다."""
    in_block = False
    for number, line in enumerate(text.splitlines(), 1):
        if FENCE.match(line):
            in_block = not in_block
            continue
        if in_block:
            yield number, line
            continue
        for match in re.finditer(r"`([^`]+)`", line):
            yield number, match.group(1)


def check_paths(report, path, text):
    root = report.root
    for number, span in text_spans(text):
        for match in PATH_TOKEN.finditer(span):
            token = clean_path(match.group(1))
            if not token or "<" in token or "$" in token or "…" in token:
                continue
            if token in OPTIONAL:
                continue
            if not path_exists(root, token):
                report.fail(path, number, f"없는 저장소 경로: {token}")


def registered_commands(root):
    names = set(EXTRA_COMMANDS)
    for source in (root / "Sources/djc").rglob("*.swift"):
        names.update(re.findall(r'Command\(\s*"([a-z0-9][a-z0-9-]*)"', source.read_text(encoding="utf-8")))
    return names


def check_djc(report, path, text, commands):
    for number, span in text_spans(text):
        for match in DJC_COMMAND.finditer(span):
            name = match.group(2)
            if name not in commands:
                where = "djc lab " if match.group(1) else "djc "
                report.fail(path, number, f"등록되지 않은 명령: {where}{name}")


def frontmatter(text):
    """(머리 줄 목록, 본문 시작 줄 번호) 또는 머리가 없으면 (None, 1). 닫는 ---가 없으면 ValueError."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None, 1
    for index in range(1, len(lines)):
        if lines[index].strip() == "---":
            return lines[1:index], index + 2
    raise ValueError("머리(frontmatter)를 닫는 --- 가 없습니다")


def parse_simple_yaml(lines):
    """규칙·스킬·에이전트 머리에 쓰는 만큼만 읽는다: `키: 값`, 그 아래 `  - 항목` 목록."""
    data, key = {}, None
    for raw in lines:
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        item = re.match(r"^\s+-\s+(.*)$", raw)
        if item and key is not None:
            if not isinstance(data.get(key), list):
                if data.get(key) not in (None, ""):
                    raise ValueError(f"{key}: 값과 목록을 함께 썼습니다")
                data[key] = []
            data[key].append(unquote(item.group(1)))
            continue
        pair = re.match(r"^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$", raw)
        if not pair:
            raise ValueError(f"읽을 수 없는 머리 줄: {raw.strip()}")
        key, value = pair.group(1), pair.group(2).strip()
        data[key] = unquote(value) if value else ""
    return data


def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def check_rule(report, path, text):
    try:
        head, _ = frontmatter(text)
        if head is None:
            report.fail(path, 1, "paths 머리가 없습니다(머리 없는 규칙은 늘 실린다. 늘 실을 것은 AGENTS.md에 둔다)")
            return
        data = parse_simple_yaml(head)
    except ValueError as error:
        report.fail(path, 1, f"머리를 읽을 수 없습니다({error}). 깨진 머리의 규칙은 늘 실린다")
        return
    paths = data.get("paths")
    if isinstance(paths, str):
        paths = [p.strip() for p in paths.split(",") if p.strip()]
    if not paths:
        report.fail(path, 1, "paths 목록이 비었습니다")
        return
    for pattern in paths:
        if not glob_matches(report.root, pattern):
            report.fail(path, 1, f"paths 글롭에 맞는 파일이 없습니다: {pattern}")


def check_skill(report, path, text):
    try:
        head, body_start = frontmatter(text)
        data = parse_simple_yaml(head) if head is not None else None
    except ValueError as error:
        report.fail(path, 1, f"스킬 머리를 읽을 수 없습니다({error})")
        return
    if data is None:
        report.fail(path, 1, "스킬 머리(name·description)가 없습니다")
        return
    folder = path.parent.name
    if data.get("name") and data["name"] != folder:
        report.fail(path, 1, f"name({data['name']})이 폴더 이름({folder})과 다릅니다")
    if not data.get("description"):
        report.fail(path, 1, "description이 없습니다(모델이 언제 쓸지 고르는 글)")
    body_lines = len(text.splitlines()) - body_start + 1
    if body_lines >= SKILL_MAX_LINES:
        report.fail(path, body_start, f"본문이 {body_lines}줄입니다({SKILL_MAX_LINES}줄 미만으로, 자세한 것은 딸린 파일로)")


def check_agent(report, path, text):
    try:
        head, _ = frontmatter(text)
        data = parse_simple_yaml(head) if head is not None else None
    except ValueError as error:
        report.fail(path, 1, f"에이전트 머리를 읽을 수 없습니다({error})")
        return
    if not data or not data.get("name") or not data.get("description"):
        report.fail(path, 1, "에이전트 머리에 name·description이 있어야 합니다(없으면 조용히 건너뛴다)")


def slugify(heading):
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", heading)  # 링크는 글만
    text = text.replace("`", "").lower()
    text = "".join(ch for ch in text if ch.isalnum() or ch in " -_" or unicode_mark(ch))
    return text.replace(" ", "-")


def unicode_mark(ch):
    import unicodedata
    return unicodedata.category(ch).startswith("M")


def anchors(path, cache):
    if path not in cache:
        found, counts, in_block = set(), {}, False
        for line in path.read_text(encoding="utf-8").splitlines():
            if FENCE.match(line):
                in_block = not in_block
                continue
            heading = None if in_block else HEADING.match(line)
            if heading:
                slug = slugify(heading.group(2))
                count = counts.get(slug, 0)
                counts[slug] = count + 1
                found.add(slug if count == 0 else f"{slug}-{count}")
        cache[path] = found
    return cache[path]


def check_links(report, path, text, cache):
    in_block = False
    for number, line in enumerate(text.splitlines(), 1):
        if FENCE.match(line):
            in_block = not in_block
            continue
        if in_block:
            continue
        line = re.sub(r"`[^`]*`", "", line)
        for match in LINK.finditer(line):
            target = match.group(1) or match.group(2)
            if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("//"):
                continue  # https:, mailto:, t3-thread: 등
            file_part, _, anchor = target.partition("#")
            destination = path if not file_part else (path.parent / file_part)
            if not destination.exists():
                report.fail(path, number, f"링크가 없는 파일을 가리킵니다: {target}")
                continue
            if anchor and destination.suffix == ".md" and destination.is_file():
                if anchor not in anchors(destination.resolve(), cache):
                    report.fail(path, number, f"링크의 제목(#{anchor})이 {report.rel(destination.resolve())}에 없습니다")


def check_agents_size(report, root):
    path = root / "AGENTS.md"
    if not path.is_file():
        report.fail(path, 1, "AGENTS.md가 없습니다")
        return
    size = path.stat().st_size
    if size > AGENTS_FAIL_BYTES:
        report.fail(path, 1, f"{size}바이트입니다({AGENTS_FAIL_BYTES} 이하로. 자세한 것은 docs·경로 규칙·스킬로 옮긴다)")
    elif size > AGENTS_WARN_BYTES:
        report.warn(path, f"{size}바이트입니다(목표 {AGENTS_WARN_BYTES} 이하)")


def main(arguments):
    root = Path(__file__).resolve().parent.parent
    if arguments[:1] == ["--root"] and len(arguments) == 2:
        root = Path(arguments[1]).resolve()
    elif arguments:
        print("사용: scripts/check-docs.py [--root <저장소 폴더>]")
        return 2
    report = Report(root)
    commands = registered_commands(root) if (root / "Sources/djc").is_dir() else None
    cache = {}
    check_agents_size(report, root)
    claude = root / "CLAUDE.md"
    if claude.is_file():
        for number, line in enumerate(claude.read_text(encoding="utf-8").splitlines(), 1):
            imported = re.match(r"^@(\S+)", line.strip())
            if imported and not (root / imported.group(1)).exists():
                report.fail(claude, number, f"가져오는 파일이 없습니다: {imported.group(1)}")
    for path in guidance_files(root):
        text = path.read_text(encoding="utf-8")
        check_paths(report, path, text)
        if path.parent == root / ".claude/rules":
            check_rule(report, path, text)
        elif path.name == "SKILL.md":
            check_skill(report, path, text)
        elif path.parent == root / ".claude/agents":
            check_agent(report, path, text)
    for path in guidance_files(root) + doc_files(root):
        text = path.read_text(encoding="utf-8")
        if commands is not None:
            check_djc(report, path, text, commands)
        check_links(report, path, text, cache)
    for line in report.warnings:
        print(line)
    for line in report.failures:
        print(line)
    if report.failures:
        print(f"문서 검사: 실패 {len(report.failures)}건(scripts/check-docs.py)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
