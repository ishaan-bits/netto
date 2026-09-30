import XCTest

/// TEMPORARY Milestone 4B end-to-end scan-validation harness — runs the real Dashboard flow
/// against the simulator's real photo library and records what the pipeline actually did.
///
/// Evidence it produces (attached + printed as `VALIDATE-*` lines for the runner log):
/// - timestamped samples of the scan card's copy, so progress monotonicity and the
///   fingerprinting 0-of-N regression are checked against real UI output, not unit tests;
/// - terminal state of every run (finished / cancelled / failed);
/// - cancellation and restart behaviour, including that counters restart fresh.
///
/// With `NETTO_SCAN_METRICS=1` (set below) the app also emits signposts and one
/// `analysis-summary` os_log line per run — collected by the runner's `log stream`.
final class ScanValidationUITests: XCTestCase {
    private var app: XCUIApplication!

    private let start = Date()
    private var pendingSamples: [Sample] = []

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: States parsed from the scan card

    private enum ScanState: Equatable {
        case reading(Int, Int)
        case candidates
        case fingerprinting(Int, Int)
        case analyzing(Int, Int)
        case comparing(Int, Int)
        case grouping
        case finalizing
        case finished(analyzed: Int, total: Int)
        case failed(String)
        case cancelled
        case emptyLibrary
        case permissionRequired
        case idle
        case scanningOther(String)
        case unknown(String)

        var stageName: String {
            switch self {
            case .reading: return "reading"
            case .candidates: return "candidates"
            case .fingerprinting: return "fingerprinting"
            case .analyzing: return "analyzing"
            case .comparing: return "comparing"
            case .grouping: return "grouping"
            case .finalizing: return "finalizing"
            case .finished: return "finished"
            case .failed: return "failed"
            case .cancelled: return "cancelled"
            case .emptyLibrary: return "emptyLibrary"
            case .permissionRequired: return "permissionRequired"
            case .idle: return "idle"
            case .scanningOther: return "scanningOther"
            case .unknown: return "unknown"
            }
        }

        var isTerminal: Bool {
            switch self {
            case .finished, .failed, .cancelled, .emptyLibrary: return true
            default: return false
            }
        }
    }

    private struct Sample {
        let offset: TimeInterval
        let state: ScanState
        let raw: String
    }

    // MARK: Test 1 — cancel mid-scan, then a second run must work

    func testCancelStopsScanAndSecondRunWorks() {
        launch()
        wait(identifier: "scanStatusCard", timeout: 60)
        settle()

        let t0 = Date()
        startScan()

        // Wait for real fingerprinting progress — the original failure point.
        let progressed = waitFor(
            deadline: t0.addingTimeInterval(12 * 60),
            description: "fingerprinting never progressed past 0 in run 1"
        ) { state in
            if case .fingerprinting(let x, _) = state, x > 0 { return true }
            return false
        }
        let run1 = drainSamples()
        XCTAssertTrue(progressed, "run 1 never showed Fingerprinting x>0\n\(summary(of: run1))")

        // Cancel during active work.
        let cancel = element("cancelAnalysisButton")
        reveal(cancel)
        XCTAssertTrue(cancel.waitForExistence(timeout: 20), "no cancel button while scanning")
        XCTAssertTrue(cancel.isHittable, "cancel not hittable: \(cancel.frame)")
        let tCancel = Date()
        cancel.tap()

        let cancelled = waitFor(
            deadline: tCancel.addingTimeInterval(60),
            description: "scan did not reach the cancelled state"
        ) { state in
            state == .cancelled
        }
        let run1Tail = drainSamples()
        XCTAssertTrue(cancelled, "cancel did not reach a terminal cancelled state\n\(summary(of: run1Tail))")
        XCTAssertTrue(
            element("analyzeLibraryButton").waitForExistence(timeout: 30),
            "card did not return to a startable state after cancel"
        )
        print("VALIDATE cancel latency: \(String(format: "%.1f", Date().timeIntervalSince(tCancel)))s")

        // Second run: must start, report fresh counters, and progress again.
        let t1 = Date()
        startScan()
        let restarted = waitFor(
            deadline: t1.addingTimeInterval(10 * 60),
            description: "second run never showed a fresh catalog/fingerprinting state"
        ) { state in
            switch state {
            case .reading(let x, _): return x < 40_000
            case .fingerprinting: return true // catalog demonstrably restarted and passed
            default: return false
            }
        }
        XCTAssertTrue(restarted, "second run did not show a fresh Reading x of N counter")

        let progressedAgain = waitFor(
            deadline: t1.addingTimeInterval(15 * 60),
            description: "second run never reached fingerprinting progress"
        ) { state in
            if case .fingerprinting(let x, _) = state, x > 0 { return true }
            return false
        }
        let run2 = drainSamples()
        XCTAssertTrue(progressedAgain, "second run stalled\n\(summary(of: run2))")

        // Leave the app clean: cancel run 2.
        let cancel2 = element("cancelAnalysisButton")
        reveal(cancel2)
        if cancel2.waitForExistence(timeout: 15), cancel2.isHittable {
            cancel2.tap()
        }
        _ = waitFor(
            deadline: Date().addingTimeInterval(60),
            description: "second cancel did not settle"
        ) { state in
            state == .cancelled
        }
        let run2Tail = drainSamples()

        // Monotonicity is judged per run — run 2 legitimately restarts its counters.
        assertMonotonic(run1 + run1Tail, label: "run1")
        assertMonotonic(run2 + run2Tail, label: "run2")
        attach(summary(of: run1 + run1Tail + run2 + run2Tail), name: "cancel-restart-samples")
    }

