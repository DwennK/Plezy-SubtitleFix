import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/analysis_cadence.dart';

void main() {
  int interval(AnalysisCadence cadence) => cadence.intervalMs(synced: false, established: false);

  test('quiet intro backs off but weak recognized dialogue promptly retries a wider window', () {
    final cadence = AnalysisCadence();
    for (var i = 0; i < 6; i++) {
      cadence.submitted();
      cadence.evidence(recognizedPassage: false, learned: false);
    }
    expect(interval(cadence), 30000);
    cadence.evidence(recognizedPassage: true, learned: false);
    expect(interval(cadence), 12000);
    expect(cadence.windowSeconds, 15);
    cadence.evidence(recognizedPassage: true, learned: true);
    expect(cadence.windowSeconds, 12);
    expect(cadence.intervalMs(synced: true, established: false), 30000);
    expect(cadence.intervalMs(synced: true, established: true), 90000);
  });

  test('transient inference failure retries twice without creating an unbounded fast loop', () {
    final cadence = AnalysisCadence();
    for (var i = 0; i < 6; i++) {
      cadence.submitted();
    }
    for (var i = 0; i < 2; i++) {
      cadence.rejectedInference();
      expect(interval(cadence), 12000);
      cadence.submitted();
    }
    cadence.rejectedInference();
    expect(interval(cadence), 30000);
    cadence.evidence(recognizedPassage: false, learned: false);
    cadence.rejectedInference();
    expect(interval(cadence), 12000);
    cadence.clear();
    expect(cadence.attempts, 0);
    expect(cadence.windowSeconds, 12);
    expect(interval(cadence), 12000);
  });
}
