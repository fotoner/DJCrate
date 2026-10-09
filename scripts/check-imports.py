#!/usr/bin/env python3
"""모듈 경계 규칙(#167 헥사고날 구조)을 소스에서 기계로 확인한다.

규칙:
  import         모듈(파일)마다 import해도 되는 프로젝트 모듈. 시스템 모듈(Foundation·SwiftUI 등)은 보지 않는다.
  api            핵심부(DJCDomain·DJCApplication)는 FileManager·ProcessInfo·UserDefaults·Bundle(타입 자체)·Date()·Date.now·UUID()·
                 Locale·TimeZone·Calendar.current를 직접 쓰지 않고, 타입 없이 쓴 암묵 멤버 .main·.current·.now도 쓰지 않는다
                 (시계·ID·환경·파일·번들은 포트·주입으로 받는다). 화면 상태(Observation·@Observable)도 두지 않는다(앱 화면 모델에).
                 주석·문자열 안은 보지 않는다.
  test-defaults  시험은 UserDefaults(suiteName:)을 직접 만들지 않고 TestDefaults(DJCTestKit)를 쓴다
                 (사용자 ~/Library/Preferences에 plist를 남기지 않게, adv4 T6).
  view-task      앱의 SwiftUI 뷰 파일(View를 채택한 타입이 든 파일)은 Task를 시작하지 않고(Task {…}·Task(…) {…}·Task.detached)
                 await하지 않는다. 화면 모델의 메서드를 부른다(MVVM, Ledger "뷰 본문에서 로직·Task 시작 금지").
                 허용: 수명 수식어 .task {…}·.task(id:) {…}의 본문이 `await 받는쪽.메서드(인자)` 하나뿐인 것(받는 쪽은 self가 아닌 값,
                 호출은 하나, 인자에 클로저·await 없음). 빚 목록에는 파일마다 "Task N곳"·"await N곳"으로 곳 수를 고정한다.

파일의 모듈은 Package.swift의 타깃 경로(swift package dump-package, .build/check-imports/에 캐시)로 정한다.
어느 타깃에도 속하지 않는 Swift 파일, ALLOWED에 규칙이 없는 타깃은 실패한다(폴더·타깃을 옮기고 이 검사에서 조용히 빠지지 않게).

지금 위반은 scripts/import-debt.txt(빚 목록)에 `파일<TAB>규칙<TAB>대상` 줄로 고정한다.
빚 목록 밖 위반이 있거나, 빚 목록의 항목이 이미 해소됐으면 실패한다(빚이 줄면 목록도 줄인다).

예외: 조립 지점은 파일 이름 목록(ASSEMBLY_FILES), 디버그 자가 테스트·실험 명령은 폴더와 허용 import 목록(BROAD_FOLDERS).
목록의 파일·폴더가 없거나, 폴더 예외가 허용한 모듈을 그 폴더의 어느 파일도 쓰지 않으면 실패한다(목록을 지금 쓰는 것으로 좁힌다).

사용: scripts/check-imports.py            검사
      scripts/check-imports.py --write-debt 지금 위반으로 빚 목록을 다시 쓴다
      scripts/check-imports.py --summary    규칙·대상별 빚 개수 표와 예외 목록(넓은 예외의 크기)
"""
import hashlib
import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEBT = ROOT / "scripts/import-debt.txt"

# 프로젝트 모듈 전부(이 밖의 import는 시스템·외부 모듈이라 보지 않는다). SQLCipher도 이 저장소가 고른 의존이라 본다.
INFRA = {"RekordboxKit", "DJCStorage", "DJCAnalysis", "DJCEnvironment"}
CORE = {"DJCDomain", "DJCApplication"}
EVERYTHING_BELOW_APP = CORE | INFRA | {"DJCAdapters"}
TEST_KITS = {"DJCTestKit", "RekordboxFixtures"}

