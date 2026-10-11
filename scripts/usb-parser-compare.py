#!/usr/bin/env python3
"""DJCrate USB 리더 결과를 외부 파서와 표·행·칸 단위로 대조한다(#189). 값은 찍지 않는다.

- Device Library(export.pdb·exportExt.pdb) ↔ rekordcrate `dump-pdb --format json --parse-unknown-tables`
- OneLibrary(exportLibrary.db) ↔ pyrekordbox `DeviceLibraryPlus`(이 스크립트를 pyrekordbox가 깔린 python으로 돌린다)

DJCrate 쪽은 `djc lab usb-fields <USB 폴더> --out <JSON>`이 쓴 칸 해시다. 외부 파서 값을 같은 정규형으로 해시해 견준다.
외부 파서 코드는 저장소에 넣지 않는다. 두 파서는 임시 폴더에 받아 돌린다(절차는 docs/usb-internals.md §8.2).

사용:
  <python> scripts/usb-parser-compare.py --djc <usb-fields JSON> --usb <USB 사본 폴더>
      [--rekordcrate <실행 파일>] [--only dl|ol] [--work <임시 폴더>] [--positions N] [--no-keys]

출력: 표마다 행 수·짝지은 행·비교한 칸·다른 칸 이름과 수, 차이 위치(형식·표·행 키·칸), 마지막 줄 "차이 N".
종료 코드: 0 차이 없음, 1 차이 있음(또는 행이 있는데 비교한 칸이 0인 표), 2 준비 실패.
"""

import argparse
import hashlib
import json
import logging
import os
import shutil
import subprocess
import sys
import tempfile

# 정규형: 글자 s:<값>(NFC로 바꾸지 않음), 정수 i:<10진>, 없음 n, 참거짓 b:1|0, 목록 l:<a,b,…>, 형식 e:<이름>
SELF_CHECK = ("s:시험 곡 1", "e7918c99dd3a6fb6")


def digest(canonical):
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:16]


def S(value):
    return "s:" + value


def I(value):
    return "i:%d" % value


def B(value):
    return "b:1" if value else "b:0"


def L(values):
    return "l:" + ",".join(str(v) for v in values)


NIL = "n"


def ref(value):
    """pdb id 칸: 0 = 없음"""
    return NIL if value == 0 else I(value)


def opt_s(value):
    return NIL if value is None else S(value)


def opt_i(value):
    return NIL if value is None else I(value)


def unwrap_menu(name):
    return name.replace("￺", "").replace("￻", "")


class Result:
    def __init__(self, show_keys):
        self.lines = []
        self.positions = []
        self.differences = 0
        self.failures = 0
        self.show_keys = show_keys
        self.transformed = {}
        self.skipped = {}

    def table(self, fmt, table, djc_rows, ext_rows, transformed=()):
        """djc_rows: 행 키 → 칸 → 해시(DJCrate), ext_rows: 행 키 → 칸 → 정규형(외부 파서). 외부 쪽에 없는 DJCrate 칸은 비교하지 않는다."""
        djc_keys, ext_keys = set(djc_rows), set(ext_rows)
        matched = djc_keys & ext_keys
        compared = 0
        differing = {}
        for key in sorted(matched, key=sort_key):
            djc, ext = djc_rows[key], ext_rows[key]
            for field, canonical in sorted(ext.items()):
                if field not in djc:
                    differing[field + "(DJCrate에 없음)"] = differing.get(field + "(DJCrate에 없음)", 0) + 1
                    self.position(fmt, table, key, field + "(DJCrate에 없음)")
                    continue
                compared += 1
                if digest(canonical) != djc[field]:
                    differing[field] = differing.get(field, 0) + 1
                    self.position(fmt, table, key, field)
        for key in sorted(djc_keys - ext_keys, key=sort_key):
            self.position(fmt, table, key, "(외부 파서에 행 없음)")
        for key in sorted(ext_keys - djc_keys, key=sort_key):
            self.position(fmt, table, key, "(DJCrate에 행 없음)")
        missing = len(djc_keys - ext_keys) + len(ext_keys - djc_keys)
        count = missing + sum(differing.values())
        self.differences += count
        line = "%s %s: 행 %d/%d, 짝 %d, 칸 %d 비교" % (fmt, table, len(djc_rows), len(ext_rows), len(matched), compared)
        if differing:
            line += ", 다른 칸: " + " ".join("%s×%d" % (k, v) for k, v in sorted(differing.items()))
        if missing:
            line += ", 짝 없는 행 %d" % missing
        if (djc_rows or ext_rows) and compared == 0:
            line += " — 비교한 칸 0(실패)"
            self.failures += 1
        self.lines.append(line)
        djc_fields = set().union(*[set(r) for r in djc_rows.values()]) if djc_rows else set()
        not_compared = sorted(djc_fields - set().union(*[set(r) for r in ext_rows.values()])) if ext_rows else sorted(djc_fields)
        if not_compared:
            self.skipped["%s %s" % (fmt, table)] = not_compared
        if transformed:
            self.transformed["%s %s" % (fmt, table)] = sorted(transformed)

    def count_only(self, fmt, table, djc_count, ext_count):
        line = "%s %s: 행 %d/%d(칸 대조 없음, 외부 파서가 해석하지 않는 표)" % (fmt, table, djc_count, ext_count)
        if djc_count != ext_count:
            line += " — 행 수 다름"
            self.differences += 1
            self.position(fmt, table, "-", "행 수")
        self.lines.append(line)

    def structure(self, fmt, name, ok_fields, differing):
        count = sum(differing.values())
        self.differences += count
        line = "%s 구조 %s: 칸 %d 비교" % (fmt, name, ok_fields + count)
        if differing:
            line += ", 다른 칸: " + " ".join("%s×%d" % (k, v) for k, v in sorted(differing.items()))
        if ok_fields + count == 0:
            line += " — 비교한 칸 0(실패)"
            self.failures += 1
        self.lines.append(line)

    def note(self, line):
        self.lines.append(line)

    def position(self, fmt, table, key, field):
        self.positions.append("%s %s[%s].%s" % (fmt, table, key if self.show_keys else "…", field))


