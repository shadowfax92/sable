import XCTest
@testable import SableCore

@MainActor
final class SelectionCaptureLifecycleTests: XCTestCase {
    /// Models pasteboard ownership without allocating even a private NSPasteboard.
    private final class Board {
        var text: String? = "original"
        var count = 1
        var restorations = 0
        func write(_ text: String?) { self.text = text; count += 1 }
        func checkpoint() -> () -> Void {
            let saved = text
            return { self.write(saved); self.restorations += 1 }
        }
    }
    private final class Tick {
        var pending: CheckedContinuation<Void, Never>?
        var entered: (() -> Void)?
        func wait() async {
            await withCheckedContinuation { pending = $0; entered?() }
        }
        func resume() { let continuation = pending; pending = nil; continuation?.resume() }
    }
    private func make(_ board: Board, ax: @escaping () -> String? = { nil },
                      copy: @escaping () throws -> Void,
                      tick: @escaping () async -> Void = { await Task.yield() }) -> SelectionCapture {
        SelectionCapture(accessibilityText: ax, changeCount: { board.count }, clipboardText: { board.text },
                         snapshot: { board.checkpoint() }, copy: copy, tick: tick)
    }

    func testAXSelectionSkipsCopyAndSnapshot() async throws {
        let board = Board()
        var copies = 0
        let capture = make(board, ax: { "AX selection" }, copy: { copies += 1 })
        let result = try await capture.capture()
        XCTAssertEqual(result.text, "AX selection")
        XCTAssertEqual(copies, 0)
        XCTAssertEqual(board.count, 1)
        XCTAssertEqual(board.restorations, 0)
    }

    func testFallbackRestoresBeforeReturningToReview() async throws {
        let board = Board()
        let capture = make(board, copy: { board.write("selected") })
        let result = try await capture.capture()
        XCTAssertEqual(result.text, "selected")
        XCTAssertEqual(board.text, "original")
        XCTAssertEqual(board.restorations, 1)
        // Later user copies survive cancellation/discard: capture retains no
        // restoration lease after returning the selected text.
        board.write("user copy during review")
        XCTAssertEqual(board.text, "user copy during review")
    }

    func testFailedEmptyFallbackRestoresOriginal() async {
        let board = Board()
        let capture = make(board, copy: { board.write(nil) })
        do { _ = try await capture.capture(); XCTFail("expected no selection") }
        catch { XCTAssertEqual(error as? SableError, .noSelectedText) }
        XCTAssertEqual(board.text, "original")
        XCTAssertEqual(board.restorations, 1)
    }

    func testThrowingFallbackRestoresItsOwnWrite() async {
        let board = Board()
        let capture = make(board, copy: { board.write("partial copy"); throw SableError.noSelectedText })
        do { _ = try await capture.capture(); XCTFail("expected copy failure") }
        catch { XCTAssertEqual(error as? SableError, .noSelectedText) }
        XCTAssertEqual(board.text, "original")
        XCTAssertEqual(board.restorations, 1)
    }

    func testCanceledFallbackDrainsLateCopyAndRestores() async {
        let board = Board()
        let tick = Tick()
        let waiting = expectation(description: "copy posted, waiting")
        tick.entered = { waiting.fulfill() }
        let capture = make(board, copy: {}, tick: { await tick.wait() })
        let task = Task { try await capture.capture() }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        // The native source may service the already-posted key after cancel.
        board.write("late native copy")
        tick.resume()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(board.text, "original")
        XCTAssertEqual(board.restorations, 1)
    }

    func testCancelPreservesNewerUserCopy() async {
        let board = Board()
        let tick = Tick()
        let waiting = expectation(description: "copy posted")
        tick.entered = { waiting.fulfill() }
        let capture = make(board, copy: { board.write("selected") }, tick: { await tick.wait() })
        let task = Task { try await capture.capture() }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        board.write("new user clipboard")
        tick.resume()
        _ = await task.result
        XCTAssertEqual(board.text, "new user clipboard")
        XCTAssertEqual(board.restorations, 0)
    }

    func testQueuedCaptureNeverSnapshotsCanceledCaptureClipboard() async throws {
        let board = Board()
        let tick = Tick()
        let firstWaiting = expectation(description: "first copy posted")
        tick.entered = { firstWaiting.fulfill() }
        var copies = 0
        let capture = make(board, copy: { copies += 1; board.write("selection \(copies)") }, tick: { await tick.wait() })
        let first = Task { try await capture.capture() }
        await fulfillment(of: [firstWaiting], timeout: 2)
        first.cancel()
        let second = Task { try await capture.capture() }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(copies, 1)
        let secondWaiting = expectation(description: "second copy posted after restore")
        tick.entered = { secondWaiting.fulfill() }
        tick.resume()
        _ = await first.result
        await fulfillment(of: [secondWaiting], timeout: 2)
        tick.resume()
        let result = try await second.value
        XCTAssertEqual(result.text, "selection 2")
        XCTAssertEqual(board.text, "original")
        XCTAssertEqual(board.restorations, 2)
    }

    func testChangedSourcePreventsGlobalCopy() async {
        let board = Board()
        var copies = 0
        let capture = make(board, copy: { copies += 1 })
        do { _ = try await capture.capture(isSourceCurrent: { false }); XCTFail("expected no selection") }
        catch { XCTAssertEqual(error as? SableError, .noSelectedText) }
        XCTAssertEqual(copies, 0)
        XCTAssertEqual(board.text, "original")
    }
}
