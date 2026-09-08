package com.same.castreader

import com.same.castreader.data.model.TTSResponse
import com.same.castreader.data.model.TtsTimestampPolicy
import com.same.castreader.data.model.HighlightGranularity
import com.squareup.moshi.Moshi
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/** Temporary host test runner; copy into the Android test source set, then remove. */
class AlignmentCompatibilityProbeTest {
    @Test fun replayCapturedPayloadsThroughActualDecoderAndPolicy() {
        val root = File(System.getenv("CASTREADER_ALIGNMENT_EVIDENCE"))
        val moshi = Moshi.Builder().build()
        val any = moshi.adapter(Any::class.java)
        val rows = any.fromJson(File(root,"client-fixtures.json").readText()) as List<*>
        val result = rows.map { raw ->
            val row = raw as Map<*, *>
            val wire = row["response"] as Map<*, *>
            val response = moshi.adapter(TTSResponse::class.java).fromJson(any.toJson(wire))!!
            assertEquals(wire["audio"], response.audio)
            val quality = TtsTimestampPolicy.inspect(row["text"] as String, response.timestamps,
                (row["duration"] as Number).toDouble(), row["language"] as String)
            mapOf("id" to row["id"], "accepted" to true, "timestamps" to response.timestamps.orEmpty().size,
                "wordQuality" to (quality is HighlightGranularity.Word),
                "qualityReason" to (quality as? HighlightGranularity.Sentence)?.reason)
        }
        File(root,"android-compatibility.json").writeText(any.toJson(result))
    }
}
