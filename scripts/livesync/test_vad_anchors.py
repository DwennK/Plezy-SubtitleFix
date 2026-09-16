import unittest

from probe_vad_anchors import cue_starts, distance_to_voice, speech_intervals


class VadAnchorTests(unittest.TestCase):
    def test_native_centiseconds_are_not_mistaken_for_seconds(self):
        text = 'Detected 2 speech segments:\nSpeech segment 0: start = 29.00, end = 221.00\nSpeech segment 1: start = 330.00, end = 377.00\n'
        self.assertEqual(speech_intervals(text, 8), [[0.29, 2.21], [3.3, 3.77]])
        with self.assertRaises(ValueError):
            speech_intervals(text, 2)

    def test_incomplete_output_is_not_silence(self):
        for text in ('', 'error: missing model', 'Detected 1 speech segments:\n'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                speech_intervals(text, 8)
        self.assertEqual(speech_intervals('Detected 0 speech segments:\n', 8), [])

    def test_final_probability_frame_does_not_invent_audio_after_the_window(self):
        text = 'Detected 1 speech segments:\nSpeech segment 0: start = 624.00, end = 803.00\n'
        self.assertEqual(speech_intervals(text, 8.019375), [[6.24, 8.019375]])
        with self.assertRaises(ValueError):
            speech_intervals(text.replace('803.00', '808.00'), 8.019375)

    def test_anchor_support_preserves_absolute_media_origin(self):
        self.assertEqual(distance_to_voice(76, [[79, 82]]), 3)
        self.assertEqual(distance_to_voice(80, [[79, 82]]), 0)
        self.assertIsNone(distance_to_voice(80, []))

    def test_srt_ordinals_remain_zero_based_independent_of_display_number(self):
        self.assertEqual(cue_starts('7\n00:02:09,400 --> 00:02:13,800\nA cue\n\n8\n00:02:15,000 --> 00:02:17,500\nAnother cue'),
                         [129.4, 135])


if __name__ == '__main__':
    unittest.main()
