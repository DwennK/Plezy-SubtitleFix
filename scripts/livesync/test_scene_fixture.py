import copy
import json
import struct
import unittest

from create_scene_fixture import cue_projection, edit_pcm, edit_plan, frames
from prepare_native import ROOT
from evaluate_scene_probe import evaluate


class SceneFixtureTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads((ROOT / 'test/fixtures/livesync/scene-edits-development.json').read_text())

    def test_insert_has_two_offsets_and_an_exact_video_only_interval(self):
        _, truth = edit_plan(self.manifest, 'added-scene')
        self.assertEqual(truth['expectedFrames'], 105 * 48000)
        self.assertEqual(truth['gaps'], [{'kind': 'videoOnly', 'start': 34.5, 'end': 64.5}])
        self.assertEqual([s['offset'] for s in truth['segments']], [-100, -70])
        self.assertEqual(truth['segments'][1]['subtitleStart'], 134.5)

    def test_removed_scene_is_absent_from_pcm_but_remains_in_the_subtitle_timeline(self):
        _, truth = edit_plan(self.manifest, 'removed-scene')
        self.assertEqual(truth['expectedFrames'], 62 * 48000)
        self.assertEqual(truth['gaps'], [{'kind': 'subtitleOnly', 'start': 134.5, 'end': 147.5}])
        self.assertEqual(truth['segments'][1], {'subtitleStart': 147.5, 'subtitleEnd': 175, 'slope': 1, 'offset': -113})

    def test_copy_ranges_preserve_stereo_sample_pairs_and_half_open_edges(self):
        main = struct.pack('<12h', 0, 10, 1, 11, 2, 12, 3, 13, 4, 14, 5, 15)
        inserted = struct.pack('<4h', 20, 30, 21, 31)
        result = edit_pcm({'main': main, 'insert': inserted},
                          [('main', 0, 2), ('insert', 0, 2), ('main', 2, 6)], 4)
        self.assertEqual(struct.unpack('<16h', result), (0, 10, 1, 11, 20, 30, 21, 31, 2, 12, 3, 13, 4, 14, 5, 15))
        removed = edit_pcm({'main': main}, [('main', 0, 2), ('main', 4, 6)], 4)
        self.assertEqual(struct.unpack('<8h', removed), (0, 10, 1, 11, 4, 14, 5, 15))
        with self.assertRaises(ValueError):
            edit_pcm({'main': main}, [('main', 0, 7)], 4)

    def test_a_crossing_cue_is_split_around_the_insert_without_losing_its_identity(self):
        _, truth = edit_plan(self.manifest, 'added-scene-crossing-cue')
        srt = '8\n00:02:15,000 --> 00:02:17,500\nA retained cue with original styling.\n'
        self.assertEqual(cue_projection(srt, truth), [{
            'cue': 8, 'sourceStart': 135, 'sourceEnd': 137.5, 'crossesEditBoundary': True,
            'expectedMediaFragments': [[35, 36.25], [66.25, 67.5]],
        }])

    def test_removed_cues_have_no_media_fragment_and_crossing_cues_are_clipped(self):
        _, truth = edit_plan(self.manifest, 'removed-scene')
        srt = ('1\r\n00:02:14,000 --> 00:02:15,000\r\nCrosses first cut.\r\n\r\n'
               '2\r\n00:02:20,000 --> 00:02:21,000\r\nRemoved.\r\n\r\n'
               '3\r\n00:02:27,000 --> 00:02:28,000\r\nCrosses second cut.\r\n')
        cues = cue_projection(srt, truth)
        self.assertEqual([c['expectedMediaFragments'] for c in cues], [[[34, 34.5]], [], [[34.5, 35]]])
        self.assertEqual([c['crossesEditBoundary'] for c in cues], [True, False, True])

    def test_correct_offsets_do_not_hide_missing_or_wrong_scene_boundaries(self):
        _, truth = edit_plan(self.manifest, 'added-scene')
        samples = [{'mediaTime': t, 'nativeDelay': -100, 'mappingAvailable': True, 'regionKind': 'aligned'}
                   for t in range(15, 34)]
        samples += [{'mediaTime': t, 'nativeDelay': -70, 'mappingAvailable': True, 'regionKind': 'aligned'}
                    for t in range(66, 86)]
        report = {'acquisitionMs': 15000, 'trackingSamples': samples, 'learnedGaps': []}
        missing = evaluate(report, truth)
        self.assertEqual(missing['alignedTrackingP95ErrorSeconds'], 0)
        self.assertFalse(missing['satisfiesSceneDomainChecks'])
        report['learnedGaps'] = copy.deepcopy(truth['gaps'])
        correct = evaluate(report, truth)
        self.assertTrue(correct['satisfiesSceneDomainChecks'])
        self.assertFalse(correct['cueBoundaryRenderingValidated'])
        self.assertFalse(correct['backwardSeekValidated'])
        report['learnedGaps'][0]['start'] += 1
        self.assertFalse(evaluate(report, truth)['satisfiesSceneDomainChecks'])

    def test_invalid_edits_and_fractional_samples_are_rejected(self):
        manifest = copy.deepcopy(self.manifest)
        manifest['cases']['removed-scene']['endSubtitleSeconds'] = 176
        with self.assertRaises(ValueError):
            edit_plan(manifest, 'removed-scene')
        manifest['cases']['added-scene']['atSubtitleSeconds'] = 99
        with self.assertRaises(ValueError):
            edit_plan(manifest, 'added-scene')
        with self.assertRaises(ValueError):
            frames(0.00001, 48000)


if __name__ == '__main__':
    unittest.main()
