import unittest

import numpy as np

from benchmark_ctc import align_words, ctc_path


class CTCPathTests(unittest.TestCase):
    def emissions(self, dominant, vocabulary=3):
        values=np.full((len(dominant),vocabulary),.001,dtype=np.float32)
        for index,label in enumerate(dominant):values[index,label]=.998
        return np.log(values)

    def test_repeated_character_requires_blank_transition(self):
        path=ctc_path(self.emissions([0,1,0,1,0]),[1,1])
        self.assertEqual(path.tolist(),[0,1,2,3,4])

    def test_impossible_short_audio_rejects_complete_target(self):
        with self.assertRaises(ValueError):
            ctc_path(self.emissions([1,1]),[1,1])

    def test_word_intervals_come_from_emission_frames(self):
        result=align_words(self.emissions([0,1,1,2,1,0]),np.arange(6)*.02+.01,
                           ['a','a'],{'<pad>':0,'A':1,'|':2})
        self.assertEqual([(w['start_time'],w['end_time']) for w in result],[(.02,.06),(.08,.10)])

    def test_numeric_text_requires_a_separate_spoken_text_policy(self):
        with self.assertRaisesRegex(ValueError,'Unsupported'):
            align_words(self.emissions([0,1,0]),np.arange(3)*.02+.01,
                        ['19'],{'<pad>':0,'A':1,'|':2})


if __name__=='__main__':unittest.main()
