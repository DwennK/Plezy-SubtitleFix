import unittest

from create_speech_fixture import captions, timestamp


class SpeechFixtureTests(unittest.TestCase):
    def test_sample_boundaries_round_across_second_and_hour(self):
        self.assertEqual(timestamp(16000 * 60), "00:01:00,000")
        self.assertEqual(timestamp(16000 * 3600 + 8), "01:00:00,001")
        self.assertEqual(timestamp(15999), "00:00:01,000")
        with self.assertRaises(ValueError):
            timestamp(-1)

    def test_text_is_preserved_and_boundaries_come_from_sample_counts(self):
        text, boundaries, count = captions([("a", 16000, "Original TEXT."), ("b", 24000, "Second utterance!")])
        self.assertIn("00:00:01,000 --> 00:00:02,500\nSecond utterance!", text)
        self.assertIn("Original TEXT.", text)
        self.assertEqual(boundaries[1], {"id": "b", "startSample": 16000, "endSample": 40000})
        self.assertEqual(count, 40000)

    def test_invalid_or_empty_utterances_cannot_create_zero_length_cues(self):
        for utterances in [[], [("a", 0, "Words")], [("a", 1, "Words")], [("a", 1, "")], [("a", 16000, "a\nb")]]:
            with self.assertRaises(ValueError):
                captions(utterances)


if __name__ == "__main__":
    unittest.main()
