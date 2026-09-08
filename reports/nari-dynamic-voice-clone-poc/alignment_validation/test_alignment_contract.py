import unittest

from alignment_contract import AlignmentRejected, to_worker_timestamps


class AlignmentContractTests(unittest.TestCase):
    def words(self, values):
        return [{"text":text,"start_time":i*.2,"end_time":i*.2+.16} for i,text in enumerate(values)]

    def test_restores_original_spelling_without_moving_boundaries(self):
        original = ["Dr", "Müller", "zahlt", "3.14", "Euro"]
        provider = self.words(["Dr", "Müller", "zahlt", "314", "Euro"])
        result = to_worker_timestamps(original, provider, duration=1)
        self.assertEqual([r["word"] for r in result], original)
        self.assertEqual(result[3]["start_time"], .6)

    def test_curly_apostrophe_and_composed_accents(self):
        original = ["Aujourd’hui", "café"]
        provider = self.words(["Aujourd'hui", "cafe\u0301"])
        self.assertEqual([r["word"] for r in to_worker_timestamps(original,provider,duration=1)], original)

    def test_only_server_speed_conversion_changes_clock(self):
        words = [{"text":"hello","start_time":1.,"end_time":2.}]
        for speed in [.8,1.,1.25,2.]:
            result = to_worker_timestamps(["hello"],words,duration=3/speed,synthesis_speed=speed)
            self.assertEqual(result[0]["start_time"],1/speed)
            self.assertEqual(result[0]["end_time"],2/speed)

    def test_zero_negative_nan_and_out_of_audio_rejected(self):
        for start,end in [(0,0),(1,.5),(-.1,.1),(0,float('nan')),(0,5)]:
            with self.assertRaises(AlignmentRejected):
                to_worker_timestamps(["word"],[{"text":"word","start_time":start,"end_time":end}],duration=1)

    def test_wrong_or_omitted_words_are_not_fabricated(self):
        for provider in [self.words(["other"]), [], self.words(["some","word"])]:
            with self.assertRaises(AlignmentRejected):
                to_worker_timestamps(["word"],provider,duration=1)

    def test_repeated_words_keep_independent_positions(self):
        words = ["the","the","end"]
        result=to_worker_timestamps(words,self.words(words),duration=1)
        self.assertEqual([r['start_time'] for r in result],[0,.2,.4])

    def test_backwards_end_is_rejected(self):
        with self.assertRaises(AlignmentRejected):
            to_worker_timestamps(["one","two"],[{"text":"one","start_time":0,"end_time":.8},{"text":"two","start_time":.3,"end_time":.5}],duration=1)


if __name__ == '__main__':
    unittest.main()
