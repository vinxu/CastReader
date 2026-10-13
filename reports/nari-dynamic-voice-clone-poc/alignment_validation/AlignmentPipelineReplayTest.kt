package com.same.castreader

import com.same.castreader.data.model.TTSResponse
import com.same.castreader.data.model.TtsTimestampPolicy
import com.same.castreader.data.model.HighlightGranularity
import com.squareup.moshi.Moshi
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

class AlignmentPipelineReplayTest {
    @Test fun replayGpuPipelineThroughActualDecoderAndPolicy() {
        val root = File(requireNotNull(System.getenv("CASTREADER_PIPELINE_EVIDENCE")))
        val moshi = Moshi.Builder().build()
        val adapter = moshi.adapter(Any::class.java)
        for (dataset in listOf("gpu-eager", "live-tts")) {
            val directory = File(root, dataset)
            val rows = adapter.fromJson(File(directory, "client-fixtures.json").readText()) as List<*>
            val result = rows.map { raw ->
                val row = raw as Map<*, *>
                val wire = row["response"] as Map<*, *>
                val response = moshi.adapter(TTSResponse::class.java).fromJson(adapter.toJson(wire))!!
                assertEquals(wire["audio"], response.audio)
                val quality = TtsTimestampPolicy.inspect(row["text"] as String, response.timestamps,
                    (row["duration"] as Number).toDouble(), row["language"] as String)
                mapOf("id" to row["id"], "accepted" to true,
                    "timestamps" to response.timestamps.orEmpty().size,
                    "wordQuality" to (quality is HighlightGranularity.Word),
                    "qualityReason" to (quality as? HighlightGranularity.Sentence)?.reason)
            }
            assertEquals(rows.size, result.size)
            File(directory, "android-compatibility.json").writeText(adapter.toJson(result))
        }
    }
}
