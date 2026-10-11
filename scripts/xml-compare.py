#!/usr/bin/env python3
"""rekordbox가 직접 내보낸 XML(File › Export Collection in xml format)과 `djc xml-export` 결과를 칸 단위로 견준다(#72).
기본은 값을 찍지 않고 개수만 낸다(결과를 공유해도 곡 정보가 새지 않게). `--examples N`을 주면 이 Mac에서만 보려고 칸마다 값 N개를 찍는다.

사용(둘 다 같은 시점의 라이브러리여야 한다 — rekordbox를 종료한 상태에서 내보내고 `djc snapshot`을 뜬다):
  python3 -I scripts/xml-compare.py <rekordbox가 만든.xml> <djc xml-export가 만든.xml> [--examples N]

곡은 Location(NFC·퍼센트 디코딩)으로 짝짓는다. 비교하는 것:
  - 곡 수, 한쪽에만 있는 곡, TrackID가 같은 곡(djc는 ContentID를 TrackID로 쓴다)
  - TRACK 속성별: 같음 / 다름 / A에만 / B에만(빈 글자는 없음으로 본다. 숫자·시각은 오차 안쪽이면 같다)
  - TEMPO(Inizio·Bpm·Battito·Metro)와 POSITION_MARK(Type·Start·End·Num·Name 외 칸도) 곡 단위
  - 재생 목록 트리: 경로(폴더 이름 이어 붙임)별 짝, 곡 순서(Location 순서)까지 같은지
A = rekordbox가 만든 파일, B = djc가 만든 파일. 종료 코드: 0 차이 없음, 1 차이 있음, 2 읽지 못함.
"""

import argparse
import sys
import unicodedata
import urllib.parse
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict

TIME_TOLERANCE = 0.0015
NUMBER_TOLERANCE = 0.005
TIME_ATTRIBUTES = {"Inizio", "Start", "End"}
NUMBER_ATTRIBUTES = {"AverageBpm", "Bpm"}


def normalize_location(location):
    for prefix in ("file://localhost", "file://"):
        if location.startswith(prefix):
            location = location[len(prefix):]
            break
    return unicodedata.normalize("NFC", urllib.parse.unquote(location))


def load(path):
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as error:
        print(f"읽지 못했습니다: {path}: {error}", file=sys.stderr)
        sys.exit(2)
    collection = root.find("COLLECTION")
    if collection is None:
        print(f"COLLECTION이 없습니다: {path}", file=sys.stderr)
        sys.exit(2)
    tracks, duplicates = {}, 0
    for track in collection.findall("TRACK"):
        key = normalize_location(track.get("Location", ""))
        if key in tracks:
            duplicates += 1
        else:
            tracks[key] = track
    return root, tracks, duplicates


def same_value(name, a, b):
    if name in TIME_ATTRIBUTES:
        return abs(float(a) - float(b)) <= TIME_TOLERANCE
    if name in NUMBER_ATTRIBUTES:
        return abs(float(a) - float(b)) <= NUMBER_TOLERANCE
    return a == b


def safe_same(name, a, b):
    try:
        return same_value(name, a, b)
    except ValueError:
        return a == b


class Report:
    def __init__(self, examples):
        self.examples = examples
        self.differences = 0
        self.shown = defaultdict(int)

    def difference(self, label, detail=None):
        self.differences += 1
        if detail is not None and self.shown[label] < self.examples:
            self.shown[label] += 1
            print(f"    예 {label}: {detail}")


def compare_attributes(report, a_tracks, b_tracks, common):
    print("\n[TRACK 속성] 짝지은 곡 기준 — 같음 / 다름 / A에만 / B에만")
    names = set()
    for key in common:
        names |= set(a_tracks[key].attrib) | set(b_tracks[key].attrib)
    for name in sorted(names):
        counts = Counter()
        for key in common:
            a, b = a_tracks[key].get(name) or "", b_tracks[key].get(name) or ""
            if not a and not b:
                continue
            if not b:
                counts["a_only"] += 1
                report.differences += 1
            elif not a:
                counts["b_only"] += 1
                report.differences += 1
            elif safe_same(name, a, b):
                counts["same"] += 1
            else:
                counts["different"] += 1
                report.difference(name, f"A={a!r} B={b!r}")
        if sum(counts.values()) == 0:
            continue
        print(f"  {name:<12} {counts['same']:>6} / {counts['different']:>6} / {counts['a_only']:>6} / {counts['b_only']:>6}")
    print("  (Location은 짝짓는 기준이라 같다. A에만이 많은 칸은 djc가 넣지 않는 칸이다 — docs/cli.md의 \"넣지 않는 것\")")


def mark_key(mark):
    return (mark.get("Type"), round(float(mark.get("Start", "0")), 3), round(float(mark.get("End", "-1")), 3),
            mark.get("Num"), mark.get("Name", ""))


