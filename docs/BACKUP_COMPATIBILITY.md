# Backup Compatibility

## Format (verified against Mihon source, 2026-08-21)

`.tachibk` = **protobuf `Backup` message**, compressed:
- current Mihon: **zstd** (frame magic `28 B5 2F FD`)
- legacy Tachiyomi: **zlib** (`0x78` first byte)

Field numbers (Mihon `data/backup/models/Backup.kt`, fetched 2026-08-21):

- `Backup`: 1 manga, 2 categories, 101 sources, 104 preferences,
  105 sourcePreferences, 106 extensionStores
- `BackupManga`: 1 source(Long), 2 url, 3 title, 4 artist, 5 author,
  6 description, 7 genre, 8 status, 9 thumbnailUrl, 13 dateAdded,
  16 chapters, 17 categories(repeated Long), 18 tracking, 100 favorite,
  101 chapterFlags, 104 history, 105 updateStrategy, 111 initialized
- `BackupChapter`: 1 url, 2 name, 3 scanlator, 4 read, 5 bookmark,
  6 lastPageRead, 7 dateFetch, 8 dateUpload, 9 chapterNumber(Float/fixed32),
  10 sourceOrder
- `BackupCategory`: 1 name, 2 order, 3 id
- `BackupHistory`: 1 url, 2 lastRead, 3 readDuration
- `BackupSource`: 1 name, 2 sourceId

## Implementation status

`MihonCompatKit/Backup/TachibkReader.swift`:
- ✅ zlib (legacy) streams fully decode — covered by the kit's Inflate.
- ✅ protobuf decoding of all messages above into typed Swift values.
- ◻ zstd streams throw a precise `zstdNotSupported` error. Plan: vendor a
  pure-Swift zstd decoder or link a zstd SPM product; schema work is done,
  only decompression blocks current-Mihon backups.

## Import flow (planned)
1. Decode entries.
2. Map `sourceId` → installed sources (native now; bridged extensions when
   the runtime lands). Unmapped sources are listed, never dropped.
3. Import manga/chapters/categories/history; match chapters by number/name
   (fuzzy) since URLs differ across source instances.
4. Emit an import report: imported / skipped / missing-source items.
