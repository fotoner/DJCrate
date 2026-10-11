#!/usr/bin/env python3
"""Claude Code PreToolUse(Bash) 훅: 라이브 rekordbox 폴더·실물 볼륨(/Volumes/…)·디스크 장치에 대한 확실한 쓰기를 막는다.

이 훅은 에이전트의 실수를 줄이는 안내(두 번째 그물)다. 안전 경계는 코드 관문(RekordboxWriteGuard·TestProcess·
UsbPhysicalWriteGate·CLIGuards)이다. 셸 문법을 다 풀지 않고, 단순하고 모르면 막는 쪽의 규칙을 쓴다.
알려진 한계(변수에 담은 경로, 스크립트 파일 안의 쓰기 등)는 .claude/rules/harness.md에 적는다.
읽기(ls·stat·cat·cp 원본)·djc 읽기 명령·빌드·시험·git은 막지 않는다. 막으면 종료 코드 2와 이유(표준 오류)를 낸다.
입력: 표준 입력의 훅 JSON(tool_name, tool_input.command, cwd). 시험: scripts/test-harness.py
"""
import json
import os
import re
import shlex
import sys

HOME = os.path.expanduser("~")
LIVE_ROOTS = (HOME + "/Library/Pioneer", HOME + "/Library/Application Support/Pioneer")
LIVE_CANON = tuple(root.lower() for root in LIVE_ROOTS)
PLACEHOLDER = {"live": LIVE_ROOTS[0] + "/__piped__", "volume": "/Volumes/__piped__", "device": "/dev/disk99"}

# 인자 중 하나라도 보호 경로면 쓰기
ANY_ARG_WRITERS = {"rm", "rmdir", "unlink", "shred", "srm", "touch", "mkdir", "chmod", "chown", "chgrp", "chflags",
                   "truncate", "dot_clean", "setfile", "mv", "tee", "sqlite3", "sqlcipher", "mktemp"}
# 지우는 명령: 보호 경로의 조상 폴더(~/Library 등)도 막는다
REMOVERS = {"rm", "rmdir", "unlink", "shred", "srm", "mv"}
# 마지막 인자(대상)가 보호 경로면 쓰기
DEST_WRITERS = {"cp", "gcp", "ditto", "rsync", "install", "scp", "ln"}
INPLACE_EDITORS = {"sed", "gsed", "perl", "ruby"}
DISKUTIL_WRITES = re.compile(r"^(erase\w*|partition\w*|reformat|zero\w*|randomdisk|secureerase|splitpartition|"
                             r"mergepartitions|resizevolume|renamevolume|addpartition|enablejournal|disablejournal)$",
                             re.IGNORECASE)
DISKUTIL_GROUPS = {"apfs", "cs", "corestorage", "ar", "appleraid"}
DISKUTIL_GROUP_WRITES = re.compile(r"^(delete\w*|erase\w*|resize\w*|add\w*|remove\w*|create\w*|convert\w*|"
                                   r"decrypt\w*|encrypt\w*|split\w*|merge\w*|update\w*)$", re.IGNORECASE)
WRAPPERS = {"sudo", "doas", "env", "nohup", "time", "command", "builtin", "exec", "nice", "caffeinate", "stdbuf",
            "timeout", "gtimeout", "lockf"}
# 감싸는 명령의 값을 받는 옵션(값 칸을 명령으로 보지 않게)
WRAPPER_VALUE_OPTIONS = {
    "sudo": {"-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T", "-R"}, "doas": {"-u", "-C"},
    "env": {"-u", "-C", "-P", "-S"}, "nice": {"-n"}, "caffeinate": {"-t", "-w"}, "stdbuf": {"-i", "-o", "-e"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"}, "gtimeout": {"-s", "-k", "--signal", "--kill-after"},
    "lockf": {"-t"}, "exec": {"-a"},
}
# 제어문·묶음 낱말: 떼고 그 뒤 명령을 본다
KEYWORDS = {"then", "do", "else", "elif", "if", "while", "until", "!", "{", "}", "fi", "done", "esac", "coproc"}
SKIP_HEADS = {"for", "case", "select", "function"}
SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "fish"}
SEPARATORS = {";", "&&", "||", "|", "|&", "&", "\n", "(", ")", ";;", ";&", ";;&"}
WRITE_REDIRECTS = {">", ">>", ">|", "&>", "&>>", "<>", ">&"}
INPUT_REDIRECTS = {"<", "<<", "<<<"}

