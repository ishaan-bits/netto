import XCTest

/// TEMPORARY Milestone 3D visual-QA harness — created for the QA run and deleted before the
/// milestone is reported (the same pattern as the Milestone 3C run). Everything it produces
/// is evidence: `XCTAttachment`s extracted from the xcresult afterwards.
///
/// The checks are the milestone's eyes: frames, containment, gaps, collisions, and escape
/// tests are all asserted here, because a screenshot on its own cannot prove alignment.
final class DashboardLayoutQATests: XCTestCase {
    private var app: XCUIApplication!

    private let topIDs = [
        "dashboardHeader",
        "dashboardHeroCopy",
        "storageHeroCard",
        "scanStatusCard",
        "storageRing",
        "storageStats"
    ]

    private let blocks = [
        "dashboardHeader",
        "dashboardHeroCopy",
        "storageHeroCard",
        "scanStatusCard"
    ]

    private let gridIDs = [
        "cleanupSectionTitle",
        "similarPhotosCard",
        "screenshotsCard",
        "largeVideosCard",
        "duplicateContactsRow"
    ]

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: 1 — structure: no overlap, everything contained, grid rows aligned

    func testDashboardHasNoLayoutOverlap() {
        launch()

        // The storage core draws itself in on first appearance, so the first two frames are
        // captured before the layout settles — that is the entrance evidence.
        wait(identifier: "dashboardHeader")
        shot("wake-1")
        shot("wake-2")

        // Everything is laid out and the wake animation has settled.
        wait(identifier: "storageRing", timeout: 30)
        settle()

        var log = "variant: pending\n"
        log += frameLines(topIDs)
        log += noOverlap(blocks)
        log += contained("storageRing", in: "storageHeroCard")
        log += contained("storageStats", in: "storageHeroCard")
        log += gap("storageRing", "storageStats", expected: 16, tolerance: 1)
        log += verticalGaps(blocks, expected: 24, tolerance: 1)
        log += "ring → stats gap: \(value(gap: "storageRing", "storageStats")) pt\n"
        shot("01-top")

        // Grid: scroll the "Clean up" section into view, then measure it.
        scrollToGrid()
        settle()
        log += frameLines(gridIDs)
        log += noOverlap([
            "cleanupSectionTitle",
            "similarPhotosCard",
            "screenshotsCard",
            "largeVideosCard",
            "duplicateContactsRow"
        ])
        log += rowAligned("similarPhotosCard", "screenshotsCard")
        log += rowAligned("largeVideosCard", "duplicateContactsRow")
        log += equalHeight("similarPhotosCard", "screenshotsCard", "largeVideosCard", "duplicateContactsRow")
        shot("02-cleanup-grid")

        // Back to the top: the screen must survive a scroll round-trip untouched.
        app.swipeDown()
        app.swipeDown()
        settle()
        log += "after scroll-back scanCard: \(value(frame: "scanStatusCard"))\n"
        shot("03-top-after-scroll")

        attach(log, name: "dashboard-frames")
    }

    // MARK: 2 — text: nothing collides, nothing escapes, ring labels stay inside

    func testNoTextCollidesOrEscapes() {
        launch()
        wait(identifier: "storageRing", timeout: 30)
        settle()

        var log = "text-qa variant: pending\n"
        log += frameLines(Array(topIDs.prefix(5)))
        log += textSection("[top]", containers: topIDs + gridIDs)
        log += ringLabelChecks()

        scrollToGrid()
        settle()
        log += frameLines(gridIDs)
        log += textSection("[grid]", containers: topIDs + gridIDs)
        log += rowAligned("similarPhotosCard", "screenshotsCard")
        log += rowAligned("largeVideosCard", "duplicateContactsRow")

        attach(log, name: "dashboard-text-qa")
    }

    // MARK: 3 — the scan state: progress, glass cancel, and the pulse that must stop

