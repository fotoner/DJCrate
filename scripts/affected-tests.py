#!/usr/bin/env python3
"""바꾼 파일에서 돌릴 시험을 고른다(scripts/check.sh --changed가 부른다).

규칙(위에서부터 먼저 맞는 것):
- Package.swift·Package.resolved·scripts/check.sh·.github/** → 전체 검사로 넓힌다.
- 하네스(scripts/hooks/**·.claude/**·scripts/test-harness.py·scripts/check-docs.py·scripts/check-prose.py·
  scripts/prose-*.txt) → 시험 없음(scripts/test-harness.py·scripts/check-docs.py 중 있는 것, 문서 검사는 check-prose.py와 함께).
- 문서(*.md·docs/**·skills/**) → 시험 없음(scripts/check-docs.py가 있으면 그것).
- 검사 스크립트·모듈 경계 빚 목록·번역 카탈로그 → 해당 가벼운 검사.
- Tests/Support/<재료>/** → 그 재료 타깃을 쓰는 시험 타깃 전체.
- Tests/<타깃>/X.swift → 그 파일의 Suite(Suite가 없는 도우미·가짜·재료 파일이면 그 타깃 전체).
- Sources/<모듈>/X.swift → 그 파일이 선언한 타입(파일 이름의 `+꼬리`를 뗀 이름 포함)을 쓰는 Suite. 모듈에 의존하는
  시험 타깃 안에서만 찾는다. 하나도 없으면 그 모듈에 의존하는 시험 타깃 전체.
- scripts/test-map.txt의 묶음(안전 시험·쓰기 커버리지·번역·시험 없는 파일 등)을 더한다. 안전 시험은 경로로 넓게 고른다
  (기호 grep은 프로세스로 띄우는 CLI 시험·반환값으로만 닿는 값 타입을 못 찾는다).
- 이름 바꿈은 옛 경로와 새 경로를 모두 바뀐 파일로 본다.
- 어느 규칙에도 맞지 않는 파일 → 전체 검사로 넓힌다.
- 고른 Suite가 전체의 절반을 넘으면 전체 검사로 넓힌다.

기호 이름 grep이라 놓치는 경우가 있다(프로토콜 증인·전역 함수·다른 타입을 거쳐 닿는 동작 변화). 그 몫은 합치기 전 전체 검사와
CI가 덮는다.
"""
import argparse
import fnmatch
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path.cwd() if (Path.cwd() / "scripts/affected-tests.py").exists() else Path(__file__).resolve().parent.parent
MAP = ROOT / "scripts/test-map.txt"
CACHE = ROOT / ".build/affected-tests"

WIDEN = ["Package.swift", "Package.resolved", "scripts/check.sh", ".github/**"]
DOCS = ["*.md", "**/*.md", "docs/**", "skills/**", "LICENSE*"]
# 훅·지침·하네스 검사 자신: 앱 코드에 닿지 않으므로 넓히지 않고 두 검사만 돈다
HARNESS = ["scripts/hooks/**", ".claude/**", "scripts/test-harness.py", "scripts/check-docs.py", "scripts/check-prose.py",
           "scripts/prose-*.txt"]
IMPORT_FILES = ["scripts/check-imports.py", "scripts/import-debt.txt"]
SCRIPT_FILES = ["scripts/test-check.py", "scripts/affected-tests.py", "scripts/test-map.txt"]
TRANSLATION_FILES = ["scripts/i18n.swift", "**/*.xcstrings"]
HALF = 0.5
CHECKS = ["imports", "translations", "write-coverage", "docs", "harness", "scripts"]

TOP_DECLARATION = re.compile(
    r"^(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:public|internal|package|private|fileprivate|open|final|indirect|"
    r"nonisolated|sealed)\s+)*(struct|class|enum|protocol|actor|typealias|extension)\s+([A-Za-z_][\w]*)", re.M)
UI_STRING = re.compile(r"String\(ui:|\.ui\(|\bui:")


class PlanError(Exception):
    pass


def glob_regex(pattern):
    """fnmatch와 비슷하되 `*`는 `/`를 넘지 않고 `**`는 넘는다."""
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif pattern.startswith("**", i):
            out, i = out + ".*", i + 2
        elif pattern[i] == "*":
            out, i = out + "[^/]*", i + 1
        elif pattern[i] == "?":
            out, i = out + "[^/]", i + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile(out + r"\Z")