def sort_key(key):
    head = key.split(":")[0].split("#")[0]
    return (0, int(head), key) if head.lstrip("-").isdigit() else (1, 0, key)


# MARK: - Device Library ↔ rekordcrate

PLAIN_TYPES = {"Tracks": 0, "Genres": 1, "Artists": 2, "Albums": 3, "Labels": 4, "Keys": 5, "Colors": 6, "PlaylistTree": 7,
               "PlaylistEntries": 8, "HistoryPlaylists": 11, "HistoryEntries": 12, "Artwork": 13, "Columns": 16, "Menu": 17,
               "History": 19}
EXT_TYPES = {"Tag": 3, "TrackTag": 4}
COLORS = {"None": 0, "Pink": 1, "Red": 2, "Orange": 3, "Yellow": 4, "Green": 5, "Aqua": 6, "Blue": 7, "Purple": 8}
FILE_TYPES = {"Unknown": 0, "Mp3": 1, "M4a": 4, "Flac": 5, "Wav": 0x0B, "Aiff": 0x0C}


def enum_number(value, names):
    """rekordcrate 열거 이름 → 숫자. `{"Other": n}`·`{"Unknown": n}` 모양은 n"""
    if isinstance(value, dict):
        return list(value.values())[0]
    return names[value]


def page_type_number(page_type):
    kind, value = list(page_type.items())[0]
    if kind == "Unknown":
        return value
    return (PLAIN_TYPES if kind == "Plain" else EXT_TYPES)[value]


def run_rekordcrate(binary, path, work):
    copy = os.path.join(work, os.path.basename(path))
    shutil.copyfile(path, copy)
    output = subprocess.run([binary, "dump-pdb", "--parse-unknown-tables", "--format", "json", copy],
                            capture_output=True, check=False)
    if output.returncode != 0:
        # 오류 문구에 값이 들 수 있어 길이만 남긴다
        raise SystemExit("rekordcrate 실패(%s, 종료 코드 %d, 오류 %d바이트)" % (os.path.basename(path), output.returncode,
                                                                             len(output.stderr)))
    return json.loads(output.stdout)


def rekordcrate_rows(dump):
    """표 번호 → [(쪽 번호, 오프셋, 행 내용)], 표 번호 → 표 덤프"""
    rows, tables = {}, {}
    for table in dump["tables"]:
        number = page_type_number(table["page_type"])
        tables[number] = table
        found = rows.setdefault(number, [])
        for page in table["pages"]:
            content = page["content"]
            if "Data" in content:
                for offset, row in sorted(content["Data"]["rows"].items(), key=lambda item: int(item[0])):
                    found.append((page["header"]["page_index"], int(offset), row))
    return rows, tables


