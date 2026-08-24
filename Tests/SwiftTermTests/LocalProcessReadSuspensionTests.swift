//
// Host-driven PTY read suspension (`LocalProcess.setReadSuspended`).
//
// The point of the feature is CPU, so the test asserts the thing that costs CPU: whether bytes are still
// being delivered to the delegate. It runs a real child process against a real pseudo-terminal, because the
// mechanism under test IS the PTY read chain — a mock would only assert that a boolean flips.
//
// Delivery uses the default main-queue path, which is the one a `LocalProcessTerminalView` host uses, so the
// test pumps the run loop instead of sleeping (sleeping on main would starve the very delivery it measures).
//
#if os(macOS)
import Foundation
import XCTest

@testable import SwiftTerm

final class LocalProcessReadSuspensionTests: XCTestCase {
    /// Counts bytes as they are delivered. `received` is only ever touched on the delivery queue (main).
    private final class Counter: LocalProcessDelegate {
        var received = 0
        var terminated = false
        func processTerminated(_ source: LocalProcess, exitCode: Int32?) { terminated = true }
        func dataReceived(slice: ArraySlice<UInt8>) { received += slice.count }
        func getWindowSize() -> winsize {
            winsize(ws_row: 24, ws_col: 80, ws_xpixel: 640, ws_ypixel: 480)
        }
    }

    /// Run the main run loop for `seconds`, so queued delivery actually happens.
    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// A child that emits steadily but slowly enough that the kernel PTY buffer is the backstop, not the
    /// 4 MB backlog high-water mark — otherwise backpressure, not the host, would be what stopped the reads.
    /// A child that saturates the read: `DispatchIO` completes a read op at `readSize` bytes, and completing
    /// it is what lets the park take effect. This is the shape of a real pane running a repainting TUI.
    private func startFlood(_ process: LocalProcess) {
        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "while :; do echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; done"],
            environment: nil)
    }

    private func startTrickle(_ process: LocalProcess) {
        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "while :; do echo tick; sleep 0.01; done"],
            environment: nil)
    }

    /// The contract under load — which is the only case that costs anything. Parking stops delivery and the
    /// read chain ends, so the child blocks in `write()` and a multiplexer upstream sees a stalled terminal.
    func testSuspendStopsDeliveryUnderLoadAndResumeRestartsIt() throws {
        let counter = Counter()
        let process = LocalProcess(delegate: counter)
        startFlood(process)
        defer { process.terminate() }

        pump(0.5)
        XCTAssertGreaterThan(counter.received, 0, "the child should be delivering before anything is parked")

        process.setReadSuspended(true)
        XCTAssertTrue(process.isReadSuspended)

        // Settle: the read op already in flight when the park lands still reports its bytes. What must stop is
        // everything after it, so the assertion compares two points past the settle.
        pump(0.5)
        let settled = counter.received
        pump(1.0)
        XCTAssertEqual(counter.received, settled, "a parked process must stop delivering")
        XCTAssertEqual(
            process.readChainDepthForTesting, 0,
            "the read chain must actually END — that is what makes the child block, rather than us buffering")

        process.setReadSuspended(false)
        XCTAssertFalse(process.isReadSuspended)
        pump(0.6)
        XCTAssertGreaterThan(counter.received, settled, "resuming must re-arm the chain, not leave it mute")
        XCTAssertEqual(process.readChainDepthForTesting, 1)
    }

    /// The documented limit, asserted so nobody "fixes" the CPU numbers by assuming parking is instantaneous.
    ///
    /// Parking takes effect when the in-flight read op completes, and a `DispatchIO` read op completes on
    /// `readSize` bytes (or EOF) — so a child that trickles keeps being delivered until it has produced that
    /// much. This is self-balancing rather than broken: the CPU parking saves is proportional to output, and
    /// so is how fast it engages. Ending the op sooner would mean tearing down and rebuilding the channel,
    /// which is fd-lifetime surgery for a case that by construction costs almost nothing.
    func testParkingATricklingChildIsNotImmediate() throws {
        let counter = Counter()
        let process = LocalProcess(delegate: counter)
        startTrickle(process)
        defer { process.terminate() }

        pump(0.5)
        process.setReadSuspended(true)
        pump(0.5)
        let settled = counter.received
        pump(1.0)
        XCTAssertGreaterThan(
            counter.received, settled,
            "documented: a trickling child keeps being delivered until its read op fills — if this ever stops "
                + "being true the parking mechanism changed, and the comment above is now wrong")
    }

    /// Park/unpark must not leave two read chains racing: the chain re-arms itself, so an extra `resume` that
    /// does not check for a live chain doubles it (and keeps doubling). A doubled chain still *works*, so the
    /// symptom is only CPU and memory — assert the invariant directly instead.
    func testRepeatedSuspendResumeKeepsExactlyOneReadChain() throws {
        let counter = Counter()
        let process = LocalProcess(delegate: counter)
        startTrickle(process)
        defer { process.terminate() }

        pump(0.4)
        for _ in 0..<5 {
            process.setReadSuspended(true)
            process.setReadSuspended(false)  // same turn: the in-flight op has not reported back yet
        }
        pump(0.5)
        XCTAssertEqual(process.readChainDepthForTesting, 1, "exactly one read op may be outstanding")

        // And it is still a working terminal after all that.
        let before = counter.received
        pump(0.5)
        XCTAssertGreaterThan(counter.received, before)
    }

    func testSuspendIsIdempotentAndResumeWithoutSuspendIsANoOp() throws {
        let counter = Counter()
        let process = LocalProcess(delegate: counter)
        startTrickle(process)
        defer { process.terminate() }

        pump(0.4)
        process.setReadSuspended(false)  // never suspended
        XCTAssertEqual(process.readChainDepthForTesting, 1)

        process.setReadSuspended(true)
        process.setReadSuspended(true)
        XCTAssertTrue(process.isReadSuspended)
        pump(0.5)

        process.setReadSuspended(false)
        pump(0.4)
        XCTAssertEqual(process.readChainDepthForTesting, 1)
    }
}
#endif
