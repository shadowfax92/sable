import XCTest
@testable import SableCore

/// In-memory effects and explicit suspension gates prove lifecycle ownership
/// without windows, real permission probes, global keys or pasteboard access.
@MainActor
final class RewriteInteractionTests: XCTestCase {
    private final class Gate<T> {
        var continuations: [CheckedContinuation<T, Never>] = []
        var waiting: (() -> Void)?
        func wait() async -> T {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
                waiting?()
            }
        }
        func resume(_ value: T) { continuations.removeFirst().resume(returning: value) }
    }

    private actor Generator: TextGenerating {
        var requests: [GenerationRequest] = []
        var continuations: [CheckedContinuation<String, Error>] = []
        let firstStarted: (@Sendable () -> Void)?
        let started: @Sendable () -> Void
        init(firstStarted: (@Sendable () -> Void)? = nil, started: @escaping @Sendable () -> Void) {
            self.firstStarted = firstStarted
            self.started = started
        }
        func rewrite(_ request: GenerationRequest) async throws -> String {
            requests.append(request)
            return try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
                if requests.count == 1 { firstStarted?() }
                started()
            }
        }
        func complete(_ value: String, index: Int = 0) {
            continuations.remove(at: index).resume(returning: value)
        }
        func fail() { continuations.removeFirst().resume(throwing: GenerationError.incomplete) }
        func inputs() -> [GenerationRequest] { requests }
    }

    @MainActor
    private final class Effects {
        var records: [RunRecord] = []
        var clipboard: [String] = []
        var clipboardVersion = 0
        var acceptsClipboard = true
        var closed: [UUID] = []
        var screenshots = 0
        var cleaned = 0
        var events: [UUID] = []
        var review: (() -> Void)?
        var captured: (() -> Void)?
        var copied: (() -> Void)?
        func bind(_ owner: RewriteInteraction) {
            owner.onRecord = { self.records.append($0) }
            owner.onClose = { self.closed.append($0) }
            owner.onEvent = { event in
                switch event {
                case let .captured(id, _, _): self.events.append(id); self.captured?()
                case let .review(id, _, _): self.events.append(id); self.review?()
                case let .copied(id, _): self.events.append(id); self.copied?()
                case let .running(id), let .failed(id, _): self.events.append(id)
                }
            }
        }
    }

    private func make(_ generator: Generator, effects: Effects,
                      capture: @escaping (InteractionSource) async throws -> String = { _ in "selected" },
                      uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                      pause: @escaping () async throws -> Void = { await Task.yield() }) -> RewriteInteraction {
        let owner = RewriteInteraction(generation: generator, capture: capture, screenshot: {
            effects.screenshots += 1
            return InteractionAttachment(path: "/fake/screenshot") { effects.cleaned += 1 }
        }, writeClipboard: {
            guard effects.acceptsClipboard else { return nil }
            effects.clipboard.append($0)
            effects.clipboardVersion += 1
            return effects.clipboardVersion
        }, clipboardRevision: { effects.clipboardVersion }, uptime: uptime, focusPause: pause)
        effects.bind(owner)
        return owner
    }

    private func ready(_ owner: RewriteInteraction, effects: Effects,
                       source: InteractionSource? = nil) async -> UUID {
        let captured = expectation(description: "capture")
        effects.captured = { captured.fulfill() }
        let id = owner.begin(source: source ?? InteractionSource())
        await fulfillment(of: [captured], timeout: 2)
        effects.captured = nil
        return id
    }

    func testSupersededCaptureCannotPresentOrCloseNewSession() async {
        let gate = Gate<String>()
        let firstWaiting = expectation(description: "first capture waiting")
        gate.waiting = { firstWaiting.fulfill() }
        let effects = Effects()
        let generator = Generator(started: {})
        let owner = make(generator, effects: effects, capture: { _ in await gate.wait() })
        let first = owner.begin(source: InteractionSource())
        await fulfillment(of: [firstWaiting], timeout: 2)
        let secondWaiting = expectation(description: "second capture waiting")
        gate.waiting = { secondWaiting.fulfill() }
        let second = owner.begin(source: InteractionSource())
        await fulfillment(of: [secondWaiting], timeout: 2)
        gate.resume("old capture")
        let captured = expectation(description: "only new capture")
        effects.captured = { captured.fulfill() }
        gate.resume("new capture")
        await fulfillment(of: [captured], timeout: 2)
        XCTAssertEqual(effects.events, [second])
        XCTAssertEqual(effects.closed, [first])
        XCTAssertEqual(owner.interactionID, second)
        owner.cancel(restoreFocus: false)
    }

    func testOverlappingRunsIgnoreLateSuccessAndStaleDelivery() async {
        let started = expectation(description: "two runs started")
        started.expectedFulfillmentCount = 2
        let firstStarted = expectation(description: "first run started")
        let generator = Generator(firstStarted: { firstStarted.fulfill() }) { started.fulfill() }
        let effects = Effects()
        let owner = make(generator, effects: effects)
        let mode = SableMode(name: "Fix", instruction: "fix")
        let settings = SableSettings(modes: [mode], generation: GenerationSelection(provider: .chatGPT))
        let first = await ready(owner, effects: effects)
        owner.run(id: first, mode: mode, settings: settings, input: "")
        // Wait for the first adapter to suspend before superseding it.
        await fulfillment(of: [firstStarted], timeout: 2)
        let second = await ready(owner, effects: effects)
        owner.run(id: second, mode: mode, settings: settings, input: "")
        await fulfillment(of: [started], timeout: 2)
        let reviewed = expectation(description: "new run review")
        effects.review = { reviewed.fulfill() }
        await generator.complete("new", index: 1)
        await fulfillment(of: [reviewed], timeout: 2)
        let recordsBefore = effects.records
        let closesBefore = effects.closed
        await generator.complete("stale")
        for _ in 0..<20 { await Task.yield() }
        owner.deliver(id: first, action: .paste, text: "stale edit")
        XCTAssertEqual(effects.records, recordsBefore)
        XCTAssertEqual(effects.closed, closesBefore)
        XCTAssertTrue(effects.clipboard.isEmpty)
        XCTAssertEqual(effects.records.last?.outputText, "new")
        XCTAssertEqual(effects.records.first(where: { $0.id == first && $0.status == .cancelled })?.status, .cancelled)
        owner.cancel(restoreFocus: false)
    }

    func testReviewCopiesFinalEditOnceAndNeverPastes() async {
        let started = expectation(description: "run")
        let generator = Generator { started.fulfill() }
        let effects = Effects()
        let owner = make(generator, effects: effects)
        var pastes = 0
        var activations = 0
        let source = InteractionSource(canPasteBack: true, activate: { activations += 1; return true },
                                       isReadyForPaste: { true }, paste: { pastes += 1; return true })
        let id = await self.ready(owner, effects: effects, source: source)
        let mode = SableMode(name: "Fix", instruction: "fix")
        owner.run(id: id, mode: mode, settings: SableSettings(modes: [mode]), input: "")
        await fulfillment(of: [started], timeout: 2)
        let reviewed = expectation(description: "review")
        effects.review = { reviewed.fulfill() }
        await generator.complete("generated")
        await fulfillment(of: [reviewed], timeout: 2)
        XCTAssertTrue(effects.clipboard.isEmpty)
        XCTAssertTrue(effects.closed.isEmpty)
        owner.deliver(id: id, action: .copy, text: "final edited output")
        owner.deliver(id: id, action: .copy, text: "duplicate")
        XCTAssertEqual(effects.clipboard, ["final edited output"])
        XCTAssertEqual(effects.records.last?.outputText, "final edited output")
        XCTAssertEqual(effects.records.last?.status, .copied)
        XCTAssertEqual(effects.closed, [id])
        XCTAssertEqual(pastes, 0)
        XCTAssertEqual(activations, 1)
    }

    func testDiscardRetainsFinalEditWithoutClipboardWrite() async {
        let started = expectation(description: "run")
        let generator = Generator { started.fulfill() }
        let effects = Effects()
        let owner = make(generator, effects: effects)
        let id = await ready(owner, effects: effects)
        let mode = SableMode(name: "Fix", instruction: "fix")
        owner.run(id: id, mode: mode, settings: SableSettings(modes: [mode]), input: "")
        await fulfillment(of: [started], timeout: 2)
        let reviewed = expectation(description: "review")
        effects.review = { reviewed.fulfill() }
        await generator.complete("output")
        await fulfillment(of: [reviewed], timeout: 2)
        owner.deliver(id: id, action: .discard, text: "discarded edit")
        XCTAssertEqual(effects.records.last?.status, .discarded)
        XCTAssertEqual(effects.records.last?.outputText, "discarded edit")
        XCTAssertTrue(effects.clipboard.isEmpty)
        XCTAssertEqual(effects.closed, [id])
    }

    func testSupersedingFocusWaitPreventsPasteKey() async {
        let started = expectation(description: "run")
        let generator = Generator { started.fulfill() }
        let effects = Effects()
        let gate = Gate<Void>()
        let waiting = expectation(description: "focus wait")
        gate.waiting = { waiting.fulfill() }
        let owner = make(generator, effects: effects, pause: { await gate.wait() })
        var pastes = 0
        var focused = false
        let source = InteractionSource(canPasteBack: true, activate: { true }, isReadyForPaste: { focused },
                                       paste: { pastes += 1; return true })
        let id = await self.ready(owner, effects: effects, source: source)
        let mode = SableMode(name: "Fix", instruction: "fix")
        owner.run(id: id, mode: mode, settings: SableSettings(modes: [mode]), input: "")
        await fulfillment(of: [started], timeout: 2)
        let reviewed = expectation(description: "review")
        effects.review = { reviewed.fulfill() }
        await generator.complete("output")
        await fulfillment(of: [reviewed], timeout: 2)
        owner.deliver(id: id, action: .paste, text: "final")
        await fulfillment(of: [waiting], timeout: 2)
        let newID = await ready(owner, effects: effects)
        let records = effects.records
        focused = true
        gate.resume(())
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(pastes, 0)
        XCTAssertEqual(effects.clipboard, ["final"])
        XCTAssertEqual(effects.records, records)
        XCTAssertEqual(owner.interactionID, newID)
        owner.cancel(restoreFocus: false)
    }

    func testActivationFailureKeepsCopiedOutputAndReportsRecovery() async {
        await assertPasteOutcome(activation: false, ready: true, nativePaste: true, expectedStatus: .copied)
    }

    func testNativePermissionFailureKeepsCopiedOutput() async {
        await assertPasteOutcome(activation: true, ready: true, nativePaste: false, expectedStatus: .copied)
    }

    func testVerifiedTargetReceivesPasteAndHistoryMarksPasted() async {
        await assertPasteOutcome(activation: true, ready: true, nativePaste: true, expectedStatus: .pasted)
    }

    func testFocusWaitIsBoundedAndNeverPastesToUnreadyTarget() async {
        await assertPasteOutcome(activation: true, ready: false, nativePaste: true, expectedStatus: .copied)
    }

    func testFocusWaitRejectsChangedClipboardAndElapsedDeadline() async {
        for changedClipboard in [true, false] {
            let started = expectation(description: "run")
            let generator = Generator { started.fulfill() }
            let effects = Effects()
            var time: TimeInterval = 0
            var focused = false
            var keys = 0
            let owner = make(generator, effects: effects, uptime: { time }, pause: {
                if changedClipboard { effects.clipboardVersion += 1 }
                else { time = 1 }
                focused = true
            })
            let source = InteractionSource(canPasteBack: true, activate: { true }, isReadyForPaste: { focused },
                                           paste: { keys += 1; return true })
            let id = await self.ready(owner, effects: effects, source: source)
            let mode = SableMode(name: "Fix", instruction: "fix")
            owner.run(id: id, mode: mode, settings: SableSettings(modes: [mode]), input: "")
            await fulfillment(of: [started], timeout: 2)
            let reviewed = expectation(description: "review")
            effects.review = { reviewed.fulfill() }
            await generator.complete("output")
            await fulfillment(of: [reviewed], timeout: 2)
            let copied = expectation(description: "copied only")
            effects.copied = { copied.fulfill() }
            owner.deliver(id: id, action: .paste, text: "final")
            await fulfillment(of: [copied], timeout: 2)
            XCTAssertEqual(keys, 0)
            XCTAssertEqual(effects.records.last?.status, .copied)
            if changedClipboard { XCTAssertTrue(effects.records.last?.errorMessage?.contains("History") == true) }
        }
    }

    func testClipboardWriteFailurePreservesFinalEditAndNeverActivatesOrPastes() async {
        let started = expectation(description: "run")
        let generator = Generator { started.fulfill() }
        let effects = Effects()
        effects.acceptsClipboard = false
        let owner = make(generator, effects: effects)
        var activations = 0
        var pastes = 0
        let source = InteractionSource(canPasteBack: true, activate: { activations += 1; return true },
                                       isReadyForPaste: { true }, paste: { pastes += 1; return true })
        let id = await self.ready(owner, effects: effects, source: source)
        let mode = SableMode(name: "Fix", instruction: "fix")
        owner.run(id: id, mode: mode, settings: SableSettings(modes: [mode]), input: "")
        await fulfillment(of: [started], timeout: 2)
        let reviewed = expectation(description: "review")
        effects.review = { reviewed.fulfill() }
        await generator.complete("output")
        await fulfillment(of: [reviewed], timeout: 2)
        owner.deliver(id: id, action: .paste, text: "final edit")
        XCTAssertEqual(effects.records.last?.status, .failed)
        XCTAssertEqual(effects.records.last?.outputText, "final edit")
        XCTAssertTrue(effects.records.last?.errorMessage?.contains("History") == true)
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(pastes, 0)
        XCTAssertTrue(effects.clipboard.isEmpty)
    }

    private func assertPasteOutcome(activation: Bool, ready: Bool, nativePaste: Bool, expectedStatus: RunStatus) async {
        let started = expectation(description: "run")
        let generator = Generator { started.fulfill() }
        let effects = Effects()
        var polls = 0
        var keys = 0
        let owner = make(generator, effects: effects, pause: { polls += 1 })
        let source = InteractionSource(canPasteBack: true, activate: { activation }, isReadyForPaste: { ready },
                                       paste: { keys += 1; return nativePaste })
        let id = await self.ready(owner, effects: effects, source: source)
        let mode = SableMode(name: "Fix", instruction: "fix")
        owner.run(id: id, mode: mode, settings: SableSettings(modes: [mode]), input: "")
        await fulfillment(of: [started], timeout: 2)
        let reviewed = expectation(description: "review")
        effects.review = { reviewed.fulfill() }
        await generator.complete("output")
        await fulfillment(of: [reviewed], timeout: 2)
        let completed = expectation(description: "delivery")
        effects.copied = { completed.fulfill() }
        owner.deliver(id: id, action: .paste, text: "final")
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(effects.clipboard, ["final"])
        XCTAssertEqual(effects.records.last?.status, expectedStatus)
        XCTAssertEqual(effects.records.last?.outputText, "final")
        XCTAssertEqual(keys, activation && ready ? 1 : 0)
        XCTAssertEqual(polls, activation && !ready ? 10 : 0)
        if expectedStatus == .copied { XCTAssertTrue(effects.records.last?.errorMessage?.contains("⌘V") == true) }
    }

    func testDirectSkipsScreenshotsAndSnapshotsSettingsAndQuickCopy() async {
        let started = expectation(description: "run")
        let generator = Generator { started.fulfill() }
        let effects = Effects()
        let owner = make(generator, effects: effects)
        let id = await ready(owner, effects: effects)
        let mode = SableMode(name: "Direct", instruction: "fix", model: "sonnet")
        var settings = SableSettings(modes: [mode], generation: GenerationSelection(provider: .chatGPT, model: "account-model"),
                                     resultHandling: .quickCopy, attachesScreenshotsForCLI: true)
        owner.run(id: id, mode: mode, settings: settings, input: "")
        owner.run(id: id, mode: mode, settings: settings, input: "duplicate")
        settings.generation = GenerationSelection(provider: .openRouter, model: "other")
        settings.resultHandling = .review
        await fulfillment(of: [started], timeout: 2)
        let request = await generator.inputs()
        XCTAssertEqual(request.count, 1)
        XCTAssertEqual(request.first?.selection, GenerationSelection(provider: .chatGPT, model: "account-model"))
        XCTAssertNil(request.first?.cli)
        XCTAssertEqual(effects.screenshots, 0)
        let copied = expectation(description: "quick copied")
        effects.copied = { copied.fulfill() }
        await generator.complete("output")
        await fulfillment(of: [copied], timeout: 2)
        XCTAssertEqual(effects.clipboard, ["output"])
        XCTAssertEqual(effects.closed, [id])
        XCTAssertEqual(effects.records.last?.provider, .chatGPT)
        XCTAssertEqual(effects.records.last?.model, "account-model")
    }

    func testCLIScreenshotIsDeferredAndCleanedOnceOnCancel() async {
        let started = expectation(description: "run")
        let generator = Generator { started.fulfill() }
        let effects = Effects()
        let owner = make(generator, effects: effects)
        let id = await ready(owner, effects: effects)
        XCTAssertEqual(effects.screenshots, 0)
        let mode = SableMode(name: "CLI", instruction: "fix")
        owner.run(id: id, mode: mode, settings: SableSettings(modes: [mode], attachesScreenshotsForCLI: true), input: "")
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(effects.screenshots, 1)
        let request = await generator.inputs().first
        XCTAssertEqual(request?.cli?.screenshotPath, "/fake/screenshot")
        owner.cancel(restoreFocus: false)
        XCTAssertEqual(effects.cleaned, 1)
        XCTAssertEqual(effects.closed, [id])
        await generator.complete("late")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(effects.cleaned, 1)
        XCTAssertTrue(effects.clipboard.isEmpty)
        XCTAssertEqual(effects.records.last?.status, .cancelled)
    }

    func testIncompleteGenerationNeverCopiesOrMarksSuccess() async {
        let started = expectation(description: "run")
        let generator = Generator { started.fulfill() }
        let effects = Effects()
        let owner = make(generator, effects: effects)
        let id = await ready(owner, effects: effects)
        let mode = SableMode(name: "Fix", instruction: "fix")
        owner.run(id: id, mode: mode, settings: SableSettings(modes: [mode], resultHandling: .quickCopy), input: "")
        await fulfillment(of: [started], timeout: 2)
        let failed = expectation(description: "failure")
        owner.onEvent = { if case .failed = $0 { failed.fulfill() } }
        await generator.fail()
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(effects.records.last?.status, .failed)
        XCTAssertNil(effects.records.last?.outputText)
        XCTAssertTrue(effects.clipboard.isEmpty)
    }
}