    // MARK: Test 2 — full pipeline to a terminal state on the real library

    func testFullScanReachesTerminalStateWithRealProgress() {
        launch()
        wait(identifier: "scanStatusCard", timeout: 60)
        settle()

        let t0 = Date()
        print("VALIDATE full-scan start epoch=\(t0.timeIntervalSince1970)")
        startScan()

        let deadline = t0.addingTimeInterval(50 * 60)
        var terminal: ScanState?
        var probedResponsiveness = false

        while Date() < deadline {
            let state = readState()
            if case .fingerprinting(let x, _) = state, x > 0, !probedResponsiveness {
                probedResponsiveness = true
                app.swipeUp() // interactivity probe: the UI must still take input
                app.swipeDown()
                reveal(element("scanStatusCard"))
                XCTAssertTrue(
                    element("scanStatusCard").exists,
                    "scan card lost after mid-scan interaction"
                )
            }
            if state.isTerminal {
                terminal = state
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        let samples = drainSamples()
        attach(summary(of: samples), name: "full-scan-samples")
        guard let terminal else {
            XCTFail("scan never reached a terminal state within the deadline\n\(summary(of: samples))")
            return
        }
        print("VALIDATE full-scan terminal: \(compact(terminal)) after \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")

        guard case .finished(let analyzed, let total) = terminal else {
            XCTFail("terminal state was not success: \(compact(terminal))\n\(summary(of: samples))")
            return
        }
        XCTAssertGreaterThan(total, 40_000, "expected the ~41k dataset, catalog saw \(total) assets")
        XCTAssertGreaterThan(analyzed, 0, "nothing was analyzed")
        XCTAssertLessThanOrEqual(analyzed, total, "analyzed \(analyzed) exceeds total \(total)")

        let names = samples.map { $0.state.stageName }

        // Progress requirements across the run.
        let fingerprintSamples = samples.filter {
            if case .fingerprinting = $0.state { return true }
            return false
        }
        XCTAssertFalse(fingerprintSamples.isEmpty, "fingerprinting stage never appeared in the UI")
        XCTAssertTrue(
            fingerprintSamples.contains {
                if case .fingerprinting(let x, _) = $0.state, x > 0 { return true }
                return false
            },
            "fingerprinting never advanced past 0 — original failure reproduced"
        )
        XCTAssertTrue(
            fingerprintSamples.contains {
                if case .fingerprinting(let x, let y) = $0.state, y > 0, x >= y { return true }
                return false
            }
                // The terminal tick can fall between two 0.5 s samples; reaching any later
                // stage after fingerprinting samples were seen proves it ran to completion.
                || names.contains("analyzing")
                || names.contains("comparing")
                || names.contains("grouping")
                || names.contains("finalizing")
                || names.contains("finished"),
            "fingerprinting never completed"
        )
        assertMonotonic(samples, label: "full-scan")

        // Stage coverage: extraction/compare ran. The catalog read itself can complete
        // between two samples (it took ~1s once warm), so fingerprinting on the same
        // scan — which cannot start before the catalog finished — is an equivalent proof.
        XCTAssertTrue(
            names.contains("reading") || names.contains("fingerprinting"),
            "catalog reading never shown"
        )
        XCTAssertTrue(
            names.contains("analyzing") || names.contains("comparing"),
            "no extraction/compare progress shown"
        )

        // Result reached the dashboard: the Similar Photos card must carry group counts.
        scrollToGrid()
        let card = element("similarPhotosCard")
        let cardText = card.exists ? labelTree(of: card) : ""
        print("VALIDATE similar-photos card: \(cardText)")
        attach("similar photos card: \(cardText)", name: "results-card")
        XCTAssertTrue(
            cardText.lowercased().contains("ready to review")
                || cardText.lowercased().contains("no duplicates")
                || cardText.lowercased().contains("not analyzed"),
            "results did not reach the dashboard card: \(cardText)"
        )

        // And the Similar Photos flow must open with the results.
        XCTAssertTrue(card.isHittable, "similar photos card not hittable: \(card.frame)")
        card.tap()
        let similarLoaded = app.navigationBars["Similar Photos"].waitForExistence(timeout: 30)
            || app.staticTexts.matching(
                NSPredicate(format: "label == %@", "Similar Photos")
            ).firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(similarLoaded, "Similar Photos flow did not open")
        print(
            "VALIDATE full-scan total: \(String(format: "%.1f", Date().timeIntervalSince(t0)))s "
                + "analyzed=\(analyzed) total=\(total)"
        )
    }

    // MARK: Flow helpers

    private func launch() {
        app = XCUIApplication()
        app.launchEnvironment["NETTO_SCAN_METRICS"] = "1"
        app.launch()
    }

    private func startScan() {
        let analyze = element("analyzeLibraryButton")
        reveal(analyze)
        XCTAssertTrue(analyze.waitForExistence(timeout: 30), "analyze button not found")
        XCTAssertTrue(analyze.isHittable, "analyze button not hittable: \(analyze.frame)")
        analyze.tap()
        XCTAssertTrue(
            element("cancelAnalysisButton").waitForExistence(timeout: 45),
            "scan never entered the scanning state"
        )
    }

    /// Reads the card, records a timestamped sample, prints it for the runner log.
    private func readState() -> ScanState {
        let card = element("scanStatusCard")
        guard card.exists else {
            let state = ScanState.unknown("card missing")
            record(state, raw: "card missing")
            return state
        }
        let raw = labelTree(of: card)
        let state = parse(raw)
        record(state, raw: raw)
        return state
    }

    private func record(_ state: ScanState, raw: String) {
        let sample = Sample(offset: Date().timeIntervalSince(start), state: state, raw: raw)
        pendingSamples.append(sample)
        print("VALIDATE-SAMPLE +\(String(format: "%.1f", sample.offset))s \(state.stageName) :: \(compact(state))")
    }

    private func drainSamples() -> [Sample] {
        let drained = pendingSamples
        pendingSamples = []
        return drained
    }

    /// Everything the card says, flattened: the header combines title + body into one label.
    private func labelTree(of element: XCUIElement) -> String {
        var parts: [String] = []
        if !element.label.isEmpty { parts.append(element.label) }
        for t in element.staticTexts.allElementsBoundByAccessibilityElement where t.exists {
            if !t.label.isEmpty { parts.append(t.label) }
        }
        for b in element.buttons.allElementsBoundByAccessibilityElement where b.exists {
            if !b.label.isEmpty { parts.append(b.label) }
        }
        return parts.joined(separator: " | ")
    }

    private func parse(_ text: String) -> ScanState {
        if text.contains("Last scan finished") {
            let nums = capture(pattern: #"(\d+) of (\d+) items analyzed"#, in: text)
            return .finished(analyzed: nums?.first ?? -1, total: nums?.last ?? -1)
        }
        if text.contains("Scan couldn't finish") { return .failed(text) }
        if text.contains("Scan cancelled") { return .cancelled }
        if text.contains("No photos visible") { return .emptyLibrary }
        if text.contains("Photos access needed") { return .permissionRequired }
        if text.contains("Ready when you are") { return .idle }

        if let m = capture(pattern: #"Reading (\d+) of (\d+) assets"#, in: text) {
            return .reading(m[0], m[1])
        }
        if let m = capture(pattern: #"Fingerprinting (\d+) of (\d+)"#, in: text) {
            return .fingerprinting(m[0], m[1])
        }
        if let m = capture(pattern: #"Analyzing (\d+) of (\d+) images"#, in: text) {
            return .analyzing(m[0], m[1])
        }
        if let m = capture(pattern: #"Comparing (\d+) of (\d+) groups"#, in: text) {
            return .comparing(m[0], m[1])
        }
        if text.contains("Finding candidate groups") { return .candidates }
        if text.contains("Grouping matches") { return .grouping }
        if text.contains("Finalizing") { return .finalizing }
        if text.contains("Scanning your library") || text.contains("Preparing") {
            return .scanningOther(text)
        }
        return .unknown(text)
    }

    private func capture(pattern: String, in text: String) -> [Int]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        var values: [Int] = []
        for index in 1..<match.numberOfRanges {
            let r = match.range(at: index)
            guard r.location != NSNotFound,
                  let swiftRange = Range(r, in: text),
                  let value = Int(text[swiftRange]) else { return nil }
            values.append(value)
        }
        return values
    }

    /// Polls until `condition` sees the awaited state (or the scan fails outright).
    private func waitFor(
        deadline: Date,
        description: String,
        _ condition: (ScanState) -> Bool
    ) -> Bool {
        while Date() < deadline {
            let state = readState()
            if condition(state) { return true }
            if case .failed(let message) = state {
                XCTFail("scan failed while waiting: \(message)")
                return false
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail(description)
        return false
    }

    // MARK: Assertions

    /// Counters may only move forward *within* one run; call per run.
    private func assertMonotonic(_ samples: [Sample], label: String) {
        var last: [String: Int] = [:]
        for sample in samples {
            let pair: (name: String, value: Int)?
            switch sample.state {
            case .reading(let x, _): pair = ("reading", x)
            case .fingerprinting(let x, _): pair = ("fingerprinting", x)
            case .analyzing(let x, _): pair = ("analyzing", x)
            case .comparing(let x, _): pair = ("comparing", x)
            default: pair = nil
            }
            guard let (name, value) = pair else { continue }
            if let previous = last[name] {
                XCTAssertGreaterThanOrEqual(
                    value, previous,
                    "\(label): \(name) went backwards: \(value) after \(previous) at +\(sample.offset)s"
                )
            }
            last[name] = value
        }
    }

    private func compact(_ state: ScanState) -> String {
        switch state {
        case .reading(let x, let y): return "Reading \(x) of \(y)"
        case .fingerprinting(let x, let y): return "Fingerprinting \(x) of \(y)"
        case .analyzing(let x, let y): return "Analyzing \(x) of \(y)"
        case .comparing(let x, let y): return "Comparing \(x) of \(y)"
        case .finished(let a, let t): return "Finished analyzed=\(a) total=\(t)"
        case .failed(let m): return "Failed: \(m)"
        case .scanningOther(let raw): return "Scanning: \(raw)"
        case .unknown(let raw): return "Unknown: \(raw)"
        default: return state.stageName
        }
    }

    private func summary(of samples: [Sample]) -> String {
        var lines = "samples: \(samples.count)\n"
        for s in samples {
            lines += "+\(String(format: "%.1f", s.offset))s \(s.state.stageName): \(s.raw)\n"
        }
        return lines
    }

    // MARK: Element helpers

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", id)
        ).firstMatch
    }

    private func reveal(_ target: XCUIElement, maxSwipes: Int = 6) {
        var swipes = 0
        while swipes < maxSwipes, target.exists, !target.isHittable {
            let frame = target.frame
            let screen = app.windows.firstMatch.frame
            if frame.minY >= screen.maxY - 8 {
                app.swipeUp()
            } else if frame.maxY <= screen.minY + 8 {
                app.swipeDown()
            } else {
                break
            }
            swipes += 1
        }
    }

    private func settle() {
        Thread.sleep(forTimeInterval: 1.6)
    }

    private func wait(identifier: String, timeout: TimeInterval = 20) -> XCUIElement {
        let e = element(identifier)
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "missing id: \(identifier)")
        return e
    }

    private func scrollToGrid(maxSwipes: Int = 8) {
        let title = element("cleanupSectionTitle")
        var swipes = 0
        while swipes < maxSwipes, !title.exists {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(title.waitForExistence(timeout: 20), "could not scroll to the cleanup grid")
    }

    private func attach(_ text: String, name: String) {
        let attachment = XCTAttachment(data: Data(text.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