# djc: 등록된 맨 위 명령(변수로 부른 djc를 알아볼 때). scripts/test-harness.py가 소스 등록과 대조한다
DJC_COMMANDS = {"compat", "lab", "cache", "search", "track", "playlists", "playlist", "histories", "history", "drafts",
                "duplicates", "draft", "snapshot-point", "xml-export", "xml-diff", "snapshot", "report", "analyze",
                "reflection-dry-run", "cue-write", "track-add", "track-delete", "playlist-write", "rekordbox-restore",
                "schema-dump", "path", "parse", "usb-info", "usb-export", "usb-edit", "usb-migrate", "usb-restore",
                "usb-recover"}
# 라이브 경로를 받아도 되는 읽기 명령(라이브 DB 확인·사본 뜨기·분석 폴더 읽기·rekordbox 설정 읽기)
DJC_READ = {"compat", "snapshot", "usb-info", "xml-export", "xml-diff"}
SNAPSHOT_POINT_READ = {"create", "list", "diff"}
LAB_READ = {"setting-export", "setting-check", "usb-anlz-check", "anlz-roundtrip"}
RB_WRITE_COMMANDS = {"cue-write", "track-add", "track-delete", "playlist-write", "rekordbox-restore"}
USB_WRITE_COMMANDS = {"usb-export", "usb-edit", "usb-migrate", "usb-restore", "usb-recover"}
USB_LAB_WRITES = {"usb-image", "usb-write-check", "usb-commit-crash", "usb-anlz-relocate"}
OUTPUT_OPTIONS = {"--out", "--output", "--output-file"}
# rsync: 값이 경로가 아닌 옵션(값을 피연산자로 보지 않게)과 값이 쓰는 자리인 옵션
RSYNC_VALUE_OPTIONS = {"--exclude", "--include", "--filter", "-f", "-e", "--rsh", "--exclude-from", "--include-from",
                       "--files-from", "--chmod", "--chown", "--rsync-path", "--timeout", "--bwlimit", "--suffix"}
RSYNC_WRITE_OPTIONS = {"--log-file", "--backup-dir", "--temp-dir", "-T", "--partial-dir"}

# 코드 문자열 안의 보호 경로(인터프리터 규칙). 글자로만 본다
PROTECTED_TEXT = re.compile(r"library/pioneer|application\\? support/pioneer|/volumes/|/dev/r?disk\d", re.IGNORECASE)
FAST_PATH = re.compile(r"pioneer|/volumes|--live|--allow-physical|/dev/|"
                       r"\b(dd|diskutil|newfs\w*|mkfs\w*|fdisk|gpt|asr|rm|rmdir|mv|srm|shred|unlink|find)\b", re.IGNORECASE)

LIVE_REASON = ("라이브 rekordbox 폴더(~/Library/Pioneer 등)에는 쓰지 않습니다(djc는 읽기 명령만 라이브 경로를 받습니다). "
               "시험·실험은 사본에만 하세요: djc 쓰기 명령은 --db <사본 폴더>/master.db(필요하면 --share <사본 폴더>/share), "
               "앱·시험은 DJC_REKORDBOX_DIR=<사본 폴더>·DJC_HOME=<임시 폴더>")
LIVE_FLAG_REASON = ("--live는 실제 rekordbox 라이브러리에 씁니다(--dry-run이어도 라이브 DB를 엽니다). 에이전트는 사본에 "
                    "--db <사본 폴더>/master.db를 쓰세요. 실제 반영은 사용자가 앱이나 터미널에서 직접 합니다")
