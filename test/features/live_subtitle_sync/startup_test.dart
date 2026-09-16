import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/startup.dart';

void main() {
  test('capture starts while the complete subtitle document is still pending', () async {
    final document = Completer<String>();
    final opened = Completer<void>();
    var finished = false;
    var closed = false;
    final startup =
        prepareLiveSyncInputs(
          loadSubtitles: () => document.future,
          openCapture: () async {
            opened.complete();
            return 'capture';
          },
          cancelPending: () => fail('successful startup must not cancel'),
          closeCapture: (_) async => closed = true,
        ).then((value) {
          finished = true;
          return value;
        });
    await opened.future;
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    expect(closed, isFalse);
    document.complete('complete SRT');
    expect(await startup, ('complete SRT', 'capture'));
    expect(closed, isFalse);
  });

  test('a ready subtitle document still waits for the capture owner', () async {
    final capture = Completer<String>();
    var finished = false;
    final startup =
        prepareLiveSyncInputs(
          loadSubtitles: () async => 'index',
          openCapture: () => capture.future,
          cancelPending: () => fail('successful startup must not cancel'),
          closeCapture: (_) async => fail('ownership belongs to the caller'),
        ).then((value) {
          finished = true;
          return value;
        });
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    capture.complete('capture');
    expect(await startup, ('index', 'capture'));
  });

  test('a subtitle failure cancels preparation and awaits capture teardown', () async {
    final document = Completer<String>();
    final teardown = Completer<void>();
    final closing = Completer<void>();
    final original = StateError('source failed');
    var cancellations = 0;
    var finished = false;
    final startup = prepareLiveSyncInputs(
      loadSubtitles: () => document.future,
      openCapture: () async => 'capture',
      cancelPending: () => cancellations++,
      closeCapture: (capture) async {
        expect(capture, 'capture');
        closing.complete();
        await teardown.future;
      },
    );
    final observed = expectLater(startup, throwsA(same(original))).then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    document.completeError(original);
    await closing.future;
    expect(cancellations, 1);
    expect(finished, isFalse);
    teardown.complete();
    await observed;
  });

  test('capture finishing after the sibling fails is still closed exactly once', () async {
    final capture = Completer<String>();
    final document = Completer<String>();
    final cancelled = Completer<void>();
    var closes = 0;
    final original = StateError('source failed');
    final startup = prepareLiveSyncInputs(
      loadSubtitles: () => document.future,
      openCapture: () => capture.future,
      cancelPending: cancelled.complete,
      closeCapture: (_) async => closes++,
    );
    final observed = expectLater(startup, throwsA(same(original)));
    document.completeError(original);
    await cancelled.future;
    expect(closes, 0);
    capture.complete('late capture');
    await observed;
    expect(closes, 1);
  });

  test('capture failure aborts the source and preserves the initiating error', () async {
    final document = Completer<String>();
    final original = StateError('native unavailable');
    var cancellations = 0;
    final startup = prepareLiveSyncInputs(
      loadSubtitles: () => document.future,
      openCapture: () async => throw original,
      cancelPending: () {
        cancellations++;
        document.completeError(StateError('source aborted'));
      },
      closeCapture: (_) async => fail('no capture was opened'),
    );
    await expectLater(startup, throwsA(same(original)));
    expect(cancellations, 1);
  });

  test('subtitle failure preserves its reason when cancelling model preparation', () async {
    final document = Completer<String>();
    final capture = Completer<String>();
    final original = StateError('invalid SRT');
    final startup = prepareLiveSyncInputs(
      loadSubtitles: () => document.future,
      openCapture: () => capture.future,
      cancelPending: () => capture.completeError(StateError('model cancelled')),
      closeCapture: (_) async => fail('no capture was opened'),
    );
    final observed = expectLater(startup, throwsA(same(original)));
    document.completeError(original);
    await observed;
  });

  test('synchronous source rejection does not begin model preparation', () async {
    final original = StateError('unsupported');
    await expectLater(
      prepareLiveSyncInputs<String, String>(
        loadSubtitles: () => throw original,
        openCapture: () async => fail('source already rejected'),
        cancelPending: () {},
        closeCapture: (_) async => fail('no capture was opened'),
      ),
      throwsA(same(original)),
    );
  });

  test('capture cleanup failure is surfaced instead of claiming a clean teardown', () async {
    final document = Completer<String>();
    final cleanup = StateError('native close failed');
    final startup = prepareLiveSyncInputs(
      loadSubtitles: () => document.future,
      openCapture: () async => 'capture',
      cancelPending: () {},
      closeCapture: (_) async => throw cleanup,
    );
    final observed = expectLater(startup, throwsA(same(cleanup)));
    await Future<void>.delayed(Duration.zero);
    document.completeError(StateError('bad SRT'));
    await observed;
  });
}