def compare_structure(result, fmt, name, djc_file, dump):
    header, rc = djc_file["header"], dump["header"]
    differing, ok = {}, 0

    def check(field, left, right):
        nonlocal ok
        if left == right:
            ok += 1
        else:
            differing[field] = differing.get(field, 0) + 1
            result.position(fmt, "구조 " + name, "-", field)

    for field, rc_field in [("pageSize", "page_size"), ("numTables", "num_tables"), ("nextUnusedPage", "next_unused_page"),
                            ("flag10", "unknown"), ("sequence", "sequence")]:
        check("머리." + field, header[field], rc[rc_field])
    check("머리.표 수", len(header["tables"]), len(rc["tables"]))
    for djc_pointer, rc_pointer in zip(header["tables"], rc["tables"]):
        check("표 포인터.type", djc_pointer["type"], page_type_number(rc_pointer["page_type"]))
        for field, rc_field in [("emptyCandidate", "empty_candidate"), ("firstPage", "first_page"), ("lastPage", "last_page")]:
            check("표 포인터." + field, djc_pointer[field], rc_pointer[rc_field])
    rc_tables = {page_type_number(t["page_type"]): t for t in dump["tables"]}
    for table in djc_file["tables"]:
        rc_table = rc_tables.get(table["type"])
        if rc_table is None:
            check("표 덤프 없음", True, False)
            continue
        check("쪽 사슬", [p["index"] for p in table["pages"]], [p["header"]["page_index"] for p in rc_table["pages"]])
        for page, rc_page in zip(table["pages"], rc_table["pages"]):
            ph = rc_page["header"]
            pairs = [("next", ph["next_page"]), ("sequence", ph["unknown1"]), ("u2", ph["unknown2"]),
                     ("slots", ph["packed_row_counts"]["num_rows"]), ("live", ph["packed_row_counts"]["num_rows_valid"]),
                     ("flags", ph["page_flags"]["bytes"][0]), ("free", ph["free_size"]), ("used", ph["used_size"])]
            content = rc_page["content"]
            check("쪽.isIndex", page["isIndex"], "Index" in content)
            if "Data" in content:
                dh = content["Data"]["header"]
                pairs += [("txRowCount", dh["unknown5"]), ("txRowIndex", dh["unknown_not_num_rows_large"]), ("u6", dh["unknown6"]),
                          ("u7", dh["unknown7"])]
                check("쪽.liveOffsets", page["liveOffsets"], sorted(int(k) for k in content["Data"]["rows"]))
            for field, value in pairs:
                check("쪽." + field, page[field], value)
    result.structure(fmt, name, ok, differing)


