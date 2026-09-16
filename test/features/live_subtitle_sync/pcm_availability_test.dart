import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/pcm_availability.dart';

void main() {
  test('missing PCM expires after thirty observed active seconds', () {
    final availability = PcmAvailability();
    for (var time = 0; time < 30000; time += 500) {
      expect(availability.expired(nowMs: time, samples: 0, playing: true, buffering: false), isFalse);
    }
    expect(availability.expired(nowMs: 30000, samples: 0, playing: true, buffering: false), isTrue);
  });

  test('silence with samples and buffering do not count as a missing capture', () {
    final availability = PcmAvailability();
    for (var time = 0; time < 120000; time += 500) {
      expect(availability.expired(nowMs: time, samples: 128000, playing: true, buffering: false), isFalse);
      expect(availability.expired(nowMs: time, samples: 0, playing: true, buffering: true), isFalse);
    }
  });

  test('pause, reset and a delayed poll cannot falsely expire on resume', () {
    final availability = PcmAvailability();
    for (var time = 0; time < 29500; time += 500) {
      availability.expired(nowMs: time, samples: 0, playing: true, buffering: false);
    }
    expect(availability.expired(nowMs: 29500, samples: 0, playing: false, buffering: false), isFalse);
    expect(availability.expired(nowMs: 200000, samples: 0, playing: true, buffering: false), isFalse);
    availability.clear();
    expect(availability.expired(nowMs: 999999, samples: 0, playing: true, buffering: false), isFalse);
  });
}
