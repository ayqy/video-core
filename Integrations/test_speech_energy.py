import array
import math
import sys
import unittest

from speech_energy import EnergyError, energy_from_pcm


def pcm(values):
    result = array.array('f', values)
    if sys.byteorder != 'little':
        result.byteswap()
    return result.tobytes()


class SpeechEnergyTests(unittest.TestCase):
    def test_pause_and_actual_tail_are_bound_to_source_frames(self):
        # 100 ms voiced, 100 ms silent, 100 ms softer tail. No synthesized
        # speech or media file is involved in this signal-analysis rule.
        raw = pcm([.5] * 4800 + [0] * 4800 + [.1] * 4800)
        cues = energy_from_pcm(raw, sample_rate=48000, fps=30, duration_frames=9)
        self.assertEqual([(v['startFrame'], v['endFrame']) for v in cues], [(0, 3), (3, 6), (6, 9)])
        self.assertAlmostEqual(cues[0]['rms'], .5)
        self.assertEqual(cues[1]['rms'], 0)
        self.assertAlmostEqual(cues[2]['rms'], .1)
        self.assertEqual(raw, pcm([.5] * 4800 + [0] * 4800 + [.1] * 4800))

    def test_partial_cue_consumes_complete_tail(self):
        cues = energy_from_pcm(pcm([0] * 4800 + [.25] * 1600), sample_rate=48000,
                               fps=30, duration_frames=4)
        self.assertEqual(cues[-1], dict(startFrame=3, endFrame=4, rms=.25))

    def test_wrong_duration_nonfinite_and_partial_pcm_rejected(self):
        for raw, frames in ((pcm([0] * 4800), 20), (pcm([math.nan] * 4800), 3),
                            (b'123', 3), (pcm([9] * 4800), 3)):
            with self.subTest(frames=frames, size=len(raw)), self.assertRaises(EnergyError):
                energy_from_pcm(raw, sample_rate=48000, fps=30, duration_frames=frames)

    def test_float_decoder_overshoot_does_not_reject_an_original_take(self):
        cues = energy_from_pcm(pcm([1.002] * 4800), sample_rate=48000, fps=30, duration_frames=3)
        self.assertEqual(cues[0]['rms'], 1)


if __name__ == '__main__':
    unittest.main()