# 모듈마다 import해도 되는 프로젝트 모듈(목표 구조, HEX-BRIEF "규칙").
ALLOWED = {
    "DJCDomain": set(),
    "DJCApplication": {"DJCDomain"},
    "DJCEnvironment": {"DJCDomain"},
    "RekordboxKit": {"DJCDomain", "DJCEnvironment", "SQLCipher"},
    "DJCStorage": {"DJCDomain", "DJCEnvironment", "RekordboxKit"},
    "DJCAnalysis": {"DJCDomain", "DJCEnvironment"},
    "DJCAdapters": EVERYTHING_BELOW_APP - {"DJCAdapters"},
    # 앱·CLI의 화면 모델·뷰·명령은 유스케이스와 도메인만. 조립 지점·자가 테스트·실험 명령은 아래 FILE_EXCEPTIONS.
    "DJCrate": {"DJCApplication", "DJCDomain"},
    "djc": {"DJCApplication", "DJCDomain"},
    "DJCrateExecutable": {"DJCrate"},
    "djcExecutable": {"djc"},
    # 시험 재료
    "DJCTestKit": {"DJCDomain"},
    "RekordboxFixtures": {"DJCDomain", "RekordboxKit", "SQLCipher", "DJCTestKit"},
    # 포트 시험 재료(가짜·공용 계약 함수): 유스케이스 시험과 어댑터 계약 시험이 함께 쓴다. 실제 구현·인프라를 모른다
    "PortTestKit": {"DJCApplication", "DJCDomain", "DJCTestKit"},
    # 시험 타깃: 시험하는 층과 그 아래 층, 재료. 유스케이스 시험은 가짜 포트와 DJCTestKit만(인프라 없이).
    "DJCDomainTests": {"DJCDomain", "DJCEnvironment", "DJCTestKit"},
    "RekordboxKitTests": {"RekordboxKit", "DJCDomain", "DJCEnvironment", "SQLCipher"} | TEST_KITS,
    "DJCAnalysisTests": {"DJCAnalysis", "DJCDomain", "DJCEnvironment", "DJCTestKit"},
    "DJCStorageTests": {"DJCStorage", "DJCApplication", "DJCAnalysis", "RekordboxKit", "DJCDomain"} | TEST_KITS,
    "DJCApplicationTests": {"DJCApplication", "DJCDomain", "DJCTestKit", "PortTestKit"},
    "DJCAdaptersTests": EVERYTHING_BELOW_APP | TEST_KITS | {"PortTestKit"},
    "djcTests": EVERYTHING_BELOW_APP | {"djc"} | TEST_KITS,
    "DJCrateTests": EVERYTHING_BELOW_APP | {"DJCrate"} | TEST_KITS,
}
PROJECT_MODULES = set(ALLOWED) | {"SQLCipher"}

# 예외 ①: 조립 지점(실제 구현을 고르고 잇는 곳). 파일 이름으로만 둔다(이름이 비슷한 새 파일이 슬쩍 예외가 되지 않게).
# 모든 아래 층을 import해도 되고, 조립 밖 로직은 두지 않는다.
APP_WIDE = EVERYTHING_BELOW_APP
ASSEMBLY_FILES = [
    "Sources/DJCrate/App/AppComposition.swift",
    "Sources/DJCrate/App/AppComposition+Usb.swift",
    "Sources/djc/CLIComposition.swift",
    "Sources/djc/CLIComposition+Usb.swift",
    # CLI 쓰기 명령이 고른 대상(사본·라이브)과 그 관문을 푼다
    "Sources/djc/Commands/CLIWriteTarget.swift",
]
# 예외 ②(넓다): 디버그 자가 테스트(앱 Diagnostics/, 쓰기가 있는 파일은 #if DEBUG)·실험 명령(CLI Lab/). 폴더 전체가 예외라
# 더 허용하는 import는 지금 쓰는 것만 적는다(아무도 쓰지 않게 되면 실패해 목록을 줄인다). 크기는 --summary가 보인다.
BROAD_FOLDERS = {
    "Sources/DJCrate/Diagnostics": {"DJCAdapters", "DJCAnalysis", "DJCStorage", "RekordboxKit"},
    "Sources/djc/Lab": {"DJCAdapters", "DJCAnalysis", "DJCEnvironment", "DJCStorage", "RekordboxKit"},
}