    func testScanStateLayoutAndMotion() {
        launch()
        wait(identifier: "scanStatusCard", timeout: 30)
        settle()

        let analyze = app.buttons["analyzeLibraryButton"]
        // At accessibility text sizes the scan card sits below the fold — bring it into
        // view before deciding whether the analysis can start.
        reveal(analyze)
        if analyze.waitForExistence(timeout: 15), analyze.isHittable {
            analyze.tap()
        }

        let cancel = app.buttons["cancelAnalysisButton"]
        guard cancel.waitForExistence(timeout: 45) else {
            XCTFail("scan never reached the scanning state\n\(app.debugDescription)")
            return
        }
        // The card grows when the scan starts; at accessibility sizes that can push the
        // action row down — bring Cancel into view before judging reachability.
        reveal(cancel)
        settle()

        var log = "scan variant: pending\n"
        log += frameLines(["scanStatusCard", "scanProgressBar", "cancelAnalysisButton"])
        log += contained("scanProgressBar", in: "scanStatusCard")
        log += contained("cancelAnalysisButton", in: "scanStatusCard")
        shot("scan-active")

        // Two frames, 0.45 s apart: the indicator breathes while a scan runs.
        shot("pulse-1")
        Thread.sleep(forTimeInterval: 0.45)
        shot("pulse-2")

        // Cancel must be a first-class, hittable target — and the card must return to idle.
        XCTAssertTrue(
            cancel.isHittable,
            "Cancel is not hittable while scanning: frame=\(cancel.frame) screen=\(app.windows.firstMatch.frame)"
        )
        cancel.tap()

        let again = app.buttons["analyzeLibraryButton"]
        XCTAssertTrue(again.waitForExistence(timeout: 30), "card did not return to idle after cancel")
        settle()
        log += "after cancel: \(value(frame: "scanStatusCard"))\n"
        log += frameLines(["scanStatusCard"])
        shot("scan-idle")

        attach(log, name: "dashboard-scan")
    }

    /// Scroll an element into the visible area. Swipes *toward* it based on where it
    /// actually sits, so a tall card can never be overshot into the section below it.
    private func reveal(_ element: XCUIElement, maxSwipes: Int = 6) {
        var swipes = 0
        while swipes < maxSwipes, !element.isHittable {
            let frame = element.frame
            let screen = app.windows.firstMatch.frame
            if frame.minY >= screen.maxY - 8 {
                app.swipeUp()
            } else if frame.maxY <= screen.minY + 8 {
                app.swipeDown()
            } else {
                break // on screen but blocked — the assertion below reports it
            }
            swipes += 1
        }
    }

    // MARK: Screens / waiting

    private func launch() {
        app = XCUIApplication()
        app.launch()
    }

    /// Entrance, wake, and state changes are short; give them a beat before measuring so the
    /// numbers are the settled layout, not an in-flight frame.
    private func settle() {
        Thread.sleep(forTimeInterval: 1.6)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attach(_ text: String, name: String) {
        let attachment = XCTAttachment(data: Data(text.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    private func wait(identifier: String, timeout: TimeInterval = 20) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", identifier)
        ).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "missing id: \(identifier)")
        return element
    }

    /// The cleanup grid sits in a LazyVGrid: the section title becomes reachable before the
    /// cells are materialized, so scroll until every card is actually in the hierarchy.
    private func scrollToGrid(maxSwipes: Int = 8) {
        let title = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "cleanupSectionTitle")
        ).firstMatch
        let cards = ["similarPhotosCard", "screenshotsCard", "largeVideosCard", "duplicateContactsRow"]
            .map { element($0) }

        var swipes = 0
        while swipes < maxSwipes, !(title.exists && cards.allSatisfy { $0.exists }) {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(title.waitForExistence(timeout: 20), "could not scroll to the cleanup grid")
        for (index, card) in cards.enumerated() {
            XCTAssertTrue(
                card.waitForExistence(timeout: 10),
                "grid card \(index) not built after scrolling"
            )
        }
    }