def compare_device_library(result, djc, usb, binary, work):
    fmt = "DL"
    folder = os.path.join(usb, "PIONEER", "rekordbox")
    dumps = {}
    for name in ["export.pdb", "exportExt.pdb"]:
        path = os.path.join(folder, name)
        if os.path.exists(path):
            dumps[name] = run_rekordcrate(binary, path, work)
            compare_structure(result, fmt, name, djc["files"][name], dumps[name])
    tables = djc["tables"]
    rows, _ = rekordcrate_rows(dumps["export.pdb"])
    ext_rows = rekordcrate_rows(dumps["exportExt.pdb"])[0] if "exportExt.pdb" in dumps else {}

    def plain(number, kind):
        return [(page, offset, row["Plain"][kind]) for page, offset, row in rows.get(number, [])]

    tracks, extras = {}, {}
    for _, _, t in plain(0, "Track"):
        s = t["offsets"]["inner"]
        key = str(t["id"])
        tracks[key] = {
            "id": I(t["id"]), "title": S(s["title"]), "subtitle": S(s["mix_name"]), "bpmx100": I(t["tempo"]),
            "lengthSeconds": I(t["duration"]), "trackNo": I(t["track_number"]), "discNo": I(t["disc_number"]),
            "artistID": ref(t["artist_id"]), "remixerID": ref(t["remixer_id"]), "originalArtistID": ref(t["orig_artist_id"]),
            "composerID": ref(t["composer_id"]), "lyricist": S(s["lyricist"]), "albumID": ref(t["album_id"]),
            "genreID": ref(t["genre_id"]), "labelID": ref(t["label_id"]), "keyID": ref(t["key_id"]),
            "colorID": I(enum_number(t["color"], COLORS)), "imageID": ref(t["artwork_id"]), "comment": S(s["comment"]),
            "rating": I(t["rating"]), "releaseYear": I(t["year"]), "releaseDate": S(s["release_date"]),
            # 문자열 10·15: rekordcrate 이름은 date_added·analyze_date, DJCrate는 dateCreated·dateAdded(번호로 맞춘다)
            "dateCreated": S(s["date_added"]), "dateAdded": S(s["analyze_date"]), "path": S(s["file_path"]),
            "fileName": S(s["filename"]), "fileSize": I(t["file_size"]), "fileType": I(enum_number(t["file_type"], FILE_TYPES)),
            "bitrate": I(t["bitrate"]), "bitDepth": I(t["sample_depth"]), "sampleRate": I(t["sample_rate"]), "isrc": S(s["isrc"]),
            "djPlayCount": I(t["play_count"]), "hotCueAutoLoad": B(s["autoload_hotcues"] == "ON"),
            "kuvoDeliver": B(s["publish_track_information"] == "ON"),
            # 0x14 u32 = rekordcrate unknown2, 0x18 u32 = unknown3(u16) + unknown4(u16) << 16
            "masterDbId": I(t["unknown3"] | t["unknown4"] << 16), "masterContentId": I(t["unknown2"]),
            "analysisDataPath": S(s["analyze_path"]), "cueUpdateCount": S(s["unknown_string4"]),
            "analysisDataUpdateCount": S(s["unknown_string3"]), "informationUpdateCount": S(s["unknown_string2"]),
            "deviceFields.deviceLibrary.rating": I(t["rating"]), "deviceFields.deviceLibrary.playCount": I(t["play_count"]),
        }
        extras[key] = {
            "subtype": I(t["subtype"]), "bitmask": I(t["bitmask"]), "u5": I(t["unknown5"]),
            # 0x5C는 rekordcrate에서 문자열 오프셋 배열의 magic 3이다(읽혔다면 3)
            "u7": I(3), "unknownStrings.5": S(s["message"]), "unknownStrings.8": S(s["unknown_string5"]),
            "unknownStrings.9": S(s["unknown_string6"]), "unknownStrings.13": S(s["unknown_string7"]),
            "unknownStrings.18": S(s["unknown_string8"]), "flagStrings.6": S(s["publish_track_information"]),
            "flagStrings.7": S(s["autoload_hotcues"]),
        }
    result.table(fmt, "tracks", tables.get("tracks", {}), tracks, transformed=["0 → 없음(id 칸)", "\"ON\" → 참"])
    result.table(fmt, "trackRowExtras", tables.get("trackRowExtras", {}), extras)

    def named(number, kind, name_of=lambda r: r["name"]):
        return {str(r["id"]): {"id": I(r["id"]), "name": S(name_of(r))} for _, _, r in plain(number, kind)}

    result.table(fmt, "genres", tables.get("genres", {}), named(1, "Genre"))
    result.table(fmt, "labels", tables.get("labels", {}), named(4, "Label"))
    result.table(fmt, "artists", tables.get("artists", {}), named(2, "Artist", lambda r: r["offsets"]["inner"]["name"]))
    albums = {str(r["id"]): {"id": I(r["id"]), "name": S(r["offsets"]["inner"]["name"]), "artistID": ref(r["artist_id"])}
              for _, _, r in plain(3, "Album")}
    result.table(fmt, "albums", tables.get("albums", {}), albums)
    result.table(fmt, "keys", tables.get("keys", {}), named(5, "Key"))
    colors = {}
    for _, _, r in plain(6, "Color"):
        # DJCrate는 u16 @0x05, rekordcrate는 u8 @0x05(color) + u16 @0x06(unknown3)
        number = enum_number(r["color"], COLORS) | (r["unknown3"] & 0xFF) << 8
        colors[str(number)] = {"id": I(number), "name": S(r["name"])}
    result.table(fmt, "colors", tables.get("colors", {}), colors)
    result.table(fmt, "images", tables.get("images", {}),
                 {str(r["id"]): {"id": I(r["id"]), "pdbPath": S(r["path"])} for _, _, r in plain(13, "Artwork")})

    def ordered(entries, owner):
        # entry_index 순, 같으면 읽은 순서(쪽 사슬·오프셋)
        found = [(e["entry_index"], position, e["track_id"]) for position, e in enumerate(entries) if e[owner] is not None]
        return [track for _, _, track in sorted(found)]

    entries = [r for _, _, r in plain(8, "PlaylistEntry")]
    playlists = {}
    for _, _, r in plain(7, "PlaylistTreeNode"):
        mine = [e for e in entries if e["playlist_id"] == r["id"]]
        playlists[str(r["id"])] = {
            "id": I(r["id"]), "name": S(r["name"]), "parentID": I(r["parent_id"]), "attribute": I(1 if r["node_is_folder"] else 0),
            "sortOrder.deviceLibrary": I(r["sort_order"]), "entries.deviceLibrary": L(ordered(mine, "track_id")),
        }
    result.table(fmt, "playlists", tables.get("playlists", {}), playlists)
    history_entries = [r for _, _, r in plain(12, "HistoryEntry")]
    histories = {}
    for _, _, r in plain(11, "HistoryPlaylist"):
        mine = [e for e in history_entries if e["playlist_id"] == r["id"]]
        histories[str(r["id"])] = {"id": I(r["id"]), "name": S(r["name"]), "format": "e:deviceLibrary",
                                   "entries": L(ordered(mine, "track_id"))}
    result.table(fmt, "histories", tables.get("histories", {}), histories)
    menu_items = {str(r["id"]): {"id": I(r["id"]), "kind": I(r["unknown0"]), "name": S(unwrap_menu(r["column_name"]))}
                  for _, _, r in plain(16, "ColumnEntry")}
    result.table(fmt, "menuItems", tables.get("menuItems", {}), menu_items, transformed=["이름의 U+FFFA·U+FFFB 떼기"])
    categories = {}
    for _, _, r in plain(17, "Menu"):
        disable = enum_number(r["visibility"], {"Visible": 0, "Hidden": 1})
        categories[str(r["content_pointer"])] = {
            "id": I(r["content_pointer"]), "menuItemID": I(r["category_id"]), "sequenceNo": I(r["sort_order"]),
            "infoOrder": I(r["unknown"]), "disable": I(disable), "isVisible": B(disable != 1),
        }
    result.table(fmt, "categories", tables.get("categories", {}), categories, transformed=["보임 = Disable ≠ 1"])
    result.count_only(fmt, "sorts(표 18)", len(tables.get("sorts", {})), len(rows.get(18, [])))
    properties = [r["Plain"]["History"] for _, _, r in rows.get(19, [])]
    prop = {}
    if properties:
        p = properties[0]
        prop["0"] = {"numberOfContents": I(p["num_tracks"]), "pdbDate": S(p["date"]), "dbVersion": S(p["version"]),
                     "pdbDeviceName": S(p["label"])}
    result.table(fmt, "property(표 19)", tables.get("property", {}), prop)
    unknown = {}
    for key, row in tables.get("unknownRows", {}).items():
        file, number = key.split(":")
        source = rows if file == "export.pdb" else ext_rows
        unknown[key] = {"liveRows": I(len(source.get(int(number), [])))}
    result.table(fmt, "unknownRows", tables.get("unknownRows", {}), unknown)

    tags = {}
    for _, _, row in ext_rows.get(3, []):
        r = row["Ext"]["Tag"]
        tags[str(r["id"])] = {
            "id": I(r["id"]), "parentID": I(r["parent_id"] or 0), "sequenceNo": I(r["position"]),
            "name": S(r["offsets"]["inner"]["name"]),
            # DJCrate는 u8 @0x1B == 1, rekordcrate는 u32 @0x18(raw_is_category)
            "isCategory": B((r["raw_is_category"] >> 24) & 0xFF == 1),
        }
    result.table(fmt, "myTags", tables.get("myTags", {}), tags)
    links = {}
    for _, _, row in ext_rows.get(4, []):
        r = row["Ext"]["TrackTag"]
        key = "%d:%d" % (r["tag_id"], r["track_id"])
        copy = 2
        while key in links:
            key = "%d:%d#%d" % (r["tag_id"], r["track_id"], copy)
            copy += 1
        links[key] = {"myTagID": I(r["tag_id"]), "contentID": I(r["track_id"])}
    result.table(fmt, "myTagLinks", tables.get("myTagLinks", {}), links)
    result.count_only(fmt, "my_tag_property(exportExt 표 7)", 1 if tables.get("property") else 0, len(ext_rows.get(7, [])))