VOLUME_REASON = ("실물 볼륨(/Volumes/…)에는 쓰지 않습니다. USB 쓰기 시험은 djc lab usb-image로 임시 폴더 아래에 만든 "
                 "디스크 이미지(--mount <임시 폴더>)에만 하세요. 실물 USB 쓰기는 사용자가 앱 확인 창이나 터미널에서 직접 합니다")
PHYSICAL_REASON = ("--allow-physical(실물 USB 쓰기 동의)은 사람이 터미널에서 직접 줍니다. 에이전트의 USB 쓰기 시험은 "
                   "djc lab usb-image로 임시 폴더 아래에 만든 디스크 이미지에만 하세요")
DISK_REASON = ("디스크 지우기·포맷·파티션·장치 원시 쓰기는 하지 않습니다(장치 번호를 잘못 고르면 다른 디스크를 지웁니다). "
               "시험용 디스크는 djc lab usb-image create|attach로 임시 폴더 아래 디스크 이미지로 만드세요")
CODE_REASON = ("인터프리터·셸에 코드를 넘기는 명령(python -c, perl -e, osascript, eval, bash -c, here-document 등)에 "
               "라이브 rekordbox 경로나 /Volumes/가 있어 막았습니다(읽기도 막습니다). 읽기는 djc 읽기 명령(compat·usb-info·"
               "lab usb-tree 등)이나 사본에서 하고, 쓰기는 사본·디스크 이미지에만 하세요. 문서·코드 파일 편집은 Edit 도구를 쓰세요")
LINK_REASON = ("라이브 rekordbox 폴더·볼륨을 가리키는 링크는 만들지 않습니다(링크를 거친 쓰기가 원본에 닿습니다). "
               "사본은 cp -R·ditto로 실제 복사하세요")
DJC_DIR_REASON = ("DJC_REKORDBOX_DIR은 사본 폴더여야 합니다(라이브 rekordbox 폴더·볼륨을 주면 시험·자가 테스트가 실제 "
                  "라이브러리에 씁니다). cp -R로 뜬 사본 폴더를 주세요")


def normalize(command):
    for pattern in (r"\$\{HOME\}", r"\$HOME\b", r"(?<![\w/])~(?=/)"):
        command = re.sub(pattern, lambda _: HOME, command)
    return command


def canonical(value, cwd):
    """비교용 경로(소문자·// 줄임·.. 풀기, 상대 경로는 cwd 기준). 경로로 볼 수 없으면 None."""
    if not value or value.startswith("-"):
        return None
    if value == "~":
        value = HOME
    if value.startswith("/"):
        path = value
    elif cwd and not value.startswith(("$", "~")):
        path = cwd + "/" + value
    else:
        return None
    path = os.path.normpath(re.sub(r"/+", "/", path)).lower()
    if path.startswith("/system/volumes/data/"):
        path = path[len("/system/volumes/data"):]
    return path


def kind_of(path):
    if path is None:
        return None
    if any(path == root or path.startswith(root + "/") for root in LIVE_CANON):
        return "live"
    if path == "/volumes" or path.startswith("/volumes/"):
        return "volume"
    if re.match(r"^/dev/r?disk\d", path):
        return "device"
    return None


def protected(value, cwd=None, removing=False):
    """보호 경로면 'live'·'volume'·'device', 아니면 None. `--volume=/Volumes/X`·`of=/dev/disk4` 꼴도 본다.
    removing이면 보호 경로를 품은 조상 폴더(~/Library 등)도 보호로 본다(지우거나 옮기면 함께 사라진다)."""
    candidates = [value] + ([value.split("=", 1)[1]] if "=" in value else [])
    for candidate in candidates:
        path = canonical(candidate, cwd)
        kind = kind_of(path)
        if kind:
            return kind
        if removing and path and any(root.startswith(path.rstrip("/") + "/") for root in LIVE_CANON):
            return "live"
    return None


