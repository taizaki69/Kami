@file:OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)

package kami.backup.fixture

import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.zip.GZIPOutputStream
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.protobuf.ProtoBuf
import kotlinx.serialization.protobuf.ProtoNumber

// Independently authored fixture-only declarations of the documented field
// numbers/types/defaults. These are not copied Mihon app implementations.
@Serializable
data class ReferenceBackup(
    @ProtoNumber(1) val manga: List<ReferenceManga>,
    @ProtoNumber(2) val categories: List<ReferenceCategory> = emptyList(),
    @ProtoNumber(101) val sources: List<ReferenceSource> = emptyList(),
)

@Serializable
data class ReferenceManga(
    @ProtoNumber(1) val sourceId: Long,
    @ProtoNumber(2) val url: String,
    @ProtoNumber(3) val title: String = "",
    @ProtoNumber(4) val artist: String? = null,
    @ProtoNumber(5) val author: String? = null,
    @ProtoNumber(6) val description: String? = null,
    @ProtoNumber(7) val genres: List<String> = emptyList(),
    @ProtoNumber(8) val status: Int = 0,
    @ProtoNumber(9) val thumbnailUrl: String? = null,
    @ProtoNumber(13) val dateAdded: Long = 0,
    @ProtoNumber(16) val chapters: List<ReferenceChapter> = emptyList(),
    @ProtoNumber(17) val categoryOrders: List<Long> = emptyList(),
    @ProtoNumber(100) val favorite: Boolean = true,
    @ProtoNumber(104) val history: List<ReferenceHistory> = emptyList(),
    @ProtoNumber(105) val updateStrategy: ReferenceUpdateStrategy = ReferenceUpdateStrategy.ALWAYS_UPDATE,
    @ProtoNumber(107) val favoriteModifiedAt: Long? = null,
    @ProtoNumber(111) val initialized: Boolean = false,
)

@Serializable
enum class ReferenceUpdateStrategy { ALWAYS_UPDATE, ONLY_FETCH_ONCE }

@Serializable
data class ReferenceCategory(
    @ProtoNumber(1) val name: String,
    @ProtoNumber(2) val order: Long = 0,
    @ProtoNumber(3) val id: Long = 0,
    @ProtoNumber(100) val flags: Long = 0,
)

@Serializable
data class ReferenceSource(
    @ProtoNumber(1) val name: String = "",
    @ProtoNumber(2) val sourceId: Long,
)

@Serializable
data class ReferenceChapter(
    @ProtoNumber(1) val url: String,
    @ProtoNumber(2) val name: String,
    @ProtoNumber(3) val scanlator: String? = null,
    @ProtoNumber(4) val read: Boolean = false,
    @ProtoNumber(5) val bookmark: Boolean = false,
    @ProtoNumber(6) val lastPageRead: Long = 0,
    @ProtoNumber(7) val dateFetch: Long = 0,
    @ProtoNumber(8) val dateUpload: Long = 0,
    @ProtoNumber(9) val chapterNumber: Float = 0F,
    @ProtoNumber(10) val sourceOrder: Long = 0,
)

@Serializable
data class ReferenceHistory(
    @ProtoNumber(1) val url: String,
    @ProtoNumber(2) val lastRead: Long,
    @ProtoNumber(3) val readDuration: Long = 0,
)

