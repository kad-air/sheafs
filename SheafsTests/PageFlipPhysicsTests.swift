import Testing
import Foundation
@testable import Sheafs

/// The page flip's physics, checked against a second computation rather than itself: the bent
/// leaf's length is measured by numerically integrating along the deformed sheet, and must be
/// the flat width (paper does not stretch); the free edge must be where the finger put it.
struct PageFlipPhysicsTests {
    static let widths: [Double] = [180, 320, 404, 466, 760]

    /// Length of the deformed sheet, by summing small steps along it.
    static func measuredLength(of curl: PageCurl) -> Double {
        let steps = 20_000
        var length = 0.0
        var previous = curl.point(at: 0)
        for i in 1 ... steps {
            let next = curl.point(at: curl.width * Double(i) / Double(steps))
            length += hypot(next.x - previous.x, next.z - previous.z)
            previous = next
        }
        return length
    }

    @Test func paperNeverStretches() {
        for width in Self.widths {
            for step in 0 ... 50 {
                let curl = PageCurl.solve(amount: Double(step) / 50, width: width)
                let measured = Self.measuredLength(of: curl)
                #expect(abs(measured - width) < width * 0.0005, "width \(width) amount \(step)/50: \(measured)")
                #expect(curl.flat >= 0 && curl.flat <= width)
                #expect(curl.radius >= 0)
            }
        }
    }

    @Test func freeEdgeFollowsTheFinger() {
        for width in Self.widths {
            for step in 0 ... 100 {
                let amount = Double(step) / 100
                let curl = PageCurl.solve(amount: amount, width: width)
                let expected = width - 2 * width * amount
                #expect(abs(curl.edge - expected) < 0.01, "width \(width) amount \(amount): edge \(curl.edge)")
            }
        }
    }

    @Test func endpointsAreFlatPages() {
        let flat = PageCurl.solve(amount: 0, width: 400)
        #expect(flat.flat == 400)
        #expect(flat.point(at: 400).z == 0)
        let turned = PageCurl.solve(amount: 1, width: 400)
        #expect(turned.flat == 0)
        #expect(turned.radius < 1e-9)
        #expect(abs(turned.point(at: 400).x + 400) < 1e-9)
    }

    @Test func shapeIsContinuousAcrossThePhases() {
        // The bend reaches the spine and then shrinks; the sheet must never jump, including at
        // the switch between the two phases. (Right at lift-off the edge rises before it moves
        // sideways, so where the sheet leaves the surface races inward for a few steps while
        // the sheet itself barely moves; after that `flat` is smooth too.)
        let width = 404.0
        var previous = PageCurl.solve(amount: 0, width: width)
        for step in 1 ... 2000 {
            let curl = PageCurl.solve(amount: Double(step) / 2000, width: width)
            var moved = 0.0
            for s in stride(from: 0.0, through: width, by: width / 200) {
                let now = curl.point(at: s), before = previous.point(at: s)
                moved = max(moved, hypot(now.x - before.x, now.z - before.z))
                // The highest point of the leaf never exceeds the bend's diameter.
                #expect(now.z <= 2 * curl.radius + 1e-9)
            }
            #expect(moved < 6, "the sheet jumped \(moved) pt at step \(step)")
            #expect(abs(curl.radius - previous.radius) < 1, "radius jumped at \(step)")
            if step > 20 { #expect(abs(curl.flat - previous.flat) < 3, "flat jumped at \(step)") }
            previous = curl
        }
    }

    @Test func tiltNeverLiftsTheBoundEdge() {
        // A tilted axis through (flat, grab row) must not cross the hinge inside the page.
        let height = 800.0
        for grab in stride(from: 0.0, through: 1, by: 0.05) {
            for amount in stride(from: 0.0, through: 1, by: 0.05) {
                let curl = PageCurl.solve(amount: amount, width: 404)
                let tilt = PageCurl.tilt(amount: amount, grab: grab, flat: curl.flat, height: height)
                let farthest = max(grab, 1 - grab) * height
                #expect(curl.flat - farthest * abs(tan(tilt)) >= -1e-6, "grab \(grab) amount \(amount)")
                if amount >= 1 { #expect(tilt == 0) }
            }
        }
        #expect(PageCurl.tilt(amount: 0.1, grab: 0.95, flat: 300, height: height) > 0)
        #expect(PageCurl.tilt(amount: 0.1, grab: 0.05, flat: 300, height: height) < 0)
    }

    @Test func releasedLeafSettlesWithoutBouncing() {
        var spring = FlipSpring(value: 0.3, velocity: 1.5, target: 1)
        var previous = spring.value
        var elapsed = 0.0
        while !spring.isSettled && elapsed < 3 {
            spring.step(1.0 / 120)
            elapsed += 1.0 / 120
            #expect(spring.value >= previous - 1e-9, "went back at \(elapsed)")
            #expect(spring.value <= 1 + 1e-6)
            previous = spring.value
        }
        #expect(elapsed < 0.8, "took \(elapsed) s")
        // Frame rate must not change the path: 60 Hz and 120 Hz agree.
        var slow = FlipSpring(value: 0.3, velocity: 1.5, target: 1)
        var fast = FlipSpring(value: 0.3, velocity: 1.5, target: 1)
        for _ in 0 ..< 30 { slow.step(1.0 / 60) }
        for _ in 0 ..< 60 { fast.step(1.0 / 120) }
        #expect(abs(slow.value - fast.value) < 1e-6)
    }
}