def reason_for(kind):
    return {"live": LIVE_REASON, "volume": VOLUME_REASON, "device": DISK_REASON}[kind]


def split_lines(command):
    """따옴표 밖 줄바꿈을 ;로 바꾼다(줄마다 다른 명령). 줄 끝 \\ 이음은 그대로 둔다."""
    out, quote, index = [], None, 0
    while index < len(command):
        ch = command[index]
        if ch == "\\" and index + 1 < len(command):
            out.append(command[index:index + 2])
            index += 2
            continue
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == "\n":
            ch = " ; "
        out.append(ch)
        index += 1
    return "".join(out)


def tokenize(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()<>")
    lexer.whitespace_split = True
    lexer.commenters = ""
    try:
        return list(lexer)
    except ValueError:
        return command.split()


HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def head_word(text):
    """그 글의 마지막 명령 조각의 명령 이름(here-document를 받는 명령)."""
    part = re.split(r"[;&|(]", text)[-1]
    _, rest = strip_prefix(tokenize(part))
    return os.path.basename(rest[0]) if rest else ""


def split_heredocs(command):
    """here-document 본문을 떼어 (본문 뺀 명령, [(받는 명령, 본문, 따옴표 구분자인지)])를 낸다.
    끝 줄이 없는 here-document는 본문으로 보지 않는다(명령으로 남겨 검사한다)."""
    lines, result, docs, index = command.split("\n"), [], [], 0
    while index < len(lines):
        line = lines[index]
        result.append(line)
        index += 1
        for match in HEREDOC.finditer(line):
            delimiter = match.group(2)
            end = next((j for j in range(index, len(lines)) if lines[j].strip() == delimiter), None)
            if end is None:
                continue
            docs.append((head_word(line[:match.start()]), "\n".join(lines[index:end]), bool(match.group(1))))
            index = end + 1
    return "\n".join(result), docs


def substitutions(text):
    """홑따옴표 밖의 명령 치환(`…`·$(…)) 안 글들."""
    found, index, quote = [], 0, None
    while index < len(text):
        ch = text[index]
        if ch == "\\" and quote != "'":
            index += 2
            continue
        if quote == "'":
            if ch == "'":
                quote = None
        elif ch == "'" and quote is None:
            quote = "'"
        elif ch == '"':
            quote = None if quote == '"' else '"'
        elif ch == "`":
            end = text.find("`", index + 1)
            if end > index:
                found.append(text[index + 1:end])
                index = end
        elif text.startswith("$(", index) and not text.startswith("$((", index):
            depth, cursor = 1, index + 2
            while cursor < len(text) and depth:
                depth += {"(": 1, ")": -1}.get(text[cursor], 0)
                cursor += 1
            found.append(text[index + 2:cursor - 1])
            index = cursor - 1
        index += 1
    return found


def segments(tokens):
    """명령 줄을 (구분자, 토큰 목록)으로 나눈다. 리다이렉션은 토큰으로 남긴다."""
    current, joined, result = [], None, []
    for token in tokens:
        if token in SEPARATORS:
            if current:
                result.append((joined, current))
            current, joined = [], token
        else:
            current.append(token)
    if current:
        result.append((joined, current))
    return result


def strip_prefix(tokens):
    """앞의 환경 변수 대입·제어문 낱말·감싸는 명령(sudo·env·timeout·nice 등)을 떼고 (대입 목록, 나머지)를 낸다."""
    assigned, index = [], 0
    while index < len(tokens):
        token = tokens[index]
        name = os.path.basename(token)
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token):
            assigned.append(token)
            index += 1
        elif token in KEYWORDS:
            index += 1
        elif name in WRAPPERS:
            index += 1
            valued = WRAPPER_VALUE_OPTIONS.get(name, set())
            while index < len(tokens) and tokens[index].startswith("-"):
                option = tokens[index]
                index += 1
                if option == "--":
                    break
                if option in valued:
                    index += 1
            if name in ("timeout", "gtimeout") and index < len(tokens) and re.match(r"^[\d.]+[smhd]?$", tokens[index]):
                index += 1
            if name == "lockf" and index < len(tokens):
                index += 1  # 잠금 파일
        else:
            break
    return assigned, tokens[index:]