# 핵심부가 직접 쓰면 안 되는 API(대상 이름, 정규식)
FORBIDDEN_API = [
    ("FileManager", re.compile(r"\bFileManager\b")),
    ("ProcessInfo", re.compile(r"\bProcessInfo\b")),
    ("UserDefaults", re.compile(r"\bUserDefaults\b")),
    # 번들(리소스·문구 카탈로그)을 고르는 일은 앱·CLI가 한다. Bundle.main뿐 아니라 Mutex<Bundle>(.main)처럼 이름이 빠지는 꼴도 잡게 타입 자체를 본다
    ("Bundle", re.compile(r"\bBundle\b")),
    ("Date()", re.compile(r"\bDate\s*(?:\.\s*init\s*)?\(\s*\)")),
    ("Date.now", re.compile(r"\bDate\s*\.\s*now\b")),
    ("UUID()", re.compile(r"\bUUID\s*(?:\.\s*init\s*)?\(\s*\)")),
    ("Locale·TimeZone·Calendar.current", re.compile(r"\b(?:Locale|TimeZone|Calendar)\s*\.\s*(?:current|autoupdatingCurrent)\b")),
    # 화면 상태(관찰)는 앱 화면 모델에 둔다. 핵심부는 값·결과·이벤트를 돌려준다
    ("Observation", re.compile(r"\bimport\s+Observation\b|@Observable\b")),
]
IMPLICIT_API = ".main·.current·.now(암묵 멤버)"
# 타입 없이 쓴 환경 멤버(Mutex<Locale>(.current), locale: Locale = .current, queue: .main). 앞이 식의 끝이면 멤버 접근이다
IMPLICIT_MEMBER = re.compile(r"\.\s*(?:main|current|autoupdatingCurrent|now)\b")
KEYWORDS_BEFORE_VALUE = {"return", "case", "in", "try", "await", "throw", "else", "is", "as", "where", "if", "guard", "while", "switch",
                         "yield", "then", "repeat", "defer", "do"}
# 뷰 규칙(view-task): 앱 파일 중 View를 채택한 타입이 든 것. NSViewRepresentable·ViewModifier는 낱말 경계로 빠진다
VIEW_MODULE = "DJCrate"
VIEW_DECLARATION = re.compile(r"\b(?:struct|class|enum|extension)\s+[A-Za-z_][\w.]*(?:<[^>{]*>)?\s*:\s*[^{]*?\bView\b")
TASK_START = re.compile(r"\bTask\s*(?:\.\s*detached\s*)?(?:\([^(){}]*\)\s*)?\{")
AWAIT = re.compile(r"\bawait\b")
TASK_MODIFIER = re.compile(r"\.task\s*(?=[({])")
MODEL_CALL_HEAD = re.compile(r"\s*await\s+(?!self\b)[A-Za-z_]\w*(?:\s*\??\.\s*[A-Za-z_]\w*)+\s*(?=\()")
COUNTED = re.compile(r"^(.*) (\d+)곳$")
TEST_DEFAULTS_HELPER = "Tests/Support/Kit/TestDefaults.swift"
TEST_DEFAULTS = re.compile(r"\bUserDefaults\s*\(\s*suiteName\s*:")

IMPORT = re.compile(
    r"^[ \t]*(?:@[A-Za-z_]+(?:\([^)]*\))?[ \t]+)*(?:(?:public|package|internal|fileprivate|private)[ \t]+)?"
    r"import[ \t]+(?:(?:typealias|struct|class|enum|protocol|let|var|func)[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)",
    re.MULTILINE,
)


class PackageError(Exception):
    pass


