import base64
import copy
import importlib.util
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('public_gate',ROOT/'verify-public-gateway.py')
gate=importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def body_for(fixture):
    return {'audio':base64.b64encode(b'offline parser fixture; MP3 decoding is separate').decode(),
        'voice_code':fixture['voice'],'timestamps':[{'word':word,'start_time':index/4,'end_time':(index+1)/4}
            for index,word in enumerate(fixture['words'])]}


class PublicGateTests(unittest.TestCase):
    def test_complete_german_sentence_preserves_internal_punctuation(self):
        fixture=gate.FIXTURES[0]
        _,result=gate.validate_audio_contract(body_for(fixture),fixture)
        self.assertEqual(result['timestampWords'],['Dr.','Müller','zahlt','3.14','Euro'])

    def test_decimal_space_and_truncated_abbreviation_are_rejected(self):
        fixture=gate.FIXTURES[0]
        for bad in ['Dr.','Dr. Müller zahlt 3. 14 Euro.']:
            with self.subTest(bad=bad),self.assertRaisesRegex(RuntimeError,'split or rewritten'):
                gate.validate_audio_contract({**body_for(fixture),'processed_text':bad},fixture)

    def test_terminal_citation_is_consumed_but_never_a_timestamp_word(self):
        fixture=gate.FIXTURES[1]
        data=body_for(fixture)
        data['processed_text']='A careful reader follows the text.'
        gate.validate_audio_contract(data,fixture)
        data['timestamps'].append({'word':'5','start_time':2,'end_time':2.5})
        with self.assertRaisesRegex(RuntimeError,'word sequence'):
            gate.validate_audio_contract(data,fixture)

    def test_remainder_and_conflicting_aliases_fail_the_single_sentence_gate(self):
        fixture=gate.FIXTURES[0]
        data=body_for(fixture)
        with self.assertRaisesRegex(RuntimeError,'remainder'):
            gate.validate_audio_contract({**data,'unprocessed_text':'Müller zahlt 3.14 Euro.'},fixture)
        data['timestamps'][0]['start']=100
        with self.assertRaisesRegex(RuntimeError,'aliases'):
            gate.validate_audio_contract(data,fixture)

    def test_missing_audio_and_reverse_time_are_rejected(self):
        fixture=gate.FIXTURES[0]
        data=body_for(fixture)
        with self.assertRaisesRegex(RuntimeError,'audio string'):
            gate.validate_audio_contract({**data,'audio':''},fixture)
        data['timestamps'][1]['end_time']=.01
        with self.assertRaisesRegex(RuntimeError,'clock moved backward'):
            gate.validate_audio_contract(data,fixture)


if __name__=='__main__':unittest.main()
