#!/usr/bin/env python3
"""Independent wire observations; this script never produces fixture bytes."""

import hashlib
import json
from pathlib import Path
import struct
import zlib


def varint(data, position):
    value = 0
    for index in range(10):
        assert position < len(data), "truncated varint"
        byte = data[position]
        position += 1
        assert index < 9 or byte <= 1, "overflowing varint"
        value |= (byte & 127) << (index * 7)
        if byte < 128:
            return value, position
    raise AssertionError("unterminated varint")


def fields(data):
    position = 0
    result = []
    while position < len(data):
        tag, position = varint(data, position)
        number, wire = tag >> 3, tag & 7
        assert number > 0, "zero field number"
        if wire == 0:
            value, position = varint(data, position)
        elif wire == 2:
            length, position = varint(data, position)
            assert length <= len(data) - position, "truncated LEN field"
            value = data[position:position + length]
            position += length
        elif wire in (1, 5):
            length = 8 if wire == 1 else 4
            assert length <= len(data) - position, "truncated fixed-width field"
            value = data[position:position + length]
            position += length
        else:
            raise AssertionError("unexpected wire type")
        result.append((number, wire, value))
    return result


def occurrences(message, number):
    return [(wire, value) for field, wire, value in message if field == number]


def scalar(message, number, default=None):
    rows = occurrences(message, number)
    assert len(rows) <= 1, "unexpected duplicate scalar in producer output"
    if not rows:
        return default
    wire, value = rows[0]
    assert wire == 0
    return value


def messages(message, number):
    result = []
    for wire, value in occurrences(message, number):
        assert wire == 2
        result.append(fields(value))
    return result


def signed64(value):
    return value if value < (1 << 63) else value - (1 << 64)


def main():
    directory = Path(__file__).resolve().parent
    manifest = json.loads((directory / "manifest.json").read_text())
    for fixture in manifest["fixtures"]:
        for path_key, hash_key in [
            ("rawPath", "rawSHA256"),
            ("gzipPath", "gzipSHA256"),
            ("expectedJSONPath", "expectedJSONSHA256"),
        ]:
            assert hashlib.sha256((directory / fixture[path_key]).read_bytes()).hexdigest() == fixture[hash_key]
        raw = (directory / fixture["rawPath"]).read_bytes()
        compressed = (directory / fixture["gzipPath"]).read_bytes()
        assert compressed[:10] == bytes.fromhex("1f8b08000000000000ff")
        inflater = zlib.decompressobj(wbits=31)
        assert inflater.decompress(compressed) + inflater.flush() == raw
        assert inflater.eof and not inflater.unused_data and not inflater.unconsumed_tail
        expected = json.loads((directory / fixture["expectedJSONPath"]).read_text())
        root = fields(raw)
        assert len(messages(root, 1)) == len(expected["manga"])
        assert len(messages(root, 2)) == len(expected["categories"])
        assert len(messages(root, 101)) == len(expected["sources"])

    root = fields((directory / "kotlin-defaults.pb").read_bytes())
    first, second = messages(root, 1)
    assert signed64(scalar(first, 1)) == 9_007_199_254_740_993
    assert signed64(scalar(second, 1)) == 9_223_372_036_854_775_807
    assert occurrences(first, 100) == [], "favorite=true must be omitted by default serializer"
    assert occurrences(second, 100) == [(0, 0)], "explicit favorite=false must be present"
    assert occurrences(first, 17) == [(0, 7), (0, 4_294_967_301)], "category orders are unpacked Long values"
    assert scalar(first, 105) == 1 and occurrences(second, 105) == []
    assert scalar(first, 107) == 1_760_000_123 and occurrences(second, 107) == []
    assert scalar(first, 111) == 1 and occurrences(second, 111) == []
    first_category, second_category = messages(root, 2)
    assert (scalar(first_category, 2), scalar(first_category, 3)) == (7, 101)
    assert (scalar(second_category, 2), scalar(second_category, 3)) == (4_294_967_301, 202)
    chapters = messages(first, 16)
    for chapter, expected in zip(chapters, [2.25, 3.5]):
        assert occurrences(chapter, 9) == [(5, struct.pack("<f", expected))]
    assert scalar(chapters[1], 6) == 4_294_967_311
    assert scalar(chapters[1], 10) == 4_294_967_305
    default_chapter = messages(second, 16)[0]
    assert [number for number, _, _ in default_chapter] == [1, 2]
    history = messages(first, 104)
    assert [(scalar(entry, 2), scalar(entry, 3)) for entry in history] == [
        (1_780_009_876_543, 90_123), (1_780_009_999_999, 5_000_000_001),
    ]

    negative = messages(fields((directory / "kotlin-negative-source.pb").read_bytes()), 1)[0]
    assert signed64(scalar(negative, 1)) == -9_223_372_036_854_775_808
    assert occurrences(negative, 107) == [(0, 0)], "nullable zero differs from omitted null"
    assert (directory / "kotlin-empty-root.pb").read_bytes() == b""
    empty_expected = json.loads((directory / "kotlin-empty-root.kotlin-decoded.json").read_text())
    assert empty_expected == {"manga": [], "categories": [], "sources": []}
    assert (directory / "kotlin-categories-only.pb").read_bytes()[0] == 0x12
    assert (directory / "kotlin-sources-only.pb").read_bytes()[:2] == bytes.fromhex("aa06")
    print("Verified five Kotlin fixture pairs, hashes, gzip containers, default omissions, Long values, and wire observations.")


if __name__ == "__main__":
    main()
