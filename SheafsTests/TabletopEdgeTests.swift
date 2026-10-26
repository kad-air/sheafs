import Testing
import Metal
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import Sheafs

/// The tabletop pose: the page stands on a surface at the fold (`TabletopBaseView`), and a turn
/// must end at the page's edge and shade that surface, not run on into the fold and stop at a line.
///
/// The landmines this pins: the leaf used to be the window's full height, so in tabletop it ran
/// 40 pt past the page into the fold and the deck cut it off flat; and the leaf's shadow stopped
/// dead at its bottom row. The shader is the real one (compiled from `PageFlipShader.source`);
/// the leaf is painted red, the page beneath blue and the surface green, so each pixel says what
/// it is and green's loss is the shade.
///
/// `TEST_RUNNER_SHEAFS_TABLETOP_RENDERS=1 xcodebuild test …` also writes renders of real pages
/// and the real surface to `<tmp>/sheafs-tabletop/` (the path is printed), to look at.
@MainActor
struct TabletopEdgeTests {
    /// The Duo's inner display, portrait, folded into tabletop: the page ends at the fold.
    static let width = 669.0, height = 951.0, pageBottom = 455.5

    final class Composer {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState

        init?() {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let library = try? device.makeLibrary(source: PageFlipShader.source, options: nil),
                  let vertex = library.makeFunction(name: "flipVertex"),
                  let fragment = library.makeFunction(name: "flipFragment") else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
            (self.device, self.queue, self.pipeline) = (device, queue, pipeline)
        }

