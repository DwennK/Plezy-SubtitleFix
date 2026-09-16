import unittest
from unittest.mock import patch

from probe_pcm import collect


class SeekEpochTests(unittest.TestCase):
    def collect(self, packets):
        now = [0.0]
        last = [packets[-1]]
        iterator = iter(packets)

        class Player:
            def get(self, key):
                last[0] = next(iterator, last[0])
                return last[0]

        def sleep(seconds):
            now[0] += seconds

        with patch('probe_pcm.time.monotonic', side_effect=lambda: now[0]), \
                patch('probe_pcm.time.sleep', side_effect=sleep), \
                patch('probe_pcm.check_frame', side_effect=lambda frame: {'pts': frame['pts']}) as checked:
            result = collect(Player(), duration=0.06, after_epoch=2)
            return result, checked.call_count

    @staticmethod
    def packet(epoch, pts=None):
        return {'version': 1, 'epoch': epoch,
                'frames': [] if pts is None else [{'pts': pts, 'pcm': b''}]}

    def test_queued_seek_validates_old_frames_separately(self):
        result, calls = self.collect([self.packet(2, 7.8), self.packet(2), self.packet(3, 2.0)])
        self.assertEqual(result['epochs'], [3])
        self.assertEqual(result['seekTransition'], {'epochs': [2], 'validatedFrames': 1})
        self.assertTrue(all(frame['pts'] == 2.0 for frame in result['frames']))
        self.assertGreater(calls, len(result['frames']))

    def test_no_epoch_change_times_out(self):
        with self.assertRaisesRegex(AssertionError, 'did not reset'):
            self.collect([self.packet(2, 7.8)])

    def test_old_generation_cannot_return_after_reset(self):
        with self.assertRaisesRegex(AssertionError, 'regressed'):
            self.collect([self.packet(3, 2.0), self.packet(2, 7.8)])

    def test_empty_new_generation_does_not_prove_capture(self):
        with self.assertRaisesRegex(AssertionError, 'No native PCM'):
            self.collect([self.packet(3)])


if __name__ == '__main__':
    unittest.main()