private fun sha256(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

private val decodedJsonFormatter = Json { encodeDefaults = true; prettyPrint = true }

private fun writeFixture(directory: File, name: String, value: ReferenceBackup) {
    // The default ProtoBuf instance deliberately omits declared default values.
    val raw = ProtoBuf.encodeToByteArray(ReferenceBackup.serializer(), value)
    val decoded = ProtoBuf.decodeFromByteArray(ReferenceBackup.serializer(), raw)
    check(decoded == value)
    val compressed = ByteArrayOutputStream().also { output ->
        GZIPOutputStream(output).use { it.write(raw) }
    }.toByteArray()
    // Pinned JRE GZIPOutputStream emits one deterministic zero-mtime member.
    check(compressed.copyOfRange(4, 8).all { it == 0.toByte() })
    File(directory, "$name.pb").writeBytes(raw)
    File(directory, "$name.tachibk").writeBytes(compressed)
    // Expected values come from this independent Kotlin decoder, with every
    // declared default made explicit in JSON. The wire producer still omits them.
    val decodedJson = decodedJsonFormatter.encodeToString(ReferenceBackup.serializer(), decoded) + "\n"
    File(directory, "$name.kotlin-decoded.json").writeText(decodedJson, Charsets.UTF_8)
    println("$name.pb ${raw.size} ${sha256(raw)}")
    println("$name.tachibk ${compressed.size} ${sha256(compressed)}")
}

fun main(arguments: Array<String>) {
    require(arguments.size == 1) { "Pass the fixture output directory." }
    val directory = File(arguments.single())
    directory.mkdirs()

    val categories = listOf(
        ReferenceCategory("Reference reading", order = 7L, id = 101L, flags = 9L),
        ReferenceCategory("Reference archived", order = 4_294_967_301L, id = 202L, flags = 64L),
    )
    val sources = listOf(
        ReferenceSource("Reference high-precision source", 9_007_199_254_740_993L),
        ReferenceSource("Reference maximum signed source", Long.MAX_VALUE),
    )
    val manga = listOf(
        ReferenceManga(
            sourceId = 9_007_199_254_740_993L,
            url = "/manga/reference-default",
            title = "Reference default favorite",
            artist = "Fixture artist",
            author = "Fixture author",
            description = "No personal data.\nIndependent serializer fixture.",
            genres = listOf("Reference", "Action"),
            status = 1,
            thumbnailUrl = "https://fixtures.invalid/reference-cover.jpg",
            dateAdded = 1_770_000_012_345L,
            updateStrategy = ReferenceUpdateStrategy.ONLY_FETCH_ONCE,
            favoriteModifiedAt = 1_760_000_123L,
            initialized = true,
            categoryOrders = listOf(7L, 4_294_967_301L),
            chapters = listOf(
                ReferenceChapter(
                    url = "/chapter/reference-1",
                    name = "Reference chapter 2.25",
                    scanlator = "Fixture team",
                    read = true,
                    lastPageRead = 7L,
                    dateFetch = 1_780_000_000_111L,
                    dateUpload = 1_779_999_999_999L,
                    chapterNumber = 2.25F,
                    sourceOrder = 3L,
                ),
                ReferenceChapter(
                    url = "/chapter/reference-2",
                    name = "Reference chapter 3.5",
                    bookmark = true,
                    lastPageRead = 4_294_967_311L,
                    chapterNumber = 3.5F,
                    sourceOrder = 4_294_967_305L,
                ),
            ),
            history = listOf(
                ReferenceHistory("/chapter/reference-1", 1_780_009_876_543L, 90_123L),
                ReferenceHistory("/chapter/reference-2", 1_780_009_999_999L, 5_000_000_001L),
            ),
            // favorite=true intentionally uses the Kotlin declared default.
        ),
        ReferenceManga(
            sourceId = Long.MAX_VALUE,
            url = "/manga/reference-nonfavorite",
            title = "Reference explicit nonfavorite",
            favorite = false,
            categoryOrders = listOf(7L),
            chapters = listOf(
                ReferenceChapter("/chapter/default-scalars", "Default scalar chapter"),
            ),
        ),
    )
    writeFixture(directory, "kotlin-defaults", ReferenceBackup(manga, categories, sources))
    writeFixture(directory, "kotlin-categories-only", ReferenceBackup(emptyList(), categories))
    writeFixture(directory, "kotlin-sources-only", ReferenceBackup(emptyList(), sources = sources))
    writeFixture(directory, "kotlin-negative-source", ReferenceBackup(
        manga = listOf(ReferenceManga(
            sourceId = Long.MIN_VALUE,
            url = "/manga/reference-negative",
            title = "Reference negative signed source",
            favoriteModifiedAt = 0L,
        )),
        sources = listOf(ReferenceSource("Reference negative signed source", Long.MIN_VALUE)),
    ))
    writeFixture(directory, "kotlin-empty-root", ReferenceBackup(emptyList()))
}