def operands(args):
    return [a for a in args if not a.startswith("-")]


class State:
    def __init__(self, cwd):
        self.cwd = cwd
        self.oldpwd = None
        self.stack = []
        self.code = False
        self.variables = {}

    def expand(self, token):
        """같은 명령 안에서 정한 변수(`RB=…; cp x "$RB/…"`, for 변수)를 글자로 바꾼다. 모르는 변수는 그대로 둔다."""
        return re.sub(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", lambda m: self.variables.get(m.group(1), m.group(0)), token)

    def remember(self, assignments):
        for assignment in assignments:
            name, value = assignment.split("=", 1)
            self.variables[name] = self.expand(value)


def change_directory(target, state):
    """cd 대상을 따라간다. 모르는 곳(변수 등)이면 보호 폴더에 있을 때는 그대로 둔다(모르면 막는 쪽)."""
    if target == "-":
        state.cwd, state.oldpwd = state.oldpwd, state.cwd
        return
    target = HOME if target in (None, "~") else target
    state.oldpwd = state.cwd
    if target.startswith("/"):
        state.cwd = os.path.normpath(re.sub(r"/+", "/", target))
    elif target.startswith(("$", "~")) or not state.cwd:
        state.cwd = state.cwd if kind_of(canonical(state.cwd or "", None)) else None
    else:
        state.cwd = os.path.normpath(state.cwd + "/" + target)


def is_code_form(name, params, stdin):
    """인터프리터·셸에 코드를 넘기는 모양인지(stdin: 파이프·here-document·here-string·< 로 입력을 받음)."""
    script_operands = operands(params)
    if name == "eval" or name == "osascript":
        return True
    if name in SHELLS:
        return (any(re.match(r"^-[a-zA-Z]*[cs][a-zA-Z]*$", p) for p in params)
                or (stdin and not script_operands))
    if re.match(r"^(python|pypy)[\d.]*$", name):
        return (any(re.match(r"^-[a-zA-Z]*c$", p) for p in params) or "-" in params
                or (stdin and not script_operands))
    if re.match(r"^perl[\d.]*$", name) or name == "ruby":
        return any(re.match(r"^-[a-zA-Z]*[eE]$", p) for p in params) or (stdin and not script_operands)
    if name in ("node", "nodejs", "deno", "bun"):
        return any(p in ("-e", "--eval", "-p", "--print") for p in params) or (stdin and not script_operands)
    if name in ("php", "lua"):
        return any(p in ("-r", "-e") for p in params)
    if name in ("awk", "gawk", "nawk", "mawk"):
        return any("system(" in p for p in params)
    return False


def check_djc(params, state):
    words = operands(params)
    if not words:
        return None
    name = words[0]
    sub = words[1] if name == "lab" and len(words) > 1 else None
    rb_write = name in RB_WRITE_COMMANDS or (name == "snapshot-point" and len(words) > 1 and words[1] == "restore")
    if rb_write and "--live" in params:
        return LIVE_FLAG_REASON
    dry_run = "--dry-run" in params
    lab_usb_write = sub in USB_LAB_WRITES and not (sub == "usb-image" and (len(words) < 3 or words[2] == "info"))
    if (name in USB_WRITE_COMMANDS or lab_usb_write) and not dry_run:
        if any(protected(p, state.cwd) == "volume" for p in params):
            return VOLUME_REASON
    reading = (name in DJC_READ or (name == "snapshot-point" and len(words) > 1 and words[1] in SNAPSHOT_POINT_READ)
               or sub in LAB_READ)
    if not reading and any(protected(p, state.cwd) == "live" for p in params):
        return LIVE_REASON
    return check_outputs(params, state)


def check_outputs(params, state):
    """--out <보호 경로> 꼴(읽기 명령의 출력 자리도)."""
    for position, value in enumerate(params):
        if value in OUTPUT_OPTIONS and position + 1 < len(params):
            kind = protected(params[position + 1], state.cwd)
        elif value.startswith(tuple(option + "=" for option in OUTPUT_OPTIONS)):
            kind = protected(value, state.cwd)
        else:
            continue
        if kind:
            return reason_for(kind)
    return None


def check_xargs(params, state, piped):
    """xargs 뒤 명령을 본다. 앞 파이프가 보호 경로를 넘기면 그 자리({}·끝 인자)에 보호 경로를 넣어 본다."""
    replace, index = None, 0
    while index < len(params) and params[index].startswith("-"):
        option = params[index]
        index += 1
        if option in ("-I", "-J") and index < len(params):
            replace = params[index]
            index += 1
        elif option.startswith(("-I", "-J")) and len(option) > 2:
            replace = option[2:]
        elif option == "-i" or option.startswith("-i"):
            replace = option[2:] or "{}"
        elif option in ("-n", "-P", "-L", "-s", "-E", "-R", "-S", "-d"):
            index += 1
    inner = params[index:] or ["echo"]
    if piped:
        placeholder = PLACEHOLDER[piped]
        inner = [t.replace(replace, placeholder) for t in inner] if replace else inner + [placeholder]
    return check_segment(inner, state, None, stdin=True)


def check_find(params, state):
    starts, index = [], 0
    while index < len(params) and params[index] in ("-H", "-L", "-P", "-E", "-X", "-d", "-s", "-x", "-f"):
        if params[index] == "-f" and index + 1 < len(params):
            starts.append(params[index + 1])
            index += 1
        index += 1
    while index < len(params) and not params[index].startswith("-") and params[index] not in ("(", "!", ")"):
        starts.append(params[index])
        index += 1
    starts = starts or ["."]
    while index < len(params):
        token = params[index]
        if token == "-delete":
            for start in starts:
                kind = protected(start, state.cwd, removing=True)
                if kind:
                    return reason_for(kind)
        elif token in ("-fprint", "-fprint0", "-fls", "-fprintf") and index + 1 < len(params):
            kind = protected(params[index + 1], state.cwd)
            if kind:
                return reason_for(kind)
        elif token in ("-exec", "-execdir", "-ok", "-okdir"):
            end = index + 1
            while end < len(params) and params[end] not in (";", "+"):
                end += 1
            inner = params[index + 1:end]
            for start in starts:
                path = start if start.startswith("/") else (state.cwd or ".") + "/" + start
                reason = check_segment([t.replace("{}", path + "/x") for t in inner], state, None)
                if reason:
                    return reason
            index = end
        index += 1
    return None


def check_disk(name, params):
    words = operands(params)
    if name == "diskutil" and words:
        if DISKUTIL_WRITES.match(words[0]):
            return DISK_REASON
        if words[0].lower() in DISKUTIL_GROUPS and len(words) > 1 and DISKUTIL_GROUP_WRITES.match(words[1]):
            return DISK_REASON
    if name.startswith(("newfs", "mkfs")):
        return DISK_REASON
    if name == "fdisk" and any(re.match(r"^-[a-zA-Z]*[ieuafry]", p) for p in params):
        return DISK_REASON
    if name == "gpt" and words and words[0] != "show":
        return DISK_REASON
    if name == "asr" and any(p in ("restore", "restoreexact", "-target", "--target", "-erase", "--erase") for p in params):
        return DISK_REASON
    return None


def check_segment(tokens, state, joined, stdin=False):
    """막을 이유 또는 None. 리다이렉션도 본다."""
    assigned, rest = strip_prefix(tokens)
    for assignment in assigned:
        if assignment.startswith("DJC_REKORDBOX_DIR=") and protected(assignment.split("=", 1)[1], state.cwd):
            return DJC_DIR_REASON
    args, index = [], 0
    while index < len(rest):
        token = rest[index]
        target = rest[index + 1] if index + 1 < len(rest) else None
        if token in WRITE_REDIRECTS:
            if target is not None and not (token == ">&" and re.match(r"^(\d+|-)$", target)):
                kind = protected(target, state.cwd)
                if kind:
                    return reason_for(kind)
            index += 2
        elif token in INPUT_REDIRECTS:
            stdin = True
            index += 2
        else:
            args.append(token)
            index += 1
    if not args:
        return None
    if joined in ("|", "|&"):
        stdin = True
    name = os.path.basename(args[0])
    params = args[1:]
    if name in SKIP_HEADS or name == "git":
        return None
    if re.match(r"^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$", args[0]) and operands(params)[:1] and operands(params)[0] in DJC_COMMANDS:
        name = "djc"  # D=.build/debug/djc; $D usb-export … 꼴
    if name == "swift" and params[:1] == ["run"] and "djc" in params:
        name, params = "djc", params[params.index("djc") + 1:]
    if is_code_form(name, params, stdin):
        state.code = True
    if name == "djc":
        return check_djc(params, state)
    if name == "xargs":
        return check_xargs(params, state, None)
    if name == "find":
        return check_find(params, state)
    reason = check_disk(name, params)
    if reason:
        return reason
    reason = check_outputs(params, state)
    if reason:
        return reason
    if name in ANY_ARG_WRITERS:
        for value in operands(params) + [p for p in params if "=" in p]:
            kind = protected(value, state.cwd, removing=name in REMOVERS)
            if kind:
                return reason_for(kind)
    if name in DEST_WRITERS:
        found = operands(params)
        if name == "rsync":
            skipped = {i + 1 for i, p in enumerate(params) if p in RSYNC_VALUE_OPTIONS | RSYNC_WRITE_OPTIONS}
            found = [p for i, p in enumerate(params) if i not in skipped and not p.startswith("-")]
            for i, option in enumerate(params):
                written = params[i + 1] if option in RSYNC_WRITE_OPTIONS and i + 1 < len(params) else (
                    option.split("=", 1)[1] if option.split("=", 1)[0] in RSYNC_WRITE_OPTIONS and "=" in option else None)
                kind = protected(written, state.cwd) if written else None
                if kind:
                    return reason_for(kind)
        if "-t" in params and params.index("-t") + 1 < len(params):
            targets, sources = [params[params.index("-t") + 1]], found
        else:
            targets, sources = found[-1:], found[:-1]
        if name == "rsync" and "--remove-source-files" in params:
            targets = found
        for value in targets:
            kind = protected(value, state.cwd)
            if kind:
                return reason_for(kind)
        if name == "ln" and any(protected(value, state.cwd) in ("live", "volume") for value in sources):
            return LINK_REASON
    if name in INPLACE_EDITORS and any(re.match(r"^-[a-zA-Z]*i", p) or p.startswith("--in-place") for p in params):
        for value in operands(params):
            kind = protected(value, state.cwd)
            if kind:
                return reason_for(kind)
    if name == "dd":
        for value in params:
            if value.startswith("of="):
                kind = protected(value[3:], state.cwd)
                if kind:
                    return reason_for(kind)
    if name == "xattr" and any(re.match(r"^-[a-zA-Z]*[wdc]", p) for p in params):
        for value in operands(params):
            kind = protected(value, state.cwd)
            if kind:
                return reason_for(kind)
    if name in ("tar", "bsdtar", "gtar") and params:
        bundle = params[0].lstrip("-")
        extracting = (re.match(r"^[a-zA-Z]*x", bundle) and not params[0].startswith("--")) or "-x" in params or "--extract" in params
        creating = re.match(r"^[a-zA-Z]*[cru]", bundle) and not params[0].startswith("--") and "f" in bundle
        if extracting:
            target = params[params.index("-C") + 1] if "-C" in params and params.index("-C") + 1 < len(params) else "."
            kind = protected(target, state.cwd)
            if kind:
                return reason_for(kind)
        if creating and len(params) > 1:
            kind = protected(params[1], state.cwd)
            if kind:
                return reason_for(kind)
    if name == "unzip" and not any(p in ("-l", "-t", "-v", "-p", "-Z", "-z") for p in params):
        target = params[params.index("-d") + 1] if "-d" in params and params.index("-d") + 1 < len(params) else "."
        kind = protected(target, state.cwd)
        if kind:
            return reason_for(kind)
    if name in ("curl", "wget"):
        for flag in ("-o", "--output", "-O", "--output-document"):
            if flag in params and params.index(flag) + 1 < len(params):
                kind = protected(params[params.index(flag) + 1], state.cwd)
                if kind:
                    return reason_for(kind)
    return None


def check_command(command, cwd=None, depth=0):
    if depth > 5:
        return None
    full = normalize(command)
    text, docs = split_heredocs(full)
    state = State(cwd)
    for receiver, body, quoted in docs:
        if receiver in SHELLS:
            reason = check_command(body, cwd, depth + 1)
            if reason:
                return reason
        if not quoted:
            for inner in substitutions(body):
                reason = check_command(inner, cwd, depth + 1)
                if reason:
                    return reason
    for inner in substitutions(text):
        reason = check_command(inner, cwd, depth + 1)
        if reason:
            return reason
    tokens = tokenize(split_lines(text))
    if any(t == "--allow-physical" or t.startswith("--allow-physical=") for t in tokens):
        return PHYSICAL_REASON
    piped = None
    for joined, segment in segments(tokens):
        segment = [state.expand(t) for t in segment]
        assigned, rest = strip_prefix(segment)
        if joined not in ("|", "|&"):
            piped = None
        head = rest[0] if rest else ""
        if not rest:
            state.remember(assigned)
        if head == "for" and len(rest) > 3 and rest[2] == "in":
            # for f in /Volumes/X/*; do rm "$f"; done: 목록 중 보호 경로(없으면 첫 값)를 변수 값으로 본다
            items = rest[3:]
            state.variables[rest[1]] = next((i for i in items if protected(i, state.cwd)), items[0])
        if head in ("cd", "chdir", "pushd"):
            if head == "pushd":
                state.stack.append(state.cwd)
            change_directory(next((t for t in rest[1:] if t == "-" or not t.startswith("-")), None), state)
            continue
        if head == "popd":
            state.cwd = state.stack.pop() if state.stack else state.cwd
            continue
        if head == "export":
            exported = [t for t in rest[1:] if "=" in t]
            reason = check_segment(exported, state, joined)
            if reason:
                return reason
            state.remember(exported)
            continue
        reason = check_segment(segment, state, joined)
        if reason:
            return reason
        # ls /Volumes/X | xargs rm 꼴: 앞 파이프 조각의 보호 경로를 xargs가 뒤 명령에 넘긴다
        if piped and rest and os.path.basename(rest[0]) == "xargs":
            reason = check_xargs(rest[1:], state, piped)
            if reason:
                return reason
        kind = next((k for k in (protected(t, state.cwd) for t in rest[1:]) if k), None)
        if kind:
            piped = kind
    for receiver, _, _ in docs:
        if receiver in SHELLS or is_code_form(receiver, [], True):
            state.code = True
    if state.code and PROTECTED_TEXT.search(full):
        return CODE_REASON
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0
    if data.get("tool_name") != "Bash":
        return 0
    command = (data.get("tool_input") or {}).get("command") or ""
    cwd = data.get("cwd") or None
    # 빠른 길: 보호 경로·쓰기 동의·디스크 도구 낱말이 없고 지금 폴더도 보호 폴더가 아니면 볼 것이 없다
    if not FAST_PATH.search(normalize(command)) and not (cwd and kind_of(canonical(cwd, None))):
        return 0
    reason = check_command(command, cwd)
    if reason:
        print(f"막음(scripts/hooks/guard-bash.py): {reason}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