def compare_children(report, a_tracks, b_tracks, common):
    tempo_same = tempo_diff = mark_same = mark_diff = 0
    extra = Counter()
    for key in common:
        a, b = a_tracks[key], b_tracks[key]
        a_tempos = [(float(t.get("Inizio", "0")), float(t.get("Bpm", "0")), t.get("Battito"), t.get("Metro")) for t in a.findall("TEMPO")]
        b_tempos = [(float(t.get("Inizio", "0")), float(t.get("Bpm", "0")), t.get("Battito"), t.get("Metro")) for t in b.findall("TEMPO")]
        if len(a_tempos) == len(b_tempos) and all(
                abs(x[0] - y[0]) <= TIME_TOLERANCE and abs(x[1] - y[1]) <= NUMBER_TOLERANCE and x[2:] == y[2:]
                for x, y in zip(a_tempos, b_tempos)):
            tempo_same += 1
        else:
            tempo_diff += 1
            report.difference("TEMPO", f"A={a_tempos[:3]} B={b_tempos[:3]}")
        a_marks, b_marks = a.findall("POSITION_MARK"), b.findall("POSITION_MARK")
        for mark in a_marks:
            for name in mark.attrib:
                if name not in ("Name", "Type", "Start", "End", "Num"):
                    extra[name] += 1
        if sorted(map(mark_key, a_marks)) == sorted(map(mark_key, b_marks)):
            mark_same += 1
        else:
            mark_diff += 1
            only_a = Counter(map(mark_key, a_marks)) - Counter(map(mark_key, b_marks))
            only_b = Counter(map(mark_key, b_marks)) - Counter(map(mark_key, a_marks))
            report.difference("POSITION_MARK", f"A에만 {sorted(only_a)[:3]} B에만 {sorted(only_b)[:3]}")
    print(f"\n[TEMPO] 곡 단위 같음 {tempo_same} / 다름 {tempo_diff}")
    print(f"[POSITION_MARK] 곡 단위 같음 {mark_same} / 다름 {mark_diff}")
    if extra:
        print("  A(rekordbox)의 POSITION_MARK에만 있는 칸(djc가 넣지 않음): "
              + ", ".join(f"{name} {count}개" for name, count in sorted(extra.items())))


def flatten_playlists(root, id_to_location, location_key):
    lists = {}
    top = root.find("PLAYLISTS")
    if top is None or top.find("NODE") is None:
        return lists

    def walk(node, path):
        seen = Counter()
        for child in node.findall("NODE"):
            name = child.get("Name", "")
            seen[name] += 1
            label = name if seen[name] == 1 else f"{name} #{seen[name]}"
            here = path + (label,)
            if child.get("Type") == "0":
                lists[here] = ("folder", None)
                walk(child, here)
            else:
                by_location = child.get("KeyType") == "1"
                entries = []
                for track in child.findall("TRACK"):
                    key = track.get("Key", "")
                    entries.append(normalize_location(key) if by_location else id_to_location.get(key))
                lists[here] = ("list", entries)

    walk(top.find("NODE"), ())
    return lists


def compare_playlists(report, a_root, b_root, a_tracks, b_tracks):
    def ids(tracks):
        return {track.get("TrackID"): key for key, track in tracks.items()}

    a_lists = flatten_playlists(a_root, ids(a_tracks), None)
    b_lists = flatten_playlists(b_root, ids(b_tracks), None)
    both = set(a_lists) & set(b_lists)
    only_a, only_b = set(a_lists) - both, set(b_lists) - both
    kinds_differ = [p for p in both if a_lists[p][0] != b_lists[p][0]]
    order_same = order_diff = 0
    for path in sorted(both):
        if a_lists[path][0] == "list" and b_lists[path][0] == "list":
            if a_lists[path][1] == b_lists[path][1]:
                order_same += 1
            else:
                order_diff += 1
                report.difference("재생 목록 곡", "/".join(path))
    print(f"\n[재생 목록 트리] 경로 짝 {len(both)} / A에만 {len(only_a)} / B에만 {len(only_b)} / 폴더·목록 종류 다름 {len(kinds_differ)}")
    print(f"  곡 순서까지 같은 목록 {order_same} / 다른 목록 {order_diff}")
    print("  (A에만 있는 목록은 보통 djc가 넣지 않는 인텔리전트 목록이다)")
    report.differences += len(only_a) + len(only_b) + len(kinds_differ)
    for path in sorted(only_a)[:report.examples]:
        print(f"    예 A에만: {'/'.join(path)}")
    for path in sorted(only_b)[:report.examples]:
        print(f"    예 B에만: {'/'.join(path)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("rekordbox_xml", help="A: rekordbox가 만든 XML")
    parser.add_argument("djc_xml", help="B: djc xml-export가 만든 XML")
    parser.add_argument("--examples", type=int, default=0, help="칸마다 값 예를 N개 찍는다(기본 0: 값을 찍지 않는다)")
    args = parser.parse_args()
    a_root, a_tracks, a_dupes = load(args.rekordbox_xml)
    b_root, b_tracks, b_dupes = load(args.djc_xml)
    report = Report(args.examples)
    common = sorted(set(a_tracks) & set(b_tracks))
    print(f"[곡] A {len(a_tracks)} / B {len(b_tracks)} / 짝 {len(common)} / A에만 {len(set(a_tracks) - set(b_tracks))} / "
          f"B에만 {len(set(b_tracks) - set(a_tracks))} (Location 중복 A {a_dupes} · B {b_dupes})")
    report.differences += len(set(a_tracks) ^ set(b_tracks))
    same_id = sum(1 for key in common if a_tracks[key].get("TrackID") == b_tracks[key].get("TrackID"))
    print(f"  TrackID가 같은 곡 {same_id}/{len(common)}")
    compare_attributes(report, a_tracks, b_tracks, common)
    compare_children(report, a_tracks, b_tracks, common)
    compare_playlists(report, a_root, b_root, a_tracks, b_tracks)
    print(f"\n차이 {report.differences}")
    sys.exit(0 if report.differences == 0 else 1)


if __name__ == "__main__":
    main()
