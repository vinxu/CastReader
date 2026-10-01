import base64
import io
import threading
import time
import unittest
from types import SimpleNamespace

import numpy as np
import soundfile as sf

from alignment_contract import AlignmentRejected
from caption_pipeline import (
    CaptionPipeline, EncodedAudio, PCM, PipelineCancelled, encode_gapless,
    QwenPCMAligner, alignment_input_text, prepare_pcm, project_words,
)


def aligned(text="Hello", start=.1, end=.4):
    return [{"text": text, "start_time": start, "end_time": end}]


class ProjectionTests(unittest.TestCase):
    def test_punctuation_delimits_alignment_words_without_changing_source_letters(self):
        cases = [
            ('"Nedat."("Below.")', "Nedat Below"),
            ('enthusiastically;"that', "enthusiastically that"),
            ('“Hello”—world...again!', "Hello world again"),
            ("Don't Aujourd’hui 3.14 1,000", "Don't Aujourd’hui 3.14 1,000"),
            ("Ｍüller cafe\u0301", "Müller café"),
        ]
        for source, expected in cases:
            with self.subTest(source=source):
                self.assertEqual(alignment_input_text(source), expected)

    def test_model_receives_separate_words_at_unspaced_punctuation(self):
        observed = []

        def align(**kwargs):
            observed.append(kwargs["text"])
            return [SimpleNamespace(items=[SimpleNamespace(text="Nedat", start_time=.3, end_time=.8),
                                           SimpleNamespace(text="Below", start_time=1.3, end_time=1.7)])]

        aligner = QwenPCMAligner.__new__(QwenPCMAligner)
        aligner.model = SimpleNamespace(align=align)
        words = aligner(PCM(np.zeros(48000, dtype=np.float32), 24000), '"Nedat."("Below.")', "en")
        self.assertEqual(observed, ["Nedat Below"])
        self.assertEqual([row["word"] for row in project_words('"Nedat."("Below.")', words, 2)],
                         ["Nedat", "Below"])

    def test_mp3_frame_preparation_pads_only_the_tail_and_preserves_exact_decoded_clock(self):
        original = np.sin(np.arange(278820, dtype=np.float32) * .1) * .1
        stream = io.BytesIO()
        sf.write(stream, original, 24000, format="WAV", subtype="FLOAT")
        pcm = prepare_pcm(stream.getvalue())
        self.assertEqual(len(pcm.samples) % 576, 0)
        np.testing.assert_array_equal(pcm.samples[:len(original)], original)
        self.assertTrue(np.all(pcm.samples[len(original):] == 0))
        self.assertLess(len(pcm.samples) - len(original), 576)
        self.assertEqual(encode_gapless(pcm).duration, pcm.duration)

    def test_numbers_are_source_spans_not_invented_subword_intervals(self):
        for source, provider in [("19th", "19th"), ("3.14", "314"), ("1,000", "1000")]:
            result = project_words(source, aligned(provider), 1)
            self.assertEqual(result, [{"word": source, "start_time": .1, "end_time": .4}])

    def test_unicode_source_spelling(self):
        for source, provider in [("cafe\u0301", "café"), ("Aujourd’hui", "Aujourd'hui"),
                                 ("Straße", "STRASSE"), ("Ｍüller", "Müller")]:
            self.assertEqual(project_words(source, aligned(provider), 1)[0]["word"], source)

    def test_repeated_words_and_punctuation(self):
        words = aligned("the", .1, .3) + aligned("the", .4, .7)
        self.assertEqual([row["word"] for row in project_words("“the”, the!", words, 1)], ["the", "the"])

    def test_invalid_intervals_rejected_without_clamping(self):
        for start, end in [(0, 0), (0, 1.001), (-.01, .1), (.3, .2), (0, float("nan")),
                           (float("inf"), 1)]:
            with self.subTest(start=start, end=end), self.assertRaises(AlignmentRejected):
                project_words("Hello", aligned(start=start, end=end), 1)

    def test_overlap_rejected(self):
        with self.assertRaises(AlignmentRejected):
            project_words("Hello world", aligned() + aligned("world", .3, .8), 1)

    def test_missing_and_changed_words_rejected(self):
        for text, words in [("Hello world", aligned()), ("19th", aligned("nineteenth")),
                             ("Hello", []), ("café", aligned("cafe"))]:
            with self.assertRaises(AlignmentRejected):
                project_words(text, words, 1)

    def test_cannot_split_normalization_expansion(self):
        with self.assertRaises(AlignmentRejected):
            project_words("ß", aligned("s") + aligned("s", .5, .7), 1)


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.pcm = PCM(np.zeros(24000, dtype=np.float32), 24000)

    def pipeline(self, aligner=lambda *args: aligned(), **kwargs):
        kwargs.setdefault("encoder", lambda pcm: EncodedAudio(b"same-mp3", pcm.duration))
        pipeline = CaptionPipeline(aligner, **kwargs)
        self.addCleanup(pipeline.close)
        return pipeline

    def caption(self, pipeline, **kwargs):
        return pipeline.caption(self.pcm, text="Hello", language="en", voice_code="vc_test", **kwargs)

    def test_exact_wire_contract_and_voice(self):
        result = self.caption(self.pipeline())
        self.assertEqual(set(result.response), {"audio", "audio_format", "timestamps", "voice_code"})
        self.assertEqual(base64.b64decode(result.response["audio"]), b"same-mp3")
        self.assertEqual(result.response["voice_code"], "vc_test")
        self.assertEqual(result.duration, 1)
        self.assertEqual(result.reason, "qwen-word")

    def test_actual_overlap_not_serial_execution(self):
        entered = threading.Event()
        release = threading.Event()

        def aligner(*args):
            entered.set()
            if not release.wait(1):
                raise AssertionError("encoder did not overlap")
            return aligned()

        def encoder(pcm):
            self.assertTrue(entered.wait(1))
            release.set()
            return EncodedAudio(b"same-mp3", 1)

        self.assertEqual(self.caption(self.pipeline(aligner, encoder=encoder)).reason, "qwen-word")

    def test_alignment_failure_never_retries_or_changes_audio(self):
        calls = []

        def aligner(*args):
            calls.append(1)
            raise RuntimeError("model unavailable")

        result = self.caption(self.pipeline(aligner))
        self.assertEqual(calls, [1])
        self.assertEqual(result.response["timestamps"], [])
        self.assertEqual(result.reason, "alignment-failed")
        self.assertEqual(base64.b64decode(result.response["audio"]), b"same-mp3")

    def test_zero_duration_is_explicit_segment_fallback(self):
        result = self.caption(self.pipeline(lambda *args: aligned(start=.2, end=.2)))
        self.assertEqual(result.reason, "unresolved-word-near-pause")
        self.assertEqual(result.response["timestamps"], [])

    def test_unresolved_short_word_groups_measured_neighbors_without_inventing_times(self):
        words = aligned("This", .1, .3) + aligned("is", .3, .3) + aligned("real", .3, .7)
        result = self.pipeline(lambda *args: words).caption(
            self.pcm, text="This is real.", language="en", voice_code="vc_test")
        self.assertEqual(result.reason, "qwen-word-groups")
        self.assertEqual(result.response["timestamps"], [
            {"word": "This", "start_time": .1, "end_time": .3},
            {"word": "is real", "start_time": .3, "end_time": .7}])

    def test_unresolved_word_does_not_bridge_a_pause(self):
        words = aligned("This", .1, .2) + aligned("is", .4, .4) + aligned("real", .7, .9)
        result = self.pipeline(lambda *args: words).caption(
            self.pcm, text="This is real", language="en", voice_code="vc_test")
        self.assertEqual(result.reason, "unresolved-word-near-pause")
        self.assertEqual(result.response["timestamps"], [])

    def test_uncovered_spoken_prefix_never_returns_late_group_timestamps(self):
        samples = np.zeros(48000, dtype=np.float32)
        samples[7200:19200] = np.sin(np.arange(12000, dtype=np.float32) * .12) * .15
        samples[31200:40800] = np.sin(np.arange(9600, dtype=np.float32) * .12) * .15
        words = aligned("Nedat", 1.28, 1.28) + aligned("Below", 1.28, 1.76)
        result = self.pipeline(lambda *args: words).caption(
            PCM(samples, 24000), text='"Nedat."("Below.")', language="en", voice_code="vc_test")
        self.assertEqual(result.reason, "uncovered-audio-near-unresolved-word")
        self.assertEqual(result.response["timestamps"], [])
        self.assertEqual(base64.b64decode(result.response["audio"]), b"same-mp3")

    def test_legitimate_leading_silence_keeps_measured_timestamps(self):
        samples = np.zeros(48000, dtype=np.float32)
        samples[31200:40800] = np.sin(np.arange(9600, dtype=np.float32) * .12) * .15
        words = aligned("Hello", 1.28, 1.28) + aligned("there", 1.28, 1.76)
        result = self.pipeline(lambda *args: words).caption(
            PCM(samples, 24000), text="Hello there", language="en", voice_code="vc_test")
        self.assertEqual(result.reason, "qwen-word-groups")
        self.assertEqual(len(result.response["timestamps"]), 1)

    def test_short_prefix_transient_and_quantization_tolerance_are_not_retimed(self):
        for first_start, prefix_start, prefix_end in [(1.28, 7200, 8160), (.4, 5760, 9600)]:
            samples = np.zeros(48000, dtype=np.float32)
            samples[prefix_start:prefix_end] = .1
            samples[int(first_start * 24000):43200] = .1
            words = aligned("Hello", first_start, first_start) + aligned("there", first_start, 1.8)
            result = self.pipeline(lambda *args: words).caption(
                PCM(samples, 24000), text="Hello there", language="en", voice_code="vc_test")
            self.assertEqual(result.reason, "qwen-word-groups")
            self.assertEqual(result.response["timestamps"][0]["start_time"], first_start)

    def test_resolved_first_word_is_not_retimed_from_leading_audio_energy(self):
        samples = np.zeros(48000, dtype=np.float32)
        samples[7200:19200] = .1
        samples[31200:40800] = .1
        result = self.pipeline(lambda *args: aligned("Hello", 1.28, 1.76)).caption(
            PCM(samples, 24000), text="Hello", language="en", voice_code="vc_test")
        self.assertEqual(result.reason, "qwen-word")
        self.assertEqual(result.response["timestamps"][0]["start_time"], 1.28)

    def test_unresolved_interior_word_cannot_hide_spoken_audio_inside_a_pause(self):
        samples = np.zeros(48000, dtype=np.float32)
        samples[16800:26400] = .1
        samples[33600:43200] = .1
        words = aligned("Said", .1, .4) + aligned("enthusiastically", 1.4, 1.4) + aligned("that", 1.4, 1.8)
        result = self.pipeline(lambda *args: words).caption(
            PCM(samples, 24000), text="Said enthusiastically; that", language="en", voice_code="vc_test")
        self.assertEqual(result.reason, "uncovered-audio-near-unresolved-word")
        self.assertEqual(result.response["timestamps"], [])

    def test_unresolved_final_word_cannot_hide_subsequent_spoken_audio(self):
        samples = np.zeros(48000, dtype=np.float32)
        samples[19200:33600] = .1
        words = aligned("Hello", .1, .4) + aligned("there", .4, .4)
        result = self.pipeline(lambda *args: words).caption(
            PCM(samples, 24000), text="Hello there", language="en", voice_code="vc_test")
        self.assertEqual(result.reason, "uncovered-audio-near-unresolved-word")
        self.assertEqual(result.response["timestamps"], [])

    def test_sentence_initial_short_word_does_not_absorb_the_previous_sentence(self):
        words = aligned("Done", .1, .2) + aligned("The", .6, .6) + aligned("test", .6, .9)
        result = self.pipeline(lambda *args: words).caption(
            self.pcm, text="Done. The test", language="en", voice_code="vc_test")
        self.assertEqual(result.response["timestamps"], [
            {"word": "Done", "start_time": .1, "end_time": .2},
            {"word": "The test", "start_time": .6, "end_time": .9}])

    def test_adjacent_zero_words_merge_once_and_preserve_source_punctuation(self):
        words = aligned("This", .1, .3) + aligned("is", .3, .3) + aligned("a", .3, .3) + aligned("test", .3, .7)
        result = self.pipeline(lambda *args: words).caption(
            self.pcm, text="This is a—test.", language="en", voice_code="vc_test")
        self.assertEqual(result.response["timestamps"], [
            {"word": "This", "start_time": .1, "end_time": .3},
            {"word": "is a—test", "start_time": .3, "end_time": .7}])

    def test_grouping_does_not_hide_text_mismatch_or_reversed_intervals(self):
        for words in [aligned("Other", .1, .3) + aligned("is", .3, .3) + aligned("real", .3, .7),
                      aligned("This", .3, .1) + aligned("is", .3, .3) + aligned("real", .3, .7)]:
            result = self.pipeline(lambda *args: words).caption(
                self.pcm, text="This is real", language="en", voice_code="vc_test")
            self.assertEqual(result.response["timestamps"], [])

    def test_queued_and_active_timeout_do_not_release_running_slot(self):
        release = threading.Event()
        entered = threading.Event()
        calls = []

        def aligner(*args):
            calls.append(1)
            entered.set()
            release.wait(2)
            return aligned()

        pipeline = self.pipeline(aligner, max_inflight=1, alignment_budget_s=.05)
        try:
            first = self.caption(pipeline)
            self.assertTrue(entered.is_set())
            self.assertEqual(first.reason, "deadline")
            second = self.caption(pipeline)
            self.assertEqual(second.reason, "overloaded")
            self.assertEqual(calls, [1])
            self.assertEqual(first.response["timestamps"], [])
        finally:
            release.set()

    def test_queued_timeout_never_runs_expired_audio(self):
        release = threading.Event()
        calls = []

        def aligner(*args):
            calls.append(1)
            release.wait(2)
            return aligned()

        pipeline = self.pipeline(aligner, max_inflight=2, alignment_budget_s=.05)
        try:
            self.assertEqual(self.caption(pipeline).reason, "deadline")
            self.assertEqual(self.caption(pipeline).reason, "deadline")
        finally:
            release.set()
        pipeline.close()
        self.assertEqual(calls, [1])

    def test_slow_encoder_keeps_alignment_completed_before_deadline(self):
        completed = threading.Event()

        def aligner(*args):
            completed.set()
            return aligned()

        def encoder(pcm):
            self.assertTrue(completed.wait(1))
            time.sleep(.1)
            return EncodedAudio(b"same-mp3", 1)

        self.assertEqual(self.caption(self.pipeline(aligner, encoder=encoder, alignment_budget_s=.05)).reason,
                         "qwen-word")

    def test_completed_but_late_alignment_is_not_published(self):
        completed = threading.Event()

        def aligner(*args):
            time.sleep(.1)
            completed.set()
            return aligned()

        def encoder(pcm):
            self.assertTrue(completed.wait(1))
            return EncodedAudio(b"same-mp3", 1)

        self.assertEqual(self.caption(self.pipeline(aligner, encoder=encoder, alignment_budget_s=.05)).reason,
                         "deadline")

    def test_cancel_before_and_during_work(self):
        cancel = threading.Event()
        cancel.set()
        with self.assertRaises(PipelineCancelled):
            self.caption(self.pipeline(), cancel=cancel)
        cancel.clear()

        def encoder(pcm):
            cancel.set()
            return EncodedAudio(b"same-mp3", 1)

        with self.assertRaises(PipelineCancelled):
            self.caption(self.pipeline(encoder=encoder), cancel=cancel)

    def test_nonword_language_and_disabled_do_not_infer(self):
        def forbidden(*args):
            raise AssertionError("aligner should not be called")

        pipeline = self.pipeline(forbidden)
        for language in ("ja-JP", "ko_KR", "ar"):
            result = pipeline.caption(self.pcm, text="Hello", language=language, voice_code="vc_test")
            self.assertNotEqual(result.reason, "alignment-failed")
            self.assertEqual(result.response["timestamps"], [])
        self.assertEqual(self.caption(pipeline, return_timestamps=False).reason, "disabled")

    def test_chinese_measured_source_spans_keep_exact_audio_clock(self):
        calls = []
        words = aligned("今天", .1, .4) + aligned("读书", .5, .9)
        def aligner(pcm, text, language):
            calls.append(language)
            return words
        pipeline = self.pipeline(aligner)
        for language in ("zh", "zh-Hans", "zh_TW"):
            result = pipeline.caption(self.pcm, text="今天，读书。", language=language, voice_code="vc_test")
            self.assertEqual(result.reason, "qwen-word")
            self.assertEqual(result.response["timestamps"], [
                {"word": "今天", "start_time": .1, "end_time": .4},
                {"word": "读书", "start_time": .5, "end_time": .9}])
            self.assertEqual(base64.b64decode(result.response["audio"]), b"same-mp3")
        self.assertEqual(calls, ["zh"] * 3)

    def test_chinese_missing_source_is_rejected_without_estimated_repair(self):
        result = self.pipeline(lambda *args: aligned("今天")).caption(
            self.pcm, text="今天，读书。", language="zh", voice_code="vc_test")
        self.assertEqual(result.reason, "text-coverage-mismatch")
        self.assertEqual(result.response["timestamps"], [])

    def test_encoding_failure_is_not_disguised_as_success(self):
        def encoder(pcm):
            raise ValueError("encoder failed")

        with self.assertRaises(ValueError):
            self.caption(self.pipeline(encoder=encoder))

    def test_serial_and_overlap_return_identical_payloads(self):
        pipeline = self.pipeline()
        self.assertEqual(self.caption(pipeline, overlap=False).response, self.caption(pipeline).response)

    def test_closed_pipeline_rejects_work(self):
        pipeline = self.pipeline()
        pipeline.close()
        with self.assertRaises(RuntimeError):
            self.caption(pipeline)

    def test_encoded_clock_must_match_aligned_pcm(self):
        with self.assertRaises(ValueError):
            self.caption(self.pipeline(encoder=lambda pcm: EncodedAudio(b"bad", 2)))


class AudioClockTests(unittest.TestCase):
    def test_speed_and_mp3_gapless_preserve_sample_clock(self):
        sample_rate = 24000
        timeline = np.arange(sample_rate, dtype=np.float32) / sample_rate
        samples = .2 * np.sin(2 * np.pi * 220 * timeline)
        samples[:1200] = 0
        stream = io.BytesIO()
        sf.write(stream, samples, sample_rate, format="WAV")
        for speed in (.8, 1, 1.25, 2):
            pcm = prepare_pcm(stream.getvalue(), speed)
            encoded = encode_gapless(pcm)
            decoded, decoded_rate = sf.read(io.BytesIO(encoded.data), dtype="float32")
            self.assertEqual(decoded_rate, sample_rate)
            self.assertEqual(len(decoded), len(pcm.samples))
            self.assertEqual(encoded.duration, pcm.duration)
            self.assertLess(abs(pcm.duration - 1 / speed), .1)


if __name__ == "__main__":
    unittest.main()
