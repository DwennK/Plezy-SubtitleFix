/// Reporting gates only; these never alter the synchronization algorithm.
class LiveSyncProbeMetrics {
  LiveSyncProbeMetrics(Iterable<double> errors) : _errors = errors.toList()..sort();

  final List<double> _errors;
  bool get valid => _errors.isNotEmpty && _errors.every((error) => error.isFinite && error >= 0);
  double? get median => !valid
      ? null
      : _errors.length.isOdd
      ? _errors[_errors.length ~/ 2]
      : (_errors[_errors.length ~/ 2 - 1] + _errors[_errors.length ~/ 2]) / 2;
  double? get p95 => valid ? _errors[(_errors.length * 0.95).ceil() - 1] : null;
  double? get maximum => valid ? _errors.last : null;

  bool passes({
    required int? acquisitionMs,
    required int maximumAcquisitionMs,
    required double maximumMedianError,
    required double maximumP95Error,
    required bool slopeConfirmed,
    required bool finalMappingAvailable,
  }) =>
      valid &&
      _errors.length >= 10 &&
      acquisitionMs != null &&
      acquisitionMs <= maximumAcquisitionMs &&
      median! < maximumMedianError &&
      p95! < maximumP95Error &&
      slopeConfirmed &&
      finalMappingAvailable;
}