def package_targets(root=ROOT):
    """타깃 이름 → (경로, 제외 경로들). swift package dump-package 결과를 Package.swift 내용 해시로 캐시한다."""
    manifest = root / "Package.swift"
    if not manifest.is_file():
        raise PackageError("Package.swift가 없습니다")
    cached = root / ".build/check-imports" / f"package-{hashlib.sha256(manifest.read_bytes()).hexdigest()[:16]}.json"
    if cached.exists():
        data = json.loads(cached.read_text())
    else:
        try:
            result = subprocess.run(["swift", "package", "dump-package"], cwd=root, capture_output=True, text=True, timeout=120)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise PackageError(f"swift package dump-package를 실행하지 못했습니다: {error}") from error
        if result.returncode != 0:
            raise PackageError("swift package dump-package 실패: " + result.stderr.strip()[-300:])
        data = json.loads(result.stdout)
        cached.parent.mkdir(parents=True, exist_ok=True)
        for old in cached.parent.glob("package-*.json"):
            old.unlink(missing_ok=True)
        temporary = cached.with_suffix(f".{os.getpid()}.tmp")
        temporary.write_text(json.dumps(data))
        temporary.replace(cached)
    targets = {}
    for target in data["targets"]:
        if target["type"] in ("binary", "plugin"):
            continue
        path = (target.get("path") or ("Tests/" if target["type"] == "test" else "Sources/") + target["name"]).rstrip("/")
        targets[target["name"]] = (path, [f"{path}/{e}".rstrip("/") for e in target.get("exclude", [])])
    return targets


def module_of(relative, targets):
    """그 파일을 컴파일하는 타깃(경로가 가장 길게 맞는 것). 없거나 제외한 파일이면 None."""
    best = None
    for name, (path, excluded) in targets.items():
        if relative.startswith(path + "/") and (best is None or len(path) > len(targets[best][0])):
            best = name
    if best is None or any(relative == e or relative.startswith(e + "/") for e in targets[best][1]):
        return None
    return best


def strip_comments_and_strings(text):
    """주석과 문자열 리터럴을 공백으로 바꾼다(줄 번호는 그대로). 문자열 보간 안의 코드도 문자열로 본다."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        elif c == '"' or (c == "#" and re.match(r'#+"', text[i:])):
            hashes = len(re.match(r"#*", text[i:]).group(0))
            start = i
            i += hashes
            triple = text.startswith('"""', i)
            quote = '"""' if triple else '"'
            i += len(quote)
            closing = quote + "#" * hashes
            while i < n:
                if hashes == 0 and text[i] == "\\":
                    i += 2
                    continue
                if text.startswith(closing, i):
                    i += len(closing)
                    break
                if not triple and text[i] == "\n":
                    break
                i += 1
            out.append(re.sub(r"[^\n]", " ", text[start:i]))
        else:
            out.append(c)
            i += 1
    return "".join(out)


def exception_of(relative):
    """그 파일이 받는 예외: (더 허용하는 모듈, 넓은 예외 폴더 또는 None)"""
    if relative in ASSEMBLY_FILES:
        return APP_WIDE, None
    for folder, modules in BROAD_FOLDERS.items():
        if relative.startswith(folder + "/"):
            return modules, folder
    return set(), None


def implicit_members(code):
    """타입 없이 쓴 .main·.current·.now(암묵 멤버식)가 있는지. 앞이 이름·닫는 괄호·옵셔널 연쇄·범위 연산자면 멤버 접근으로 본다."""
    for match in IMPLICIT_MEMBER.finditer(code):
        j = match.start() - 1
        while j >= 0 and code[j] in " \t\r\n":
            j -= 1
        if j < 0:
            return True
        previous = code[j]
        if previous.isalnum() or previous == "_":
            k = j
            while k >= 0 and (code[k].isalnum() or code[k] == "_"):
                k -= 1
            if code[k + 1:j + 1] in KEYWORDS_BEFORE_VALUE:
                return True
            continue
        if previous in ")]>.":
            continue
        if previous in "?!" and j == match.start() - 1:
            continue
        return True
    return False