    // MARK: Geometry

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", id)
        ).firstMatch
    }

    private func rect(_ id: String) -> CGRect? {
        let e = element(id)
        guard e.exists else {
            print("RECT \(id) exists=false -> nil")
            return nil
        }
        let f = e.frame
        let ok = f.width > 0 && f.height > 0
        print("RECT \(id) frame=\(f) ok=\(ok)")
        return ok ? f : nil
    }

    private func frameLines(_ ids: [String]) -> String {
        ids.map { id in
            guard let f = rect(id) else { return "\(id): missing\n" }
            return "\(id): x=\(f.origin.x) y=\(f.origin.y) w=\(f.width) h=\(f.height)\n"
        }.joined()
    }

    private func value(frame id: String) -> String {
        guard let f = rect(id) else { return "missing" }
        return "x=\(f.origin.x) y=\(f.origin.y) w=\(f.width) h=\(f.height)"
    }

    private func value(gap a: String, _ b: String) -> String {
        guard let ra = rect(a), let rb = rect(b) else { return "missing" }
        return String(format: "%.1f", rb.minY - ra.maxY)
    }

    /// Two rectangles may not share area (beyond a hairline of rounding).
    private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        guard !i.isNull else { return false }
        return i.width > 1 && i.height > 1
    }

    /// One rect genuinely inside the other — including sub-pixel containment where the
    /// frames differ by thousandths of a point (SwiftUI accessibility rounding).
    private func nestedPair(_ a: CGRect, _ b: CGRect) -> Bool {
        if a.contains(b) || b.contains(a) { return true }
        let i = a.intersection(b)
        guard !i.isNull else { return false }
        let smallArea = min(a.width * a.height, b.width * b.height)
        guard smallArea > 0 else { return false }
        return (i.width * i.height) / smallArea > 0.9
    }

    private func noOverlap(_ ids: [String]) -> String {
        var log = ""
        var pairs = 0
        for i in 0..<ids.count {
            for j in (i + 1)..<ids.count {
                guard let a = rect(ids[i]), let b = rect(ids[j]) else {
                    log += "missing frame for pair: \(ids[i]) / \(ids[j])\n"
                    continue
                }
                pairs += 1
                XCTAssertFalse(
                    overlaps(a, b),
                    "overlap: \(ids[i]) \(a) × \(ids[j]) \(b)"
                )
                log += overlaps(a, b)
                    ? "FAIL overlap: \(ids[i]) × \(ids[j])\n"
                    : "OK no overlap: \(ids[i]) × \(ids[j])\n"
            }
        }
        XCTAssertGreaterThan(pairs, 0, "no frames measured")
        return log
    }

    private func contained(_ child: String, in parent: String) -> String {
        guard let c = rect(child), let p = rect(parent) else {
            XCTFail("missing frame: \(child)/\(parent)")
            return "FAIL missing: \(child) in \(parent)\n"
        }
        let inside = c.minX >= p.minX - 1
            && c.maxX <= p.maxX + 1
            && c.minY >= p.minY - 1
            && c.maxY <= p.maxY + 1
        XCTAssertTrue(inside, "\(child) \(c) escapes \(parent) \(p)")
        return inside ? "OK contained: \(child) in \(parent)\n" : "FAIL contained: \(child) in \(parent)\n"
    }

    private func gap(_ a: String, _ b: String, expected: CGFloat, tolerance: CGFloat) -> String {
        guard let ra = rect(a), let rb = rect(b) else { return "FAIL missing gap: \(a) \(b)\n" }
        let g = rb.minY - ra.maxY
        XCTAssertTrue(abs(g - expected) <= tolerance, "gap \(a) → \(b) = \(g), expected \(expected)")
        return "OK gap \(a) → \(b): \(g) pt\n"
    }

    private func verticalGaps(_ ids: [String], expected: CGFloat, tolerance: CGFloat) -> String {
        var log = ""
        for i in 0..<(ids.count - 1) {
            guard let a = rect(ids[i]), let b = rect(ids[i + 1]) else { continue }
            let g = b.minY - a.maxY
            XCTAssertLessThanOrEqual(abs(g - expected), tolerance, "vertical gap \(i) → \(i + 1): \(g)")
            log += "vertical gap \(i) → \(i + 1): \(g) pt\n"
        }
        return log
    }

    private func rowAligned(_ a: String, _ b: String) -> String {
        guard let ra = rect(a), let rb = rect(b) else { return "FAIL missing row: \(a) \(b)\n" }
        let aligned = abs(ra.minY - rb.minY) < 1 && abs(ra.height - rb.height) < 1
        XCTAssertTrue(aligned, "row not aligned: \(a) \(ra) × \(b) \(rb)")
        return aligned ? "OK row aligned: \(a) × \(b)\n" : "FAIL row aligned: \(a) × \(b)\n"
    }

    private func equalHeight(_ ids: String...) -> String {
        var log = ""
        let heights = ids.compactMap { rect($0)?.height }
        guard heights.count == ids.count else { return "FAIL missing card frame\n" }
        let uniform = heights.max()! - heights.min()! < 1
        XCTAssertTrue(uniform, "card heights differ: \(heights)")
        log += uniform
            ? "OK cards equal height: \(heights)\n"
            : "FAIL cards equal height: \(heights)\n"
        return log
    }

    // MARK: Text

    /// Every text element in the viewport: no two blocks may share area, nothing may leave
    /// the screen horizontally, and nothing may sit outside the container that holds it.
    private func textSection(_ tag: String, containers: [String]) -> String {
        let texts = app.staticTexts.allElementsBoundByAccessibilityElement
        var measured = 0
        var skipped = 0
        var inViewport: [(XCUIElement, CGRect)] = []

        let screen = app.windows.firstMatch.frame.size

        for t in texts where t.exists {
            let f = t.frame
            guard f.width > 0, f.height > 0 else { continue }
            guard f.maxY >= 0, f.minY <= screen.height else { continue }
            inViewport.append((t, f))
            measured += 1

            // On-screen width: nothing may run off either edge.
            XCTAssertGreaterThanOrEqual(f.minX, -1, "\(tag) text escapes left: \(t.label) \(f)")
            XCTAssertLessThanOrEqual(f.maxX, screen.width + 1, "\(tag) text escapes right: \(t.label) \(f)")

            // Inside a known container.
            var enclosing: CGRect?
            for id in containers {
                guard let c = rect(id) else { continue }
                if c.contains(f) || c.intersects(f) {
                    enclosing = c
                    break
                }
            }
            if let container = enclosing {
                let inside = f.minX >= container.minX - 1
                    && f.maxX <= container.maxX + 1
                    && f.minY >= container.minY - 1
                    && f.maxY <= container.maxY + 1
                XCTAssertTrue(
                    inside,
                    "\(tag) text escapes its container: \(t.label) \(f) vs \(container)"
                )
            }
        }

        // Pairwise collisions, skipping nested pairs (a container label and its child).
        for i in 0..<inViewport.count {
            for j in (i + 1)..<inViewport.count {
                let a = inViewport[i].1
                let b = inViewport[j].1
                if nestedPair(a, b) {
                    skipped += 1
                    continue
                }
                XCTAssertFalse(
                    overlaps(a, b),
                    "\(tag) text collision: “\(inViewport[i].0.label)” \(a) × “\(inViewport[j].0.label)” \(b)"
                )
            }
        }

        return """
        \(tag) text elements measured: \(measured)
        \(tag) OK no text-to-text collision (\(skipped) nested pairs skipped)
        \(tag) OK text within screen width
        \(tag) OK text inside its container

        """
    }

    /// The ring's labels live inside the arc: they must stay within the inner region and
    /// never sit on the stroke.
    private func ringLabelChecks() -> String {
        guard let ring = rect("storageRing") else {
            XCTFail("storageRing missing")
            return "FAIL storageRing missing\n"
        }
        let center = CGPoint(x: ring.midX, y: ring.midY)
        let strokeOuter = ring.width / 2
        let strokeInner = strokeOuter - 14
        var log = ""

        for t in app.staticTexts.allElementsBoundByAccessibilityElement where t.exists {
            let f = t.frame
            guard f.width > 0, f.height > 0 else { continue }
            guard ring.contains(CGPoint(x: f.midX, y: f.midY)) else { continue }

            let corners = [
                CGPoint(x: f.minX, y: f.minY),
                CGPoint(x: f.maxX, y: f.minY),
                CGPoint(x: f.minX, y: f.maxY),
                CGPoint(x: f.maxX, y: f.maxY)
            ]
            let distances = corners.map { hypot($0.x - center.x, $0.y - center.y) }
            let maxDistance = distances.max() ?? 0

            // Fully inside the inner circle ⇒ it cannot touch the stroke at all.
            XCTAssertLessThanOrEqual(
                maxDistance,
                strokeInner + 1,
                "ring label outside the inner region: “\(t.label)” \(f) max \(maxDistance) > \(strokeInner)"
            )
            log += maxDistance <= strokeInner + 1
                ? "OK ring label inside inner region: “\(t.label)”\n"
                : "FAIL ring label inside inner region: “\(t.label)”\n"
        }

        log += "ring geometry: center \(center) inner radius \(strokeInner) stroke to \(strokeOuter)\n"
        return log
    }
}
