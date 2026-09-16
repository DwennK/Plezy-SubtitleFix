import Libmpv
import FlutterMacOS
import XCTest

@testable import PlezyLiveSync

final class ControllablePropertyCore: MpvPlayerCoreBase {
  var nextResult: Result<Void, Error>?
  private(set) var propertyCalls: [(String, String)] = []
  private var pendingCompletion: ((Result<Void, Error>) -> Void)?

  override func setPropertyAsync(
    _ name: String,
    value: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    propertyCalls.append((name, value))
    if let nextResult {
      self.nextResult = nil
      completion(nextResult)
    } else {
      pendingCompletion = completion
    }
  }

  func finish(_ result: Result<Void, Error>) {
    let completion = pendingCompletion
    pendingCompletion = nil
    completion?(result)
  }
}

final class RecordingMpvPlugin: MpvPluginShared {
  var coreBase: MpvPlayerCoreBase?
  var eventSink: FlutterEventSink?
  var nameToId: [String: Int] = [:]
  private(set) var pauseHookValues: [String] = []

  init(core: MpvPlayerCoreBase?) {
    coreBase = core
  }

  func setPlayerVisible(_ visible: Bool, restoreOnWindowVisible: Bool) {}
  func updatePlayerFrame() {}

  func didSetPauseProperty(value: String) {
    pauseHookValues.append(value)
  }
}

final class RecordingLifecycleDelegate: MpvPlayerDelegate {
  private(set) var events: [String] = []
  private(set) var properties: [String] = []

  func onPropertyChange(name: String, value: Any?, sourceId: Int64?) { properties.append(name) }
  func onEvent(name: String, data: [String: Any]?) { events.append(name) }
}