def closing(code, start, opening, closer):
    """code[start]가 여는 괄호일 때 짝이 맞는 닫는 괄호 다음 위치(없으면 -1)"""
    depth = 0
    for index in range(start, len(code)):
        if code[index] == opening:
            depth += 1
        elif code[index] == closer:
            depth -= 1
            if depth == 0:
                return index + 1
    return -1


def single_model_call(body):
    """수식어 본문이 `await 받는쪽.메서드(인자)` 하나뿐인지(인자에 클로저·await 없음)"""
    head = MODEL_CALL_HEAD.match(body)
    if not head:
        return False
    end = closing(body, head.end(), "(", ")")
    if end < 0:
        return False
    arguments = body[head.end():end]
    return "{" not in arguments and not AWAIT.search(arguments) and not body[end:].strip()


def view_task_counts(code):
    """뷰 파일에서 허용한 .task 수식어 밖의 Task 시작·await 수"""
    allowed = []
    for modifier in TASK_MODIFIER.finditer(code):
        index = modifier.end()
        if code[index] == "(":
            index = closing(code, index, "(", ")")
            if index < 0:
                continue
            while index < len(code) and code[index] in " \t\r\n":
                index += 1
        if index >= len(code) or code[index] != "{":
            continue
        end = closing(code, index, "{", "}")
        if end > 0 and single_model_call(code[index + 1:end - 1]):
            allowed.append((index, end))

    def outside(position):
        return not any(start <= position < end for start, end in allowed)

    tasks = sum(1 for match in TASK_START.finditer(code) if outside(match.start()))
    awaits = sum(1 for match in AWAIT.finditer(code) if outside(match.start()))
    return tasks, awaits


def violations(root=ROOT):
    found, unknown, orphans, problems = set(), set(), set(), []
    targets = package_targets(root)
    files = sorted(p for top in ("Sources", "Tests") for p in (root / top).rglob("*.swift"))
    used_in_folder = {folder: set() for folder in BROAD_FOLDERS}
    files_in_folder = {folder: 0 for folder in BROAD_FOLDERS}
    for path in files:
        relative = path.relative_to(root).as_posix()
        module = module_of(relative, targets)
        if module is None:
            orphans.add(relative)
            continue
        if module not in ALLOWED:
            unknown.add(module)
            continue
        code = strip_comments_and_strings(path.read_text(encoding="utf-8"))
        extra, folder = exception_of(relative)
        allowed = ALLOWED[module] | {module}
        imported_modules = [name for name in IMPORT.findall(code) if name in PROJECT_MODULES]
        if folder:
            files_in_folder[folder] += 1
            used_in_folder[folder] |= set(imported_modules) - allowed
        allowed = allowed | extra
        for imported in imported_modules:
            if imported not in allowed:
                found.add((relative, "import", imported))
        if module in CORE:
            for name, pattern in FORBIDDEN_API:
                if pattern.search(code):
                    found.add((relative, "api", name))
            if implicit_members(code):
                found.add((relative, "api", IMPLICIT_API))
        if module == VIEW_MODULE and VIEW_DECLARATION.search(code):
            tasks, awaits = view_task_counts(code)
            if tasks:
                found.add((relative, "view-task", f"Task {tasks}곳"))
            if awaits:
                found.add((relative, "view-task", f"await {awaits}곳"))
        if relative.startswith("Tests/") and relative != TEST_DEFAULTS_HELPER and TEST_DEFAULTS.search(code):
            found.add((relative, "test-defaults", "UserDefaults(suiteName:)"))
    # 예외 목록을 지금 모양에 맞춘다(타깃이 있는 자리만 본다)
    for relative in ASSEMBLY_FILES:
        if module_of(relative, targets) is not None and not (root / relative).is_file():
            problems.append(f"예외 목록의 파일이 없습니다: {relative}. 지웠거나 옮겼으면 scripts/check-imports.py의 ASSEMBLY_FILES를 고치세요")
    for folder, modules in BROAD_FOLDERS.items():
        if module_of(folder + "/_.swift", targets) is None:
            continue
        if not files_in_folder[folder]:
            problems.append(f"예외 목록의 폴더에 Swift 파일이 없습니다: {folder}/. scripts/check-imports.py의 BROAD_FOLDERS를 고치세요")
        elif unused := sorted(modules - used_in_folder[folder]):
            problems.append(f"예외가 쓰지 않는 모듈을 허용합니다: {folder}/ {', '.join(unused)}. "
                            "scripts/check-imports.py의 BROAD_FOLDERS에서 빼세요")
    return found, unknown, orphans, problems


