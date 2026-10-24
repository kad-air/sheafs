import Foundation

/// The shape of one leaf of paper being turned, in the sheet's own coordinates: the leaf is a
/// strip of width `width` hinged at x = 0 (the spine) with its free edge at x = `width` when it
/// lies flat. Pulling the free edge toward the spine does not fold the paper, it bends it: the
/// sheet lies flat from the hinge to `flat`, wraps around a cylinder of radius `radius` whose axis
/// is parallel to the spine, and whatever is left after half a turn lies flat again on top,
/// heading back toward the spine. Paper does not stretch, so the length of that path is always
/// `width`; that is the whole model, and what makes the free edge, the bulge and the part already
/// turned over move the way a real page does.
///
/// The turn has two phases. While the finger (or the fall) carries the free edge across, the
/// bend keeps its radius and travels toward the spine (`flat` shrinks to 0). Once the bend has
/// reached the spine the leaf is past vertical and falls: the radius shrinks to nothing and the
/// leaf lands flat on the other side.
nonisolated struct PageCurl: Equatable, Sendable {
    var width: Double
    /// The sheet lies flat on its original side from the hinge to here.
    var flat: Double
    var radius: Double

    /// The radius the bend settles to while travelling, as a fraction of the leaf's width; the
    /// bend is gentler (1.5×) while the edge has only just lifted, like a page that is not yet
    /// committed to turning.
    static let restRadiusFraction = 0.17

    /// The radius of the bend for a turn `amount` of the way through, before the fall.
    static func travellingRadius(width: Double, amount: Double) -> Double {
        let rest = min(width * restRadiusFraction, width / 4)
        let lift = 1 - smoothstep(0, 0.3, amount)
        return rest * (1 + 0.5 * lift)
    }

    /// Where the free edge is, in sheet coordinates (`width` flat, `-width` fully turned).
    var edge: Double { point(at: width).x }

    /// The deformed position of the point `s` along the sheet from the hinge (x across the page,
    /// z up off it).
    func point(at s: Double) -> (x: Double, z: Double) {
        if s <= flat || radius <= 0 {
            return s <= flat ? (s, 0) : (flat - (s - flat), 0)
        }
        let theta = (s - flat) / radius
        if theta <= .pi {
            return (flat + radius * sin(theta), radius * (1 - cos(theta)))
        }
        return (flat - (s - flat - .pi * radius), 2 * radius)
    }

    /// The free edge for a sheet flat to `flat` with a bend of `radius`.
    static func edge(width: Double, flat: Double, radius: Double) -> Double {
        PageCurl(width: width, flat: flat, radius: radius).edge
    }

    /// The curl for a turn `amount` (0 flat, 1 turned over) of the way through: the free edge
    /// moves at a steady pace from `width` to `-width`, and the bend follows from the paper's
    /// length. The shape is continuous in `amount`, including across the two phases.
    static func solve(amount rawAmount: Double, width: Double) -> PageCurl {
        let amount = min(1, max(0, rawAmount))
        guard width > 0 else { return PageCurl(width: 0, flat: 0, radius: 0) }
        let target = width - 2 * width * amount
        let radius = travellingRadius(width: width, amount: amount)
        // Phase 1: with the bend at the spine the edge is at πR − W; until the target gets there
        // the bend keeps its radius and we solve for where the sheet leaves the surface.
        if target >= .pi * radius - width {
            if amount <= 0 { return PageCurl(width: width, flat: width, radius: radius) }
            var low = 0.0, high = width
            for _ in 0 ..< 48 {
                let mid = (low + high) / 2
                if edge(width: width, flat: mid, radius: radius) < target { low = mid } else { high = mid }
            }
            return PageCurl(width: width, flat: (low + high) / 2, radius: radius)
        }
        // Phase 2: the leaf is past vertical and falls, the bend at the spine shrinking away.
        return PageCurl(width: width, flat: 0, radius: max(0, (target + width) / .pi))
    }

    /// How far the curl's axis may tilt from the spine's direction, in radians, when the leaf
    /// is held `grab` of the way down its height (0 top, 1 bottom): a corner leads the turn, as
    /// when you pull a page by its corner. The tilt fades as the turn proceeds and is capped so
    /// the axis never crosses the hinge within the page (a bound edge cannot lift).
    static func tilt(amount: Double, grab: Double, flat: Double, height: Double) -> Double {
        let lead = min(1, max(-1, (grab - 0.5) * 2))
        let wanted = 0.22 * lead * (1 - min(1, max(0, amount)))
        let farthest = max(grab, 1 - grab) * height
        guard farthest > 0, flat > 0 else { return 0 }
        let cap = atan(flat / farthest)
        return min(cap, max(-cap, wanted))
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}

/// A critically damped spring on one value: the released leaf falls toward its resting state
/// with whatever velocity the finger left it, slowing into the landing without bouncing (paper
/// settling onto paper does not bounce). Stepped in closed form, so frame rate does not matter.
nonisolated struct FlipSpring: Equatable, Sendable {
    var value: Double
    var velocity: Double
    var target: Double
    /// Stiffness; the spring settles in roughly 6.6 / omega seconds.
    var omega: Double = 12

    mutating func step(_ dt: Double) {
        let x0 = value - target
        let k = velocity + omega * x0
        let decay = exp(-omega * dt)
        value = target + (x0 + k * dt) * decay
        velocity = (velocity - omega * k * dt) * decay
    }

    var isSettled: Bool { abs(value - target) < 0.0015 && abs(velocity) < 0.02 }
}