        func solid(_ bgra: UInt32) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
            d.usage = .shaderRead
            let texture = device.makeTexture(descriptor: d)!
            var value = bgra
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &value, bytesPerRow: 4)
            return texture
        }

        /// A single page turning forward in tabletop, set up as `PageFlipDriver` sets it up.
        func uniforms(amount: Double, grab: Double, scale: Double, paper: (Float, Float, Float), isDark: Bool = false) -> FlipUniforms {
            let w = TabletopEdgeTests.width, h = TabletopEdgeTests.height, page = TabletopEdgeTests.pageBottom
            let layout = PageLayout(pageFrames: [CGRect(x: 0, y: 0, width: w, height: page)], textInsets: .zero,
                                    deckFrame: CGRect(x: 0, y: 495.5, width: w, height: h - 495.5))
            let leafHeight = Double(PageFlipDriver.leafHeight(layout: layout, viewHeight: h))
            let curl = PageCurl.solve(amount: amount, width: w)
            var u = FlipUniforms()
            u.viewWidth = Float(w); u.viewHeight = Float(h); u.scale = Float(scale)
            u.leafX = 0; u.leafY = 0; u.leafWidth = Float(w); u.leafHeight = Float(leafHeight)
            u.hinge = 0; u.flip = 1
            u.flat = Float(curl.flat); u.radius = Float(curl.radius)
            u.tilt = Float(PageCurl.tilt(amount: amount, grab: grab, flat: curl.flat, height: leafHeight))
            u.grabY = Float(grab * leafHeight)
            u.inset = 0; u.hasBack = 0
            u.under0X = 0; u.under0Y = 0; u.under0Width = Float(w); u.under0Height = Float(page); u.under0On = 1
            (u.paperR, u.paperG, u.paperB) = paper
            u.isDark = isDark ? 1 : 0
            u.pageTop = 0; u.pageHeight = Float(page)
            u.baseY = Float(page); u.baseOn = 1
            return u
        }

        /// Renders one frame; returns BGRA rows.
        func render(_ u: FlipUniforms, front: MTLTexture, under: MTLTexture, base: MTLTexture, scale: Double) -> (pixels: [UInt8], width: Int, height: Int) {
            var u = u
            let width = Int(TabletopEdgeTests.width * scale), height = Int(TabletopEdgeTests.height * scale)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            d.usage = .renderTarget
            d.storageMode = .private
            let target = device.makeTexture(descriptor: d)!
            let bytesPerRow = width * 4
            let readback = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared)!
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let buffer = queue.makeCommandBuffer()!
            let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&u, length: MemoryLayout<FlipUniforms>.size, index: 0)
            encoder.setFragmentTexture(front, index: 0)
            encoder.setFragmentTexture(front, index: 1)
            encoder.setFragmentTexture(under, index: 2)
            encoder.setFragmentTexture(under, index: 3)
            encoder.setFragmentTexture(base, index: 4)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            let blit = buffer.makeBlitCommandEncoder()!
            blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: readback, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                      destinationBytesPerImage: bytesPerRow * height)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            let pointer = readback.contents().assumingMemoryBound(to: UInt8.self)
            return (Array(UnsafeBufferPointer(start: pointer, count: bytesPerRow * height)), width, height)
        }
    }

    static let scale = 2.0
    static let red: UInt32 = 0xFFFF_0000, blue: UInt32 = 0xFF00_00FF, green: UInt32 = 0xFF00_FF00

    struct Pixel { var red, green, blue: Int }

    static func pixel(_ frame: (pixels: [UInt8], width: Int, height: Int), x: Double, y: Double) -> Pixel {
        let px = min(frame.width - 1, Int(x * scale)), py = min(frame.height - 1, Int(y * scale))
        let i = (py * frame.width + px) * 4
        return Pixel(red: Int(frame.pixels[i + 2]), green: Int(frame.pixels[i + 1]), blue: Int(frame.pixels[i]))
    }

    /// The shade of the surface at a point below the page (0 none, 1 black); nil if it is not surface.
    static func surfaceShade(_ frame: (pixels: [UInt8], width: Int, height: Int), x: Double, y: Double) -> Double? {
        let p = pixel(frame, x: x, y: y)
        guard p.red < 8, p.blue < 8 else { return nil }
        return 1 - Double(p.green) / 255
    }

    static let amounts = [0.05, 0.15, 0.3, 0.45, 0.6, 0.75, 0.9]
    static let grabs = [0.9, 0.5, 0.1]

    @Test func leafEndsAtThePageEdge() throws {
        let c = try #require(Composer())
        let (leaf, page, surface) = (c.solid(Self.red), c.solid(Self.blue), c.solid(Self.green))
        for grab in Self.grabs {
            for amount in Self.amounts {
                let frame = c.render(c.uniforms(amount: amount, grab: grab, scale: Self.scale, paper: (1, 0, 0)),
                                     front: leaf, under: page, base: surface, scale: Self.scale)
                // Every pixel from a point below the page's edge down is surface, never leaf or paper.
                for y in stride(from: Self.pageBottom + 1, to: Self.height, by: 1) {
                    for x in stride(from: 0.0, to: Self.width, by: 1.5) {
                        guard Self.surfaceShade(frame, x: x, y: y) != nil else {
                            Issue.record("amount \(amount) grab \(grab): (\(x), \(y)) is \(Self.pixel(frame, x: x, y: y)), not surface")
                            return
                        }
                    }
                }
            }
        }
    }

    @Test func liftedLeafShadesTheSurfaceAndItFades() throws {
        let c = try #require(Composer())
        let (leaf, page, surface) = (c.solid(Self.red), c.solid(Self.blue), c.solid(Self.green))
        for grab in Self.grabs {
            for amount in [0.15, 0.3, 0.45, 0.6, 0.75] {
                let frame = c.render(c.uniforms(amount: amount, grab: grab, scale: Self.scale, paper: (1, 0, 0)),
                                     front: leaf, under: page, base: surface, scale: Self.scale)
                func row(_ y: Double) -> [Double] {
                    stride(from: 0.25, to: Self.width, by: 0.5).map { Self.surfaceShade(frame, x: $0, y: y) ?? 0 }
                }
                let near = row(Self.pageBottom + 1.5), mid = row(Self.pageBottom + 8), far = row(Self.pageBottom + 20)
                let tag = "amount \(amount) grab \(grab)"
                // A shadow right under the edge of a lifted leaf…
                #expect(near.max()! > 0.06, "\(tag): no shade under the edge (max \(near.max()!))")
                // …that fades with the distance from the edge, and is gone well clear of it.
                #expect(mid.max()! < near.max()!, "\(tag): shade does not fade (\(near.max()!) → \(mid.max()!))")
                #expect(far.max()! < 0.01, "\(tag): shade 20 pt below the edge (\(far.max()!))")
                // Soft: no hard step along the edge (the old turn ended in a line).
                let steps = zip(near, near.dropFirst()).map { abs($0 - $1) }
                let worst = steps.indices.max { steps[$0] < steps[$1] }!
                #expect(steps.max()! < 0.03, "\(tag): a step of \(steps.max()!) in the shade along the edge at x = \(Double(worst) * 0.5) pt (\(near[max(0, worst - 3) ... min(near.count - 1, worst + 4)].map { ($0 * 100).rounded() / 100 }))")
                // Early in a turn the leaf still lies flat at the hinge there, and throws no shadow.
                if amount < 0.4 { #expect(near[0] < 0.005, "\(tag): shade under the flat part at the hinge (\(near[0]))") }
            }
        }
    }

    @Test func leafHeightIsThePageInTabletopAndTheWindowOtherwise() {
        let page = CGRect(x: 0, y: 0, width: Self.width, height: Self.pageBottom)
        let tabletop = PageLayout(pageFrames: [page], textInsets: .zero, deckFrame: CGRect(x: 0, y: 495.5, width: Self.width, height: 455.5))
        #expect(Double(PageFlipDriver.leafHeight(layout: tabletop, viewHeight: Self.height)) == Self.pageBottom)
        let flat = PageLayout(pageFrames: [CGRect(x: 0, y: 0, width: Self.width, height: 917)], textInsets: .zero, deckFrame: nil)
        #expect(Double(PageFlipDriver.leafHeight(layout: flat, viewHeight: Self.height)) == Self.height)
    }

    @Test func blockThinsTowardTheEnd() {
        #expect(TabletopBaseView.sheets(progress: 0) == TabletopBaseView.maxSheets)
        #expect(TabletopBaseView.sheets(progress: 1) == 1)
        let counts = stride(from: 0.0, through: 1.0, by: 0.01).map { TabletopBaseView.sheets(progress: $0) }
        #expect(zip(counts, counts.dropFirst()).allSatisfy { $0 >= $1 })
    }

    @Test func surfaceIsDarkerThanThePage() {
        func luminance(_ color: UIColor) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        for (name, palette) in [("paper", ReaderPalette.paper), ("sepia", .sepia), ("night", .night)] {
            #expect(luminance(palette.surface) < luminance(palette.background) - 0.02, "\(name): the surface must read below the page")
        }
        #expect(luminance(ReaderPalette.black.surface) == 0, "black: pure black stays unlit")
    }

    /// Opt-in renders of the real thing: a page, the surface, a turn at a few amounts.
    @Test func renders() throws {
        guard ProcessInfo.processInfo.environment["SHEAFS_TABLETOP_RENDERS"] != nil else { return }
        let c = try #require(Composer())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sheafs-tabletop")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        print("[tabletop] renders in \(dir.path)")
        for (name, palette) in [("paper", ReaderPalette.paper), ("night", .night), ("sepia", .sepia), ("black", .black)] {
            let page = PageView(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.pageBottom))
            page.palette = palette
            page.head = "Chapter 8: THE HOUSES OF HEALING"
            page.folio = "397"
            page.curvesOverFold = true
            let base = TabletopBaseView(frame: CGRect(x: 0, y: Self.pageBottom, width: Self.width, height: Self.height - Self.pageBottom))
            base.palette = palette
            base.sheets = TabletopBaseView.sheets(progress: 0.29)
            let front = try #require(PageFlipView.texture(for: page, scale: 3, device: c.device))
            let surface = try #require(PageFlipView.texture(for: base, scale: 3, device: c.device))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            palette.background.getRed(&r, green: &g, blue: &b, alpha: &a)
            for amount in [0.0, 0.25, 0.5] {
                let frame = c.render(c.uniforms(amount: amount, grab: 0.6, scale: 3, paper: (Float(r), Float(g), Float(b)), isDark: palette.isDark),
                                     front: front, under: front, base: surface, scale: 3)
                try Self.writePNG(frame, to: dir.appendingPathComponent("\(name)-\(Int(amount * 100)).png"))
            }
        }
    }

    static func writePNG(_ frame: (pixels: [UInt8], width: Int, height: Int), to url: URL) throws {
        var pixels = frame.pixels
        let context = try #require(CGContext(data: &pixels, width: frame.width, height: frame.height, bitsPerComponent: 8,
                                             bytesPerRow: frame.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