final class MpvPlayerContractTests: XCTestCase {
  func testLiveSyncClientUsesTheActiveLinkedMpvAndRejectsDisposedCore() throws {
    let core = MpvAudioPlayerCore()
    XCTAssertTrue(core.initialize())
    defer {
      core.dispose()
      core.queue.sync {}
    }
    XCTAssertSuccess(awaitProperty(core, name: "pause", value: "yes"))
    let created = expectation(description: "weak client transferred")
    var addresses: [Int64]?
    core.createLiveSyncClient {
      addresses = $0
      created.fulfill()
    }
    wait(for: [created], timeout: 3)
    let values = try XCTUnwrap(addresses)
    XCTAssertEqual(values.count, 6)
    let client = try XCTUnwrap(OpaquePointer(bitPattern: UInt(values[0])))
    let get = unsafeBitCast(
      UInt(values[1]),
      to: (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?, mpv_format, UnsafeMutableRawPointer?) -> Int32).self
    )
    let destroy = unsafeBitCast(UInt(values[5]), to: (@convention(c) (OpaquePointer?) -> Void).self)
    core.queue.sync {
      var paused: Int32 = -1
      XCTAssertEqual(get(client, "pause", MPV_FORMAT_FLAG, &paused), 0)
      XCTAssertEqual(paused, 1)
      destroy(client)
    }
    core.dispose()
    let rejected = expectation(description: "disposed core refuses client")
    core.createLiveSyncClient {
      XCTAssertNil($0)
      rejected.fulfill()
    }
    wait(for: [rejected], timeout: 3)
  }

  func testBundledLibmpvCapturesOnlyAfterActivation() throws {
    // Generated local WAV; no media server, microphone or network is involved.
    var wav = Data()
    func text(_ value: String) { wav.append(contentsOf: value.utf8) }
    func u16(_ value: UInt16) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
    }
    func u32(_ value: UInt32) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
    }
    text("RIFF"); u32(36 + 96000); text("WAVEfmt "); u32(16)
    u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
    text("data"); u32(96000)
    for i in 0..<48000 {
      let sample = Int16(10000 * sin(2 * Double.pi * 317 * Double(i) / 16000))
      u16(UInt16(bitPattern: sample))
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    try wav.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    guard let mpv = mpv_create() else { return XCTFail("mpv_create failed") }
    defer { mpv_terminate_destroy(mpv) }
    for (key, value) in [("config", "no"), ("vo", "null"), ("ao", "null"), ("idle", "yes")] {
      XCTAssertGreaterThanOrEqual(mpv_set_option_string(mpv, key, value), 0)
    }
    XCTAssertGreaterThanOrEqual(mpv_initialize(mpv), 0)
    let strings: [UnsafeMutablePointer<CChar>?] = ["loadfile", file.path].map { argument in
      argument.withCString { strdup($0) }
    }
    defer { strings.forEach { free($0) } }
    var arguments: [UnsafePointer<CChar>?] =
      strings.map { pointer in
        pointer.map { UnsafePointer<CChar>($0) }
      } + [nil]
    XCTAssertGreaterThanOrEqual(mpv_command(mpv, &arguments), 0)
    var enabled: Int32 = -1
    let deadline = Date().addingTimeInterval(5)
    while mpv_get_property(mpv, "livesync-enabled", MPV_FORMAT_FLAG, &enabled) < 0,
      Date() < deadline
    { usleep(10000) }
    XCTAssertEqual(enabled, 0, "A fresh audio chain must start with capture disabled")
    // The chain can exist before its input PCM format is initialized. The
    // opt-in setter correctly refuses capture in that interval. Await its
    // acknowledgement within the original deadline before trying to read PCM.
    var activation = mpv_set_property_string(mpv, "livesync-enabled", "yes")
    while activation == MPV_ERROR_PROPERTY_UNAVAILABLE.rawValue, Date() < deadline {
      usleep(10000)
      activation = mpv_set_property_string(mpv, "livesync-enabled", "yes")
    }
    guard activation >= 0 else {
      return XCTFail("Capture activation was not acknowledged: \(activation)")
    }
    XCTAssertGreaterThanOrEqual(mpv_get_property(mpv, "livesync-enabled", MPV_FORMAT_FLAG, &enabled), 0)
    XCTAssertEqual(enabled, 1)
    var captured: [[String: Any]] = []
    while captured.isEmpty, Date() < deadline {
      usleep(20000)
      var node = mpv_node()
      let status = mpv_get_property(mpv, "livesync-pcm", MPV_FORMAT_NODE, &node)
      XCTAssertGreaterThanOrEqual(status, 0)
      if status >= 0 {
        let value = MpvPlayerCoreBase().convertNode(node) as? [String: Any]
        captured = value?["frames"] as? [[String: Any]] ?? []
        mpv_free_node_contents(&node)
      }
    }
    XCTAssertFalse(captured.isEmpty, "The app-linked decoder must deliver timestamped PCM")
    for frame in captured {
      XCTAssertEqual((frame["rate"] as? Int64), 16000)
      XCTAssertNotNil(frame["pts"] as? Double)
      XCTAssertFalse((frame["pcm"] as? Data ?? Data()).isEmpty)
    }
    XCTAssertGreaterThanOrEqual(mpv_set_property_string(mpv, "livesync-enabled", "no"), 0)
    XCTAssertGreaterThanOrEqual(mpv_get_property(mpv, "livesync-enabled", MPV_FORMAT_FLAG, &enabled), 0)
    XCTAssertEqual(enabled, 0)
  }

  private let failure = NSError(
    domain: "MpvPlayerContractTests",
    code: 1,
    userInfo: [NSLocalizedDescriptionKey: "controlled failure"]
  )

  func testSharedTransportEmitsSourceQualifiedPayloads() {
    let plugin = RecordingMpvPlugin(core: nil)
    plugin.nameToId["time-pos"] = 27
    var messages: [Any?] = []
    plugin.eventSink = { messages.append($0) }
    let sourceId = Int64.max - 7

    plugin.onPropertyChange(name: "time-pos", value: 12.5, sourceId: sourceId)
    plugin.onPropertyChange(name: "time-pos", value: nil, sourceId: nil)
    plugin.onEvent(
      name: "playback-restart",
      data: ["sourceId": sourceId, "positionSeconds": 12.5]
    )

    XCTAssertEqual(messages.count, 3)
    guard
      let sourcedProperty = messages[0] as? [Any?],
      let preStartProperty = messages[1] as? [Any?],
      let lifecycleEvent = messages[2] as? [String: Any],
      let lifecycleData = lifecycleEvent["data"] as? [String: Any]
    else {
      return XCTFail("Expected property triples and a lifecycle event map")
    }
    XCTAssertEqual(sourcedProperty.count, 3)
    XCTAssertEqual(sourcedProperty[0] as? Int, 27)
    XCTAssertEqual(sourcedProperty[1] as? Double, 12.5)
    XCTAssertEqual(sourcedProperty[2] as? Int64, sourceId)
    XCTAssertEqual(preStartProperty.count, 3)
    XCTAssertNil(preStartProperty[1])
    XCTAssertNil(preStartProperty[2])
    XCTAssertEqual(lifecycleEvent["name"] as? String, "playback-restart")
    XCTAssertEqual(lifecycleData["sourceId"] as? Int64, sourceId)
    XCTAssertEqual(lifecycleData["positionSeconds"] as? Double, 12.5)
  }

  func testSharedSetPropertyMapsSuccessFailureMissingCoreAndInvalidArguments() {
    let core = ControllablePropertyCore()
    let plugin = RecordingMpvPlugin(core: core)

    core.nextResult = .success(())
    let success = invokeSetProperty(plugin, name: "pause", value: "no")
    XCTAssertEqual(success.count, 1)
    XCTAssertNil(success[0])
    XCTAssertEqual(plugin.pauseHookValues, ["no"])

    core.nextResult = .failure(failure)
    let rejected = invokeSetProperty(plugin, name: "pause", value: "yes")
    XCTAssertEqual(rejected.count, 1)
    XCTAssertEqual((rejected[0] as? FlutterError)?.code, "SET_PROPERTY_FAILED")
    XCTAssertEqual(plugin.pauseHookValues, ["no"])

    plugin.coreBase = nil
    let missing = invokeSetProperty(plugin, name: "volume", value: "50")
    XCTAssertEqual(missing.count, 1)
    XCTAssertEqual((missing[0] as? FlutterError)?.code, "NOT_INITIALIZED")

    var invalidResults: [Any?] = []
    plugin.handleSetProperty(
      call: FlutterMethodCall(methodName: "setProperty", arguments: ["name": "pause"])
    ) {
      invalidResults.append($0)
    }
    XCTAssertEqual(invalidResults.count, 1)
    XCTAssertEqual((invalidResults[0] as? FlutterError)?.code, "INVALID_ARGS")
  }

  func testSharedSetPropertyMapsLifecycleCancellationAsNotInitialized() {
    let core = ControllablePropertyCore()
    let plugin = RecordingMpvPlugin(core: core)
    core.nextResult = .failure(MpvLifecycleUnavailableError("controlled cancellation"))

    let cancelled = invokeSetProperty(plugin, name: "volume", value: "50")

    XCTAssertEqual(cancelled.count, 1)
    XCTAssertEqual((cancelled[0] as? FlutterError)?.code, "NOT_INITIALIZED")
  }

  func testRealSetPropertyValidInvalidNonexistentAndPauseCache() {
    let core = MpvAudioPlayerCore()
    XCTAssertTrue(core.initialize())
    defer {
      core.dispose()
      core.queue.sync {}
    }

    XCTAssertSuccess(awaitProperty(core, name: "volume", value: "50"))
    XCTAssertTrue(core.isPaused)

    XCTAssertFailure(awaitProperty(core, name: "pause", value: "not-a-flag"))
    XCTAssertTrue(core.isPaused, "A rejected raw pause write must not change the cache")

    XCTAssertFailure(
      awaitProperty(core, name: "plezy-property-does-not-exist", value: "ignored")
    )
    XCTAssertTrue(core.isPaused)

    XCTAssertSuccess(awaitProperty(core, name: "pause", value: "no"))
    XCTAssertFalse(core.isPaused, "The accepted pause write must commit before completion")
  }

  func testMacOSVideoCoreUsesCoreAudioWithAVFoundationFallback() {
    guard let mpv = mpv_create() else {
      return XCTFail("mpv_create failed")
    }
    var initialized = false
    defer {
      if initialized {
        mpv_terminate_destroy(mpv)
      } else {
        mpv_destroy(mpv)
      }
    }

    MpvPlayerCore().configurePlatformMpvOptions(mpv: mpv)
    let initializeResult = mpv_initialize(mpv)
    XCTAssertGreaterThanOrEqual(initializeResult, 0)
    guard initializeResult >= 0 else { return }
    initialized = true

    let optionValue = "options/ao".withCString {
      mpv_get_property_string(mpv, $0)
    }
    defer { mpv_free(optionValue) }
    XCTAssertEqual(optionValue.map { String(cString: $0) }, "coreaudio,avfoundation")
  }

  func testPauseIntentUpdatesCacheBeforeAsyncWriteCompletes() {
    let core = MpvAudioPlayerCore()
    XCTAssertTrue(core.initialize())
    defer {
      core.dispose()
      core.queue.sync {}
    }

    let queueEntered = expectation(description: "mpv queue blocked")
    let releaseQueue = DispatchSemaphore(value: 0)
    core.queue.async {
      queueEntered.fulfill()
      releaseQueue.wait()
    }
    wait(for: [queueEntered], timeout: 2)

    let completion = expectation(description: "pause write completed")
    core.setPropertyAsync("pause", value: "no") { result in
      if case .failure(let error) = result {
        XCTFail("Pause write failed: \(error)")
      }
      completion.fulfill()
    }

    XCTAssertFalse(core.isPaused, "The public pause intent must be visible before the native write completes")
    releaseQueue.signal()
    wait(for: [completion], timeout: 2)
  }

  func testPendingSetPropertyIsCancelledExactlyOnceOnDispose() {
    let core = MpvAudioPlayerCore()
    XCTAssertTrue(core.initialize())

    let queueEntered = expectation(description: "mpv queue blocked")
    let releaseQueue = DispatchSemaphore(value: 0)
    core.queue.async {
      queueEntered.fulfill()
      releaseQueue.wait()
    }
    wait(for: [queueEntered], timeout: 2)

    let completion = expectation(description: "cancelled property completion")
    completion.assertForOverFulfill = true
    var completionCount = 0
    var completionError: Error?
    core.setPropertyAsync("volume", value: "51") { result in
      completionCount += 1
      switch result {
      case .success:
        XCTFail("Disposal must fail an accepted-but-pending property request")
      case .failure(let error):
        completionError = error
      }
      completion.fulfill()
    }

    core.dispose()
    releaseQueue.signal()
    wait(for: [completion], timeout: 2)
    core.queue.sync {}
    XCTAssertEqual(completionCount, 1)
    XCTAssertTrue(completionError is MpvLifecycleUnavailableError)
    let unavailableResult = awaitProperty(core, name: "volume", value: "52")
    XCTAssertFailure(unavailableResult)
    if case .failure(let error) = unavailableResult {
      XCTAssertTrue(error is MpvLifecycleUnavailableError)
    }
  }

  func testRapidAudioCoreReplacementOwnsLifecycleOnce() {
    for _ in 0..<5 {
      autoreleasepool {
        let core = MpvAudioPlayerCore()
        XCTAssertTrue(core.initialize())
        core.dispose()
        core.dispose()
        core.queue.sync {}
        XCTAssertFalse(core.hasActiveMpv)
      }
    }
  }

  func testQueuedDelegateDeliveryIsDroppedAfterTerminalTransition() {
    let core = MpvPlayerCoreBase()
    let delegate = RecordingLifecycleDelegate()
    core.delegate = delegate
    let enqueueAndDispose = {
      core.dispatchDelegateEvent(name: "file-loaded", data: nil)
      core.dispatchDelegateProperty(name: "time-pos", value: 1.0, sourceId: 7)
      XCTAssertTrue(core.beginDisposal())
    }
    if Thread.isMainThread {
      enqueueAndDispose()
    } else {
      DispatchQueue.main.sync(execute: enqueueAndDispose)
    }

    let drained = expectation(description: "main delivery drained")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)
    XCTAssertTrue(delegate.events.isEmpty)
    XCTAssertTrue(delegate.properties.isEmpty)
  }

  func testUnavailablePropertyCompletionRunsExactlyOnceOnMainThread() {
    let core = MpvAudioPlayerCore()
    XCTAssertTrue(core.initialize())
    core.dispose()
    core.queue.sync {}

    let completed = expectation(description: "unavailable property completed")
    completed.assertForOverFulfill = true
    var completionCount = 0
    DispatchQueue.global().async {
      core.getPropertyAsync("volume") { result in
        XCTAssertTrue(Thread.isMainThread)
        if case .success = result { XCTFail("Expected unavailable property failure") }
        completionCount += 1
        completed.fulfill()
      }
    }
    wait(for: [completed], timeout: 2)
    XCTAssertEqual(completionCount, 1)
  }

  func testNormalizedPlaybackDelayStringsPassThroughUnchanged() {
    let core = ControllablePropertyCore()
    let plugin = RecordingMpvPlugin(core: core)
    let values = ["0.25", "-0.5", "0", "0.25"]

    for value in values {
      core.nextResult = .success(())
      let result = invokeSetProperty(plugin, name: "audio-delay", value: value)
      XCTAssertEqual(result.count, 1)
      XCTAssertNil(result[0])
    }
    XCTAssertEqual(core.propertyCalls.map(\.1), values)
  }

  func testNodeConversionBoundsAndDiscardsMalformedSiblings() {
    let core = MpvPlayerCoreBase()
    var valid = mpv_node()
    valid.format = MPV_FORMAT_INT64
    valid.u.int64 = 7
    var malformed = mpv_node()
    malformed.format = MPV_FORMAT_NONE
    var values = [valid, malformed, valid]
    var decoded: Any?

    let valueCount = values.count
    values.withUnsafeMutableBufferPointer { valuesPointer in
      var list = mpv_node_list()
      list.num = Int32(valueCount)
      list.values = valuesPointer.baseAddress
      withUnsafeMutablePointer(to: &list) { listPointer in
        var root = mpv_node()
        root.format = MPV_FORMAT_NODE_ARRAY
        root.u.list = listPointer
        decoded = core.convertNode(root)
      }
    }
    XCTAssertEqual(decoded as? [Int64], [7, 7])

    var oversizedBytes = mpv_byte_array()
    oversizedBytes.size = 16 * 1_024 * 1_024 + 1
    withUnsafeMutablePointer(to: &oversizedBytes) { bytePointer in
      var root = mpv_node()
      root.format = MPV_FORMAT_BYTE_ARRAY
      root.u.ba = bytePointer
      XCTAssertNil(core.convertNode(root))
    }
    XCTAssertTrue(core.validateSideDataDimensions(width: 3_840, height: 2_160))
    XCTAssertFalse(core.validateSideDataDimensions(width: 0, height: 2_160))
    XCTAssertFalse(core.validateSideDataDimensions(width: 65_536, height: 2_160))
    XCTAssertFalse(core.validateSideDataDimensions(width: 16_384, height: 16_384))
  }

  private func invokeSetProperty(
    _ plugin: RecordingMpvPlugin,
    name: String,
    value: String
  ) -> [Any?] {
    var results: [Any?] = []
    plugin.handleSetProperty(
      call: FlutterMethodCall(
        methodName: "setProperty",
        arguments: ["name": name, "value": value]
      )
    ) {
      results.append($0)
    }
    return results
  }

  private func awaitProperty(
    _ core: MpvPlayerCoreBase,
    name: String,
    value: String
  ) -> Result<Void, Error> {
    let completion = expectation(description: "set \(name)")
    var propertyResult: Result<Void, Error>?
    core.setPropertyAsync(name, value: value) {
      propertyResult = $0
      completion.fulfill()
    }
    wait(for: [completion], timeout: 2)
    return propertyResult ?? .failure(failure)
  }

  private func XCTAssertSuccess(
    _ result: Result<Void, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    if case .failure(let error) = result {
      XCTFail("Expected success, received \(error)", file: file, line: line)
    }
  }

  private func XCTAssertFailure(
    _ result: Result<Void, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    if case .success = result {
      XCTFail("Expected failure", file: file, line: line)
    }
  }
}