def read_debt():
    if not DEBT.exists():
        return set()
    entries = set()
    for line in DEBT.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3:
            sys.exit(f"✘ 빚 목록 줄 모양이 틀렸습니다(파일<TAB>규칙<TAB>대상): {line}")
        entries.add(tuple(fields))
    return entries


def counted(entry):
    """곳 수를 적은 빚 줄(view-task)이면 ((파일, 규칙, 종류), 곳 수), 아니면 (None, None)"""
    match = COUNTED.match(entry[2])
    return ((entry[0], entry[1], match.group(1)), int(match.group(2))) if match else (None, None)


def summary(entries, root=ROOT):
    by_rule = Counter(rule for _, rule, _ in entries)
    by_target, places = Counter(), Counter()
    for entry in entries:
        key, count = counted(entry)
        target = key[2] if key else entry[2]
        by_target[(entry[1], target)] += 1
        places[(entry[1], target)] += count or 0
    lines = ["| 규칙 | 대상 | 빚 |", "|---|---|---|"]
    for (rule, target), count in sorted(by_target.items(), key=lambda item: (item[0][0], -item[1], item[0][1])):
        extra = f" ({places[(rule, target)]}곳)" if places[(rule, target)] else ""
        lines.append(f"| {rule} | {target} | {count}{extra} |")
    for rule, count in sorted(by_rule.items()):
        lines.append(f"| **{rule} 합계** | | **{count}** |")
    lines.append(f"| **전체** | | **{len(entries)}** |")
    return "\n".join(lines) + "\n\n" + exception_table(root)


def line_count(paths):
    return sum(len(path.read_text(encoding="utf-8").splitlines()) for path in paths)


def exception_table(root=ROOT):
    """예외 목록과 크기. 넓은 예외(폴더)는 앱·CLI 소스에서 차지하는 몫을 함께 적는다"""
    lines = ["| 예외 | 범위 | 파일 | 줄 | 더 허용하는 import |", "|---|---|---:|---:|---|"]
    for relative in ASSEMBLY_FILES:
        path = root / relative
        lines.append(f"| {relative} | 조립 지점(파일) | 1 | {line_count([path]) if path.is_file() else 0:,} | 아래 층 전부 |")
    broad = []
    for folder, modules in BROAD_FOLDERS.items():
        paths = sorted((root / folder).rglob("*.swift"))
        size = line_count(paths)
        broad.append((folder, len(paths), size))
        lines.append(f"| {folder}/ | 넓은 예외(폴더) | {len(paths)} | {size:,} | {', '.join(sorted(modules))} |")
    total = line_count([p for top in ("Sources/DJCrate", "Sources/djc") for p in (root / top).rglob("*.swift")])
    share = sum(size for _, _, size in broad) / total * 100 if total else 0
    lines.append("")
    lines.append("넓은 예외(폴더 단위, 허용 import 목록은 위 표): " + ", ".join(f"{folder}/ {count}파일 {size:,}줄" for folder, count, size in broad)
                 + f" — 앱·CLI 소스 {total:,}줄의 {share:.0f}%")
    return "\n".join(lines)