# MARK: - OneLibrary ↔ pyrekordbox

def schema_tables(path):
    """고정 스키마의 표 이름(정의 순서) → 칸 이름"""
    tables = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("CREATE TABLE "):
                head, body = line[len("CREATE TABLE "):].split("(", 1)
                columns = [part.strip().split()[0] for part in body.rsplit(")", 1)[0].split(",")]
                tables[head.strip()] = columns
    return tables


def compare_one_library(result, djc, usb, work, schema_path):
    fmt = "OL"
    logging.getLogger("pyrekordbox").setLevel(logging.WARNING)
    from pyrekordbox.devicelib_plus import DeviceLibraryPlus, models
    from sqlalchemy import inspect as sa_inspect, text

    source = os.path.join(usb, "PIONEER", "rekordbox", "exportLibrary.db")
    copy = os.path.join(work, "exportLibrary.db")
    for suffix in ["", "-wal", "-journal"]:
        if os.path.exists(source + suffix):
            shutil.copyfile(source + suffix, copy + suffix)
    db = DeviceLibraryPlus(copy)
    try:
        schema = schema_tables(schema_path)
        mapped = {cls.__tablename__: [c.name for c in sa_inspect(cls).columns] for cls in models.Base.__subclasses__()}
        diff = []
        for table, columns in schema.items():
            if table not in mapped:
                diff.append("%s 표 없음" % table)
                continue
            missing = [c for c in columns if c not in mapped[table]]
            extra = [c for c in mapped[table] if c not in columns]
            if missing or extra:
                diff.append("%s 칸 없음 %s 남는 칸 %s" % (table, missing, extra))
        result.note("OL pyrekordbox 모델 ↔ 고정 스키마: " + ("같음" if not diff else "; ".join(diff)))

        raw = {}
        for row in db.session.execute(text("SELECT content_id, releaseDate, dateCreated, dateAdded FROM content")):
            raw[row[0]] = row[1:]

        def text_of(value):
            return "" if value is None else str(value)

        tables = djc["tables"]
        tracks = {}
        for c in db.get_content().all():
            release, created, added = raw[c.content_id]
            tracks[str(c.content_id)] = {
                "id": I(c.content_id), "title": S(c.title or ""), "titleForSearch": opt_s(c.titleForSearch),
                "subtitle": S(c.subtitle or ""), "bpmx100": I(c.bpmx100 or 0), "lengthSeconds": I(c.length or 0),
                "trackNo": I(c.trackNo or 0), "discNo": I(c.discNo or 0), "artistID": opt_i(c.artist_id_artist),
                "remixerID": opt_i(c.artist_id_remixer), "originalArtistID": opt_i(c.artist_id_originalArtist),
                "composerID": opt_i(c.artist_id_composer), "lyricistArtistID": opt_i(c.artist_id_lyricist),
                "albumID": opt_i(c.album_id), "genreID": opt_i(c.genre_id), "labelID": opt_i(c.label_id), "keyID": opt_i(c.key_id),
                "colorID": I(c.color_id or 0), "imageID": opt_i(c.image_id), "comment": S(c.djComment or ""),
                "rating": I(c.rating or 0), "releaseYear": I(c.releaseYear or 0),
                # pyrekordbox는 날짜 칸을 datetime으로 바꾸므로 같은 연결에서 원래 글자로 읽는다
                "releaseDate": S(release or ""), "dateCreated": S(created or ""), "dateAdded": S(added or ""),
                "path": S(c.path or ""), "fileName": S(c.fileName or ""), "fileSize": I(c.fileSize or 0),
                "fileType": I(c.fileType or 0), "bitrate": I(c.bitrate or 0), "bitDepth": I(c.bitDepth or 0),
                "sampleRate": I(c.samplingRate or 0), "isrc": S(c.isrc or ""), "djPlayCount": I(c.djPlayCount or 0),
                "hotCueAutoLoad": B((c.isHotCueAutoLoadOn or 0) != 0), "kuvoDeliver": B((c.isKuvoDeliverStatusOn or 0) != 0),
                "kuvoDeliveryComment": S(c.kuvoDeliveryComment or ""), "masterDbId": I(c.masterDbId or 0),
                "masterContentId": I(c.masterContentId or 0), "analysisDataPath": S(c.analysisDataFilePath or ""),
                "analysedBits": I(c.analysedBits or 0), "contentLink": I(c.contentLink or 0), "hasModified": I(c.hasModified or 0),
                "cueUpdateCount": S(text_of(c.cueUpdateCount)), "analysisDataUpdateCount": S(text_of(c.analysisDataUpdateCount)),
                "informationUpdateCount": S(text_of(c.informationUpdateCount)),
                "deviceFields.oneLibrary.rating": I(c.rating or 0), "deviceFields.oneLibrary.playCount": I(c.djPlayCount or 0),
                "deviceFields.oneLibrary.hasModified": I(c.hasModified or 0),
            }
        result.table(fmt, "tracks", tables.get("tracks", {}), tracks,
                     transformed=["title·subtitle 등 글자 NULL → \"\"", "id 칸 NULL → 없음", "그 밖의 정수 NULL → 0(문서에 없음, 코드 기준)",
                                  "갱신 횟수: INTEGER → 10진 글자, NULL → \"\""])
        result.table(fmt, "artists", tables.get("artists", {}),
                     {str(a.artist_id): {"id": I(a.artist_id), "name": S(a.name or ""), "nameForSearch": opt_s(a.nameForSearch)}
                      for a in db.get_artist().all()})
        result.table(fmt, "albums", tables.get("albums", {}),
                     {str(a.album_id): {"id": I(a.album_id), "name": S(a.name or ""), "artistID": opt_i(a.artist_id),
                                        "imageID": opt_i(a.image_id), "isCompilation": I(a.isComplation or 0),
                                        "nameForSearch": opt_s(a.nameForSearch)} for a in db.get_album().all()})
        for table, query, id_name in [("genres", db.get_genre, "genre_id"), ("keys", db.get_key, "key_id"),
                                      ("labels", db.get_label, "label_id"), ("colors", db.get_color, "color_id")]:
            result.table(fmt, table, tables.get(table, {}),
                         {str(getattr(r, id_name)): {"id": I(getattr(r, id_name)), "name": S(r.name or "")} for r in query().all()})
        result.table(fmt, "images", tables.get("images", {}),
                     {str(r.image_id): {"id": I(r.image_id), "oneLibraryPath": opt_s(r.path)} for r in db.get_image().all()})

        contents = db.get_playlist_content().all()
        raw_count = db.session.execute(text("SELECT count(*) FROM playlist_content")).scalar()
        if raw_count != len(contents):
            result.note("OL pyrekordbox playlist_content: ORM 행 %d / SQL 행 %d(기본 키 (playlist_id, content_id)가 겹치는 항목을 합침)"
                        % (len(contents), raw_count))
        playlists = {}
        for p in db.get_playlist().all():
            mine = sorted([(e.sequenceNo or 0, position, e.content_id) for position, e in enumerate(contents)
                           if e.playlist_id == p.playlist_id])
            playlists[str(p.playlist_id)] = {
                "id": I(p.playlist_id), "name": S(p.name or ""), "parentID": I(p.playlist_id_parent or 0),
                "attribute": I(p.attribute or 0), "imageID": opt_i(p.image_id), "sortOrder.oneLibrary": I(p.sequenceNo or 0),
                "entries.oneLibrary": L([content for _, _, content in mine]),
            }
        result.table(fmt, "playlists", tables.get("playlists", {}), playlists)
        if raw_count != len(contents):
            # ORM이 합친 항목 탓인지 가르려고, 같은 연결에서 원래 행을 (sequenceNo, rowid) 순으로 읽어 항목만 다시 견준다
            raw_entries = {}
            for row in db.session.execute(text("SELECT playlist_id, content_id FROM playlist_content "
                                               "ORDER BY playlist_id, sequenceNo, rowid")):
                raw_entries.setdefault(row[0], []).append(row[1])
            djc_entries = {key: {"entries.oneLibrary": row["entries.oneLibrary"]}
                           for key, row in tables.get("playlists", {}).items()}
            result.table(fmt, "playlists 항목(SQL 원래 행)", djc_entries,
                         {str(p.playlist_id): {"entries.oneLibrary": L(raw_entries.get(p.playlist_id, []))}
                          for p in db.get_playlist().all()})
        result.table(fmt, "myTags", tables.get("myTags", {}),
                     {str(t.myTag_id): {"id": I(t.myTag_id), "parentID": I(t.myTag_id_parent or 0), "sequenceNo": I(t.sequenceNo or 0),
                                        "name": S(t.name or ""), "isCategory": B(t.attribute == 1)} for t in db.get_my_tag().all()})
        result.table(fmt, "myTagLinks", tables.get("myTagLinks", {}),
                     {"%d:%d" % (l.myTag_id, l.content_id): {"myTagID": I(l.myTag_id), "contentID": I(l.content_id)}
                      for l in db.get_my_tag_content().all()})
        result.table(fmt, "menuItems", tables.get("menuItems", {}),
                     {str(m.menuItem_id): {"id": I(m.menuItem_id), "kind": I(m.kind or 0), "name": S(unwrap_menu(m.name or ""))}
                      for m in db.get_menu_item().all()}, transformed=["이름의 U+FFFA·U+FFFB 떼기"])
        result.table(fmt, "categories", tables.get("categories", {}),
                     {str(c.category_id): {"id": I(c.category_id), "menuItemID": I(c.menuItem_id or 0), "sequenceNo": I(c.sequenceNo or 0),
                                           "isVisible": B((c.isVisible or 0) != 0)} for c in db.get_category().all()})
        result.table(fmt, "sorts", tables.get("sorts", {}),
                     {str(s.sort_id): {"id": I(s.sort_id), "menuItemID": I(s.menuItem_id or 0), "sequenceNo": I(s.sequenceNo or 0),
                                       "isVisible": B((s.isVisible or 0) != 0),
                                       "isSelectedAsSubColumn": B((s.isSelectedAsSubColumn or 0) != 0)} for s in db.get_sort().all()})
        history_contents = db.get_history_content().all()
        histories = {}
        for h in db.get_history().all():
            mine = sorted([(e.sequenceNo or 0, position, e.content_id) for position, e in enumerate(history_contents)
                           if e.history_id == h.history_id])
            histories[str(h.history_id)] = {"id": I(h.history_id), "name": S(h.name or ""), "format": "e:oneLibrary",
                                            "entries": L([content for _, _, content in mine])}
        result.table(fmt, "histories", tables.get("histories", {}), histories)
        properties = db.get_property().all()
        created = db.session.execute(text("SELECT createdDate FROM property LIMIT 1")).scalar()
        prop = {}
        if properties:
            p = properties[0]
            prop["0"] = {"deviceName": S(p.deviceName or ""), "dbVersion": S(text_of(p.dbVersion)),
                         "numberOfContents": I(p.numberOfContents or 0), "createdDate": S(created or ""),
                         "backgroundColorType": I(p.backGroundColorType or 0), "myTagMasterDBID": I(p.myTagMasterDBID or 0)}
        result.table(fmt, "property", tables.get("property", {}), prop)
        order = list(schema)
        unknown = {}
        for name, query in [("hotCueBankList", db.get_hot_cue_banklist), ("hotCueBankList_cue", db.get_hot_cue_banklist_cue),
                            ("cue", db.get_cue), ("recommendedLike", db.get_recommended_like)]:
            count = len(query().all())
            if count:
                unknown["exportLibrary.db:%d" % order.index(name)] = {"liveRows": I(count)}
        result.table(fmt, "unknownRows", tables.get("unknownRows", {}), unknown)
    finally:
        db.close()