def matches(path, patterns):
    return any(glob_regex(p).match(path) for p in patterns)


def git(*arguments, check=True):
    result = subprocess.run(["git", *arguments], cwd=ROOT, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise PlanError(f"git {' '.join(arguments)} 실패: {result.stderr.strip()}")
    return result


# ── 패키지 그래프 ──────────────────────────────────────────────

def package_targets():
    """swift package dump-package 결과를 Package.swift 내용 해시로 .build/에 캐시한다."""
    manifest = (ROOT / "Package.swift").read_bytes()
    key = hashlib.sha256(manifest).hexdigest()[:16]
    cached = CACHE / f"package-{key}.json"
    if cached.exists():
        data = json.loads(cached.read_text())
    else:
        result = subprocess.run(["swift", "package", "dump-package"], cwd=ROOT, capture_output=True, text=True)
        if result.returncode != 0:
            raise PlanError("swift package dump-package 실패: " + result.stderr.strip()[-300:])
        data = json.loads(result.stdout)
        CACHE.mkdir(parents=True, exist_ok=True)
        for old in CACHE.glob("package-*.json"):
            old.unlink()
        cached.write_text(json.dumps(data))
    targets = {}
    for target in data["targets"]:
        kind = target["type"]
        if kind == "binary":
            continue
        default = ("Tests/" if kind == "test" else "Sources/") + target["name"]
        dependencies = []
        for dependency in target.get("dependencies", []):
            for value in dependency.values():
                if isinstance(value, list) and value and isinstance(value[0], str):
                    dependencies.append(value[0])
        targets[target["name"]] = {"type": kind, "path": target.get("path") or default, "deps": dependencies}
    return targets


def closure(targets, name, seen=None):
    seen = set() if seen is None else seen
    for dependency in targets.get(name, {}).get("deps", []):
        if dependency not in seen:
            seen.add(dependency)
            closure(targets, dependency, seen)
    return seen


# ── 소스·시험 색인 ─────────────────────────────────────────────

def read(path):
    try:
        return (ROOT / path).read_text(errors="replace")
    except (FileNotFoundError, IsADirectoryError):
        return None


def declarations(text):
    return [(kind, name) for kind, name in TOP_DECLARATION.findall(text or "") if name[0].isupper() or name[0] == "_"]


def suite_names(text):
    """시험 파일의 Suite: 본문(다음 최상위 선언 앞까지)에 @Test가 있거나, 이름이 Tests로 끝나거나, @Suite가 붙은 최상위
    타입(확장 포함). 같은 파일의 가짜·도우미 타입은 넣지 않는다(필터에는 무해하지만 Suite 수를 부풀린다)."""
    text = text or ""
    found = list(TOP_DECLARATION.finditer(text))
    names = set()
    for i, match in enumerate(found):
        name = match.group(2)
        if not (name[0].isupper() or name[0] == "_"):
            continue
        body = text[match.start():found[i + 1].start() if i + 1 < len(found) else len(text)]
        before = text[max(0, match.start() - 200):match.start()].rstrip().rsplit("\n", 2)
        attributed = "@Suite" in match.group(0) or any(line.lstrip().startswith("@Suite") for line in before[-2:])
        if "@Test" in body or name.endswith("Tests") or attributed:
            names.add(name)
    return sorted(names)


class Index:
    def __init__(self, targets):
        self.targets = targets
        self.tests = sorted(n for n, t in targets.items() if t["type"] == "test")
        self.dependents = {n: {t for t in self.tests if n in closure(targets, t)} for n in targets}
        self.test_files = {}   # 시험 타깃 → [경로]
        self.texts = {}
        self.suites = {}       # 시험 타깃 → {Suite: [경로]}
        for target in self.tests:
            folder = ROOT / targets[target]["path"]
            files = sorted(str(p.relative_to(ROOT)) for p in folder.rglob("*.swift")) if folder.is_dir() else []
            self.test_files[target] = files
            suites = {}
            for file in files:
                text = self.texts[file] = read(file) or ""
                if "@Test" in text or "XCTestCase" in text:
                    for name in suite_names(text):
                        suites.setdefault(name, []).append(file)
            self.suites[target] = suites
        self.declared = set()
        sources = ROOT / "Sources"
        for path in sources.rglob("*.swift") if sources.is_dir() else []:
            self.declared.update(n for k, n in declarations(path.read_text(errors="replace")) if k != "extension")

    def owner(self, path):
        """경로가 든 타깃(가장 긴 경로가 이긴다)."""
        best = None
        for name, target in self.targets.items():
            prefix = target["path"].rstrip("/") + "/"
            if path.startswith(prefix) and (best is None or len(prefix) > len(self.targets[best]["path"]) + 1):
                best = name
        return best

    def suite_count(self, target):
        return len(self.suites.get(target, {}))

    def suites_in(self, file, target):
        return sorted(name for name, files in self.suites.get(target, {}).items() if file in files)

    def users(self, names, targets, exclude=()):
        """이름을 쓰는 시험 파일 → (Suite 목록, 도우미 파일 목록)."""
        if not names:
            return {}, []
        pattern = re.compile(r"\b(?:" + "|".join(sorted(map(re.escape, names))) + r")\b")
        hits, helpers = {}, []
        for target in targets:
            for file in self.test_files.get(target, []):
                if file in exclude or not pattern.search(self.texts.get(file, "")):
                    continue
                found = self.suites_in(file, target)
                if found:
                    hits.setdefault(target, set()).update(found)
                else:
                    helpers.append((target, file))
        return hits, helpers


# ── 시험 지도(scripts/test-map.txt) ────────────────────────────

def load_map(index, path=MAP):
    groups, needs = [], {}
    if not path.exists():
        return groups, needs
    current = None
    for number, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.split("#", 1)[0].strip() if not raw.lstrip().startswith("note ") else raw.strip()
        if not line:
            continue
        word, _, rest = line.partition(" ")
        rest = rest.strip()
        where = f"test-map.txt {number}행"
        if word == "group":
            current = {"name": rest, "when": [], "maybe": [], "lines": [], "suites": [], "targets": [], "checks": [],
                       "notes": [], "required": [], "none": False}
            groups.append(current)
            continue
        if word == "needs":
            target, _, product = rest.partition(" ")
            if target not in index.tests or not product.strip():
                raise PlanError(f"{where}: needs <시험 타깃> <제품> 모양이 아니거나 없는 시험 타깃입니다: {rest}")
            needs.setdefault(target, []).append(product.strip())
            continue
        if current is None:
            raise PlanError(f"{where}: group 줄보다 앞에 {word}가 있습니다")
        if word == "when":
            current["when"].append(rest)
            current["lines"].append((number, rest))
        elif word == "maybe":
            current["maybe"].append(rest)
        elif word == "suite":
            target, _, suite = rest.partition(".")
            if target not in index.tests or suite not in index.suites.get(target, {}):
                raise PlanError(f"{where}: 없는 Suite입니다: {rest}. 이름이 바뀌었으면 test-map.txt를 고치세요")
            current["suites"].append((target, suite))
        elif word == "target":
            if rest not in index.tests:
                raise PlanError(f"{where}: 없는 시험 타깃입니다: {rest}")
            current["targets"].append(rest)
        elif word == "check":
            if rest not in CHECKS:
                raise PlanError(f"{where}: 모르는 검사입니다: {rest} (가능: {', '.join(CHECKS)})")
            current["checks"].append(rest)
        elif word == "note":
            current["notes"].append(rest)
        elif word == "require":
            current["required"].append(rest)
        elif word == "none":
            current["none"] = True
        else:
            raise PlanError(f"{where}: 모르는 줄입니다: {raw.strip()}")
    for group in groups:
        if not group["when"]:
            raise PlanError(f"test-map.txt: {group['name']} 묶음에 when 줄이 없습니다")
        group["paths"] = group["when"] + group["maybe"]
    return groups, needs


def repository_files():
    """지도 경로 검사용 저장소 파일 목록(빌드 산출물·.git 제외)."""
    skip = {".git", ".build", ".swiftpm", "__pycache__", "node_modules", "dist"}
    found = []
    for folder, names, files in os.walk(ROOT):
        names[:] = [n for n in names if n not in skip]
        relative = os.path.relpath(folder, ROOT)
        found += [f if relative == "." else f"{relative}/{f}" for f in files]
    return found


def check_map_paths(groups):
    """when 줄이 어느 파일에도 맞지 않으면(오타·파일 이동) 그 묶음이 소리 없이 꺼지므로 실패한다.
    앞으로 옮길 자리처럼 일부러 둔 경로는 maybe로 적는다."""
    files = repository_files()
    for group in groups:
        for number, pattern in group["lines"]:
            regex = glob_regex(pattern)
            if not any(regex.match(f) for f in files):
                raise PlanError(f"test-map.txt {number}행: when {pattern}에 맞는 파일이 없습니다({group['name']} 묶음). "
                                "파일을 옮겼으면 지도를 고치고, 앞으로 생길 자리면 maybe로 적으세요")


# ── 바꾼 파일 ─────────────────────────────────────────────────

def resolve_base(base):
    if base is not None:
        if not base or git("rev-parse", "--verify", "--quiet", base + "^{tree}", check=False).returncode != 0:
            raise PlanError(f"기준을 찾지 못했습니다: {base}")
        return base
    for candidate in ("dev", "origin/dev", "main"):
        result = git("merge-base", "HEAD", candidate, check=False)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    if git("rev-parse", "--verify", "--quiet", "main", check=False).returncode == 0:
        return "main"
    raise PlanError("기준을 정하지 못했습니다(dev·origin/dev·main이 없음). --base <rev>를 주세요")


def generated(path):
    return "__pycache__/" in path or path.endswith(".pyc")


def changed_files(base):
    """기준과 작업 트리(스테이지·추적 안 된 파일 포함)의 차이. 기준이 트리 해시(작업 트리 해시)면 `git diff`가 기준에만 있는
    추적 안 된 파일을 지운 것으로 내므로, 디스크에 있는 후보는 기준의 blob과 내용을 맞대어 같으면 뺀다."""
    # --no-renames: 다른 모듈로 옮긴 파일의 옛 경로(옛 모듈에 의존하는 시험)도 바뀐 파일로 본다.
    names = [n for n in re.split(r"[\0\n]", git("diff", "--name-only", "--no-renames", "-z", base).stdout) if n]
    names += [n for n in re.split(r"[\0\n]", git("ls-files", "--others", "--exclude-standard", "-z").stdout) if n]
    candidates = sorted({n for n in names if not generated(n)})
    present = [n for n in candidates if (ROOT / n).is_file()]
    if not present:
        return candidates
    hashes = subprocess.run(["git", "hash-object", "--stdin-paths"], cwd=ROOT, input="\n".join(present) + "\n",
                            capture_output=True, text=True).stdout.split()
    if len(hashes) != len(present):
        return candidates
    in_base = {}
    for entry in git("ls-tree", "-r", "-z", base, "--", *present, check=False).stdout.split("\0"):
        if "\t" in entry:
            meta, path = entry.split("\t", 1)
            in_base[path] = meta.split()[-1]
    same = {path for path, blob in zip(present, hashes) if in_base.get(path) == blob}
    return [n for n in candidates if n not in same]


def ui_string_changed(path, base):
    if base is not None:
        diff = git("diff", "-U0", base, "--", path, check=False).stdout
        if diff.strip():
            return any(UI_STRING.search(l) for l in diff.splitlines() if l[:1] in "+-" and l[:3] not in ("+++", "---"))
    return bool(UI_STRING.search(read(path) or ""))


# ── 고르기 ────────────────────────────────────────────────────

class Plan:
    def __init__(self, index):
        self.index = index
        self.suites = {}        # 시험 타깃 → set(Suite)
        self.whole = set()
        self.checks = {name: False for name in CHECKS}
        self.reasons = []
        self.notes = []
        self.required = []
        self.widen = None
        self.build = False

    def add(self, file, rule, suites=(), whole=()):
        selects = []
        for target, suite in suites:
            self.suites.setdefault(target, set()).add(suite)
            selects.append(f"{target}.{suite}")
        for target in whole:
            self.whole.add(target)
            selects.append(f"{target} 전체")
        self.reasons.append({"file": file, "rule": rule, "selects": selects})

    def widen_to_full(self, reason):
        if self.widen is None:
            self.widen = reason


def source_symbols(path, base, index):
    text = read(path)
    if text is None and base is not None:
        text = git("show", f"{base}:{path}", check=False).stdout
    names = set()
    for kind, name in declarations(text):
        if kind != "extension" or name in index.declared:
            names.add(name)
    stem = Path(path).stem.split("+", 1)[0]
    if stem in index.declared:
        names.add(stem)
    return names


def select_for_source(plan, path, module, base):
    index = plan.index
    if not path.endswith(".swift"):
        dependents = sorted(index.dependents.get(module, ()))
        if dependents:
            plan.add(path, f"{module}의 리소스: 의존하는 시험 타깃 전체", whole=dependents)
        else:
            plan.build = True
            plan.add(path, f"{module}에 의존하는 시험 타깃 없음: 빌드만")
        return
    plan.checks["imports"] = True
    if ui_string_changed(path, base):
        plan.checks["translations"] = True
        plan.notes.append(f"{path}: 화면 문구가 바뀌어 번역 검사를 함께 돕니다")
    dependents = sorted(index.dependents.get(module, ()))
    if not dependents:
        plan.build = True
        plan.add(path, f"{module}에 의존하는 시험 타깃 없음: 빌드만")
        return
    names = source_symbols(path, base, index)
    hits, helpers = index.users(names, dependents)
    # 도우미 파일(시험 없음)을 거치면 한 번 더 따라간다.
    for target, helper in helpers:
        # 도우미가 새로 선언한 타입만 따라간다. `extension LibraryStore`처럼 제품 타입을 넓힌 도우미를 따라가면
        # 그 타입을 쓰는 Suite 전부로 번진다.
        extra = {n for k, n in declarations(index.texts.get(helper, "")) if k != "extension"}
        more, _ = index.users(extra, [target], exclude=[helper])
        for t, found in more.items():
            hits.setdefault(t, set()).update(found)
    stem = Path(path).stem.split("+", 1)[0]
    for target in dependents:
        if stem + "Tests" in index.suites.get(target, {}):
            hits.setdefault(target, set()).add(stem + "Tests")
    pairs = sorted((t, s) for t, found in hits.items() for s in found)
    if pairs:
        shown = ", ".join(sorted(names)[:6]) + (" …" if len(names) > 6 else "")
        plan.add(path, f"기호 {shown}을(를) 쓰는 Suite", suites=pairs)
    else:
        plan.add(path, f"시험이 닿지 않는 소스: {module}에 의존하는 시험 타깃 전체", whole=dependents)


def select_for_test(plan, path, target, base):
    index = plan.index
    text = read(path)
    if not path.endswith(".swift"):
        plan.add(path, f"{target}의 시험 자료: 타깃 전체", whole=[target])
        return
    plan.checks["imports"] = True
    if text is None:
        plan.build = True
        plan.add(path, "지운 시험 파일: 빌드만")
        return
    own = index.suites_in(path, target)
    if own:
        plan.add(path, "시험 파일의 Suite", suites=[(target, s) for s in own])
        return
    # 가짜·하네스·재료는 다른 도우미를 거쳐 여러 Suite에 닿는다(가짜 → 하네스 → 복원 세션 시험). 따라가지 않고 타깃 전체.
    plan.add(path, "시험 도우미(Suite 없음): 타깃 전체", whole=[target])


def make_plan(files, base, index, groups, needs):
    plan = Plan(index)
    for path in files:
        handled = False
        group_hits = [g for g in groups if matches(path, g["paths"])]
        if matches(path, WIDEN):
            plan.widen_to_full(f"{path}이(가) 바뀌었습니다")
            plan.add(path, "전체 검사로 넓힘")
            continue
        if matches(path, HARNESS):
            handled = True
            plan.checks["harness"] = plan.checks["harness"] or (ROOT / "scripts/test-harness.py").exists()
            plan.checks["docs"] = plan.checks["docs"] or (ROOT / "scripts/check-docs.py").exists()
            ran = [name for name, on in (("scripts/test-harness.py", plan.checks["harness"]),
                                         ("scripts/check-docs.py·check-prose.py", plan.checks["docs"])) if on]
            plan.add(path, "훅·지침·하네스: 시험 없음" + "".join(", " + name for name in ran))
        elif matches(path, DOCS):
            handled = True
            if (ROOT / "scripts/check-docs.py").exists():
                plan.checks["docs"] = True
            plan.add(path, "문서: 시험 없음" + (", scripts/check-docs.py·check-prose.py" if plan.checks["docs"] else ""))
        elif path in IMPORT_FILES:
            handled = True
            plan.checks["imports"] = True
            plan.add(path, "모듈 경계 규칙 검사")
        elif path in SCRIPT_FILES:
            handled = True
            plan.checks["scripts"] = True
            plan.add(path, "검사 스크립트 회귀(scripts/test-check.py)")
        elif matches(path, TRANSLATION_FILES):
            handled = True
            plan.checks["translations"] = True
            plan.add(path, "번역 검사")
        elif path.startswith("Tests/") or path.startswith("Sources/"):
            owner = index.owner(path)
            if owner is None:
                pass
            elif path.startswith("Tests/") and index.targets[owner]["type"] != "test":
                handled = True
                if path.endswith(".swift"):
                    plan.checks["imports"] = True
                dependents = sorted(index.dependents.get(owner, ()))
                plan.add(path, f"시험 재료 {owner}: 쓰는 시험 타깃 전체", whole=dependents)
            elif index.targets[owner]["type"] == "test":
                handled = True
                select_for_test(plan, path, owner, base)
            else:
                handled = True
                select_for_source(plan, path, owner, base)
        for group in group_hits:
            handled = True
            if group["none"] and not (group["suites"] or group["targets"] or group["checks"]):
                plan.add(path, f"{group['name']}: 시험 없음")
                continue
            for check in group["checks"]:
                plan.checks[check] = True
            plan.add(path, f"지도 묶음 {group['name']}", suites=group["suites"], whole=group["targets"])
            plan.notes.extend(n for n in group["notes"] if n not in plan.notes)
            plan.required.extend(r for r in group["required"] if r not in plan.required)
        if not handled:
            plan.widen_to_full(f"규칙에 없는 파일 {path}이(가) 바뀌었습니다")
            plan.add(path, "모르는 파일: 전체 검사로 넓힘")
    total = sum(index.suite_count(t) for t in index.tests)
    selected = sum(index.suite_count(t) for t in plan.whole)
    selected += sum(len(s) for t, s in plan.suites.items() if t not in plan.whole)
    if plan.widen is None and total and selected / total > HALF:
        plan.widen_to_full(f"고른 Suite가 전체의 절반을 넘습니다({selected}/{total})")
    return plan, selected, total, needs


def render(plan, base, files, selected, total, needs):
    targets = sorted(set(plan.whole) | set(plan.suites))
    if plan.widen:
        scope = "full"
    elif targets:
        scope = "tests"
    elif plan.build:
        scope = "build"
    else:
        scope = "none"
    test_filter = None
    if scope == "tests":
        parts = []
        for target in targets:
            if target in plan.whole:
                parts.append(re.escape(target) + r"\.")
            else:
                parts.append(re.escape(target) + r"\.(" + "|".join(sorted(plan.suites[target])) + ")/")
        test_filter = "^(" + "|".join(parts) + ")"
    else:
        targets = []
    products = sorted({p for t in targets for p in needs.get(t, [])})
    suites = sorted(f"{t}.{s}" for t, found in plan.suites.items() for s in found)
    return {
        "base": base,
        "files": files,
        "scope": scope,
        "filter": test_filter,
        "targets": targets,
        "products": products,
        "suites": suites,
        "wholeTargets": sorted(plan.whole) if scope == "tests" else [],
        "reasons": plan.reasons,
        "widen": plan.widen,
        "checks": plan.checks,
        "notes": plan.notes,
        "required": plan.required,
        "counts": {"selectedSuites": selected if scope == "tests" else 0, "totalSuites": total},
    }


def human(result):
    lines = []
    scope = {"full": "전체 검사", "tests": "고른 시험", "build": "빌드만(돌릴 시험 없음)", "none": "빌드·시험 없음"}[result["scope"]]
    counts = result["counts"]
    head = f"범위: {scope}"
    if result["scope"] == "tests":
        head += f" — Suite {counts['selectedSuites']}/{counts['totalSuites']}개, 시험 타깃 {', '.join(result['targets'])}"
    lines.append(head)
    lines.append(f"기준: {result['base'] or '(파일 목록)'} · 바뀐 파일 {len(result['files'])}개")
    if result["widen"]:
        lines.append(f"넓힘: {result['widen']}")
    shown = result["reasons"][:12]
    for reason in shown:
        selects = ", ".join(reason["selects"][:4]) + (" …" if len(reason["selects"]) > 4 else "")
        lines.append(f"  {reason['file']} → {reason['rule']}" + (f": {selects}" if selects else ""))
    if len(result["reasons"]) > len(shown):
        lines.append(f"  … 그 밖 {len(result['reasons']) - len(shown)}개(affected.json)")
    if result["filter"]:
        lines.append(f"필터: {result['filter']}")
    extra = [name for name, on in result["checks"].items() if on]
    if extra:
        lines.append("함께 돌 검사: " + ", ".join(extra))
    for note in result["notes"]:
        lines.append(f"안내: {note}")
    for required in result["required"]:
        lines.append(f"남은 필수 검사: {required}")
    return "\n".join(lines)


def shell(result):
    values = {
        "plan_scope": result["scope"],
        "plan_filter": result["filter"] or "",
        "plan_targets": " ".join(result["targets"]),
        "plan_products": " ".join(result["products"]),
        "plan_checks": " ".join(n for n, on in result["checks"].items() if on),
        "plan_widen": result["widen"] or "",
        "plan_base": result["base"] or "",
        "plan_suites": str(result["counts"]["selectedSuites"]),
        "plan_total_suites": str(result["counts"]["totalSuites"]),
        "plan_required": "\n".join(result["required"]),
        "plan_text": human(result),
        "plan_json": json.dumps(result, ensure_ascii=False, indent=1),
    }
    return "\n".join(f"{name}={shlex.quote(value)}" for name, value in values.items())


def worktree_tree():
    """작업 트리 전체(스테이지·추적 안 된 파일 포함, .gitignore 제외)의 트리 해시. 실제 index는 건드리지 않는다."""
    index_path = git("rev-parse", "--git-path", "index").stdout.strip()
    source = Path(index_path) if Path(index_path).is_absolute() else ROOT / index_path
    with tempfile.TemporaryDirectory(prefix="djc-tree-") as folder:
        copy = Path(folder) / "index"
        if source.exists():
            shutil.copyfile(source, copy)
        env = dict(os.environ, GIT_INDEX_FILE=str(copy))
        added = subprocess.run(["git", "add", "-A"], cwd=ROOT, env=env, capture_output=True, text=True)
        tree = subprocess.run(["git", "write-tree"], cwd=ROOT, env=env, capture_output=True, text=True)
    value = tree.stdout.strip()
    if added.returncode or tree.returncode or not re.fullmatch(r"[0-9a-f]{40,64}", value):
        raise PlanError("작업 트리 해시를 구하지 못했습니다")
    return value


def main():
    parser = argparse.ArgumentParser(description="바꾼 파일에서 돌릴 시험을 고른다")
    parser.add_argument("--base", help="비교 기준(커밋·브랜치·트리 해시). 없으면 dev와의 merge-base")
    parser.add_argument("--files", nargs="+", help="git 대신 이 경로들을 바뀐 파일로 본다")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_true", help="JSON으로 출력")
    output.add_argument("--shell", action="store_true", help="check.sh가 eval로 읽는 plan_ 변수로 출력")
    output.add_argument("--worktree-tree", action="store_true", help="작업 트리 해시만 출력(통과 기록 재사용 판정)")
    output.add_argument("--check-map", action="store_true", help="test-map.txt가 지금 Tests/와 맞는지만 본다")
    output.add_argument("--list-check", metavar="검사", help="--files 중 지도에서 그 검사를 켜는 파일만 출력")
    args = parser.parse_args()
    try:
        if args.worktree_tree:
            print(worktree_tree())
            return 0
        index = Index(package_targets())
        groups, needs = load_map(index)
        if args.check_map or not args.files:
            check_map_paths(groups)
        if args.check_map:
            print(f"test-map.txt: 묶음 {len(groups)}개, Suite {sum(len(g['suites']) for g in groups)}개 확인")
            return 0
        if args.list_check:
            for path in args.files or []:
                if any(args.list_check in g["checks"] and matches(path, g["paths"]) for g in groups):
                    print(path)
            return 0
        if args.files:
            base, files = None, sorted(set(args.files))
        else:
            base = resolve_base(args.base)
            files = changed_files(base)
        plan, selected, total, needs = make_plan(files, base, index, groups, needs)
        result = render(plan, base, files, selected, total, needs)
    except PlanError as error:
        print(f"affected-tests: {error}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=1))
    elif args.shell:
        print(shell(result))
    else:
        print(human(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