HEADER = """# 모듈 경계 규칙의 빚 목록(scripts/check-imports.py). 지금 남은 위반을 고정한다.
# 줄: 파일<TAB>규칙<TAB>대상. 규칙: import(허용 밖 프로젝트 모듈), api(핵심부의 직접 호출), test-defaults(시험의 UserDefaults(suiteName:)),
# view-task(뷰 파일의 Task 시작·await, 대상에 곳 수: 늘면 새 위반, 줄면 이 줄을 고친다).
# 빚을 갚으면 그 줄을 지운다(남겨 두면 검사가 "지워도 됨"으로 실패한다). 새 위반은 여기 더하지 말고 고친다.
# 다시 만들기: scripts/check-imports.py --write-debt
"""


def main(arguments):
    try:
        found, unknown, orphans, problems = violations()
    except PackageError as error:
        print(f"✘ 패키지 타깃을 읽지 못했습니다: {error}")
        return 1
    for relative in sorted(orphans):
        print(f"✘ 어느 타깃에도 속하지 않는 Swift 파일입니다: {relative}. 폴더를 옮겼으면 Package.swift의 타깃 경로를 고치세요")
    for module in sorted(unknown):
        print(f"✘ 규칙이 없는 모듈입니다: {module}. scripts/check-imports.py의 ALLOWED에 더하세요")
    if orphans or unknown:
        return 1
    if arguments == ["--write-debt"]:
        DEBT.write_text(HEADER + "".join("\t".join(entry) + "\n" for entry in sorted(found)), encoding="utf-8")
        print(f"빚 목록을 다시 썼습니다: {len(found)}개 ({DEBT.relative_to(ROOT)})")
        return 0
    if arguments == ["--summary"]:
        print(summary(found))
        return 0
    if arguments:
        print("사용: scripts/check-imports.py [--write-debt|--summary]")
        return 2
    debt = read_debt()
    new = sorted(found - debt)
    paid = sorted(debt - found)
    # 곳 수를 적은 줄(view-task)은 같은 파일·종류끼리 짝지어 늘었는지 줄었는지 알린다
    now_counts = {key: (entry, count) for entry in new for key, count in [counted(entry)] if key}
    debt_counts = {key: (entry, count) for entry in paid for key, count in [counted(entry)] if key}
    grew, shrank = [], []
    for key in sorted(now_counts.keys() & debt_counts.keys()):
        (entry_now, count_now), (entry_debt, count_debt) = now_counts[key], debt_counts[key]
        new.remove(entry_now)
        paid.remove(entry_debt)
        (grew if count_now > count_debt else shrank).append("\t".join(key) + f"(빚 {count_debt}곳 → 지금 {count_now}곳)")
    for entry in new:
        print("✘ 새 위반: " + "\t".join(entry))
    for line in grew:
        print("✘ 새 위반: " + line)
    for entry in paid:
        print("✘ 갚은 빚(빚 목록에서 지워도 됨): " + "\t".join(entry))
    for line in shrank:
        print("✘ 갚은 빚(빚 목록 고치기): " + line)
    new, paid = new + grew, paid + shrank
    for problem in problems:
        print("✘ " + problem)
    if new:
        print("새 위반은 빚 목록에 더하지 말고 고치세요. 규칙은 scripts/check-imports.py 맨 위에 있습니다")
    if paid:
        print("갚은 빚은 scripts/import-debt.txt에서 그 줄을 지우거나 곳 수를 고치세요(--write-debt로 다시 만들어도 됩니다)")
    counts = Counter(rule for _, rule, _ in found)
    detail = ", ".join(f"{rule} {count}" for rule, count in sorted(counts.items())) or "없음"
    print(f"모듈 경계 규칙: 위반 {len(found)}개(빚 {len(found & debt)}개: {detail}), 새 위반 {len(new)}개, 갚은 빚 {len(paid)}개")
    return 1 if new or paid or problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
