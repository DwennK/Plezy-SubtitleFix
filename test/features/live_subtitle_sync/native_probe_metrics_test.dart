import 'package:flutter_test/flutter_test.dart';

import '../../../tool/livesync_probe_metrics.dart';

void main() {
  bool passes(List<double> errors, {int? acquired = 34000}) => LiveSyncProbeMetrics(errors).passes(
    acquisitionMs: acquired,
    maximumAcquisitionMs: 45000,
    maximumMedianError: 0.25,
    maximumP95Error: 0.75,
    slopeConfirmed: true,
    finalMappingAvailable: true,
  );

  test('p95 success cannot conceal a failed median', () {
    expect(passes(List.filled(20, 0.66)), isFalse);
    expect(passes([...List.filled(18, 0.1), 0.5, 0.6]), isTrue);
    expect(passes([...List.filled(18, 0.1), 0.8, 0.9]), isFalse);
  });

  test('missing, late, or insufficient acquisition evidence cannot pass', () {
    expect(passes(List.filled(20, 0), acquired: null), isFalse);
    expect(passes(List.filled(20, 0), acquired: 45001), isFalse);
    expect(passes(List.filled(9, 0)), isFalse);
  });

  test('invalid measurements never pass or expose numeric percentiles', () {
    for (final values in <List<double>>[
      [],
      [double.nan],
      [double.infinity],
      [-0.1],
    ]) {
      final metrics = LiveSyncProbeMetrics(values);
      expect(metrics.median, isNull);
      expect(metrics.p95, isNull);
      expect(passes(values), isFalse);
    }
  });

  test('median averages the central pair and does not mutate caller data', () {
    final values = [0.7, 0.1, 0.3, 0.2];
    final metrics = LiveSyncProbeMetrics(values);
    expect(metrics.median, 0.25);
    expect(metrics.p95, 0.7);
    expect(values, [0.7, 0.1, 0.3, 0.2]);
  });
}