def main():
    parser = argparse.ArgumentParser(description="DJCrate USB 리더 ↔ 외부 파서 대조(값은 찍지 않음)")
    parser.add_argument("--djc", required=True, help="djc lab usb-fields 출력 JSON")
    parser.add_argument("--usb", required=True, help="같은 USB 사본 폴더")
    parser.add_argument("--rekordcrate", help="rekordcrate 실행 파일(Device Library 대조에 필요)")
    parser.add_argument("--only", choices=["dl", "ol"], help="한 형식만 대조(없으면 USB에 있는 형식 모두)")
    parser.add_argument("--work", help="외부 파서가 열 사본을 둘 임시 폴더(없으면 새로 만들고 지운다)")
    parser.add_argument("--positions", type=int, default=20, help="찍을 차이 위치 수")
    parser.add_argument("--no-keys", action="store_true", help="차이 위치에 행 키(id)를 찍지 않는다")
    args = parser.parse_args()
    if digest(SELF_CHECK[0]) != SELF_CHECK[1]:
        print("정규형 해시 자체 확인 실패")
        return 2
    with open(args.djc, encoding="utf-8") as handle:
        djc = json.load(handle)
    if djc.get("hash") != "sha256:16":
        print("usb-fields 해시 모양이 다르다")
        return 2
    schema_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Tests", "Support", "Resources",
                               "onelibrary-7.2.18-schema.sql")
    result = Result(show_keys=not args.no_keys)
    work = args.work or tempfile.mkdtemp(prefix="djc-usb-parser-compare-")
    try:
        if "deviceLibrary" in djc and args.only != "ol":
            if not args.rekordcrate:
                print("Device Library 대조에 --rekordcrate가 필요하다(OneLibrary만 보려면 --only ol)")
                return 2
            compare_device_library(result, djc["deviceLibrary"], args.usb, args.rekordcrate, work)
        if "oneLibrary" in djc and args.only != "dl":
            compare_one_library(result, djc["oneLibrary"], args.usb, work, schema_path)
    finally:
        if not args.work:
            shutil.rmtree(work, ignore_errors=True)
    for line in result.lines:
        print(line)
    if result.transformed:
        print("DJCrate 변환을 외부 쪽에 적용한 칸(독립 확인 아님):")
        for table, items in sorted(result.transformed.items()):
            print("  %s: %s" % (table, ", ".join(items)))
    if result.skipped:
        print("비교하지 않은 DJCrate 칸(그 형식에 없는 칸·리더 기본값·외부 파서가 해석하지 않는 칸):")
        for table, fields in sorted(result.skipped.items()):
            print("  %s: %s" % (table, ", ".join(fields)))
    for position in result.positions[:args.positions]:
        print("차이 위치: " + position)
    if len(result.positions) > args.positions:
        print("차이 위치 %d개 더" % (len(result.positions) - args.positions))
    print("차이 %d" % result.differences)
    return 1 if result.differences or result.failures else 0


if __name__ == "__main__":
    sys.exit(main())
