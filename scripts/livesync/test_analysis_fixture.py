import unittest

from create_analysis_fixture import shift_srt_timecodes


class SubtitleShiftTests(unittest.TestCase):
    def test_intro_case_preserves_text_and_positioning(self):
        source = '1\n00:01:47,250 --> 00:01:50,500 X1:100 X2:500\n<i>Carry the lantern.</i>\n\n'
        result = shift_srt_timecodes(source, -100000)
        self.assertEqual(result, '1\n00:00:07,250 --> 00:00:10,500 X1:100 X2:500\n<i>Carry the lantern.</i>\n\n')

    def test_hour_and_minute_boundaries(self):
        source = '1\n00:59:59,900 --> 01:00:00,100\nExample.\n'
        self.assertIn('01:01:29,900 --> 01:01:30,100', shift_srt_timecodes(source, 90000))

    def test_negative_or_unrecognized_times_fail_instead_of_changing_the_text(self):
        with self.assertRaises(ValueError):
            shift_srt_timecodes('1\n00:00:01,000 --> 00:00:02,000\nExample.\n', -3000)
        with self.assertRaises(ValueError):
            shift_srt_timecodes('1\nmalformed --> 00:00:02,000\nExample.\n', 1000)


if __name__ == '__main__':
    unittest.main()
