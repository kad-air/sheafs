import Testing
import Metal
import Foundation
@testable import Sheafs

/// The shadow the turning leaf throws on the page beneath, rendered by the real shader (compiled
/// from `PageFlipShader.source`, as on the device) and measured row by row. The leaf is painted
/// pure red and the page beneath pure blue, so each pixel of the page beneath reads its shadow
/// directly (blue = 1 − shade) and each row's shadow is the sum, in points of full shade. A smooth
/// sheet throws a smooth shadow: along the curled edge and through a slow drag it may deepen and
/// widen, but never step.
///
/// The landmine this pins: the shadow used to be cast only in rows where the sheet reached the
/// crest of the bend. While a corner leads the turn (the axis tilts) the crest arrives row by row,
/// so on a slow drag the shadow filled in from that corner like a progress bar, a hard edge
/// sweeping across the page (and back out on release), and a lifted edge short of the crest
/// threw next to nothing.
@MainActor
struct PageFlipShadowTests {
    /// A single page on the Duo's inner display, the leaf the whole sheet, hinged at its left
    /// edge, set up the way `PageFlipDriver` sets up a single page. Rendered at half scale (one
    /// pixel row every 2 pt) to keep the readback quick.
    static let width = 668.0, height = 952.0, scale = 0.5
    static let pixelWidth = Int(width * scale), pixelHeight = Int(height * scale)

    final class Renderer {
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        let red: MTLTexture
        let blue: MTLTexture
        let target: MTLTexture
        let readback: MTLBuffer
        let bytesPerRow = PageFlipShadowTests.pixelWidth * 4

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
            func solid(_ bgra: UInt32) -> MTLTexture? {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
                d.usage = .shaderRead
                guard let texture = device.makeTexture(descriptor: d) else { return nil }
                var value = bgra
                texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &value, bytesPerRow: 4)
                return texture
            }
            let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: PageFlipShadowTests.pixelWidth, height: PageFlipShadowTests.pixelHeight, mipmapped: false)
            targetDescriptor.usage = .renderTarget
            targetDescriptor.storageMode = .private
            guard let red = solid(0xFFFF_0000), let blue = solid(0xFF00_00FF),
                  let target = device.makeTexture(descriptor: targetDescriptor),
                  let readback = device.makeBuffer(length: bytesPerRow * PageFlipShadowTests.pixelHeight, options: .storageModeShared)
            else { return nil }
            (self.queue, self.pipeline, self.red, self.blue, self.target, self.readback) = (queue, pipeline, red, blue, target, readback)
        }

        struct Frame {
            /// The shadow on the page beneath in each pixel row, in points of full shade.
            var shadow: [Double]
            /// How far short of its flat position the leaf ends in each row, in points.
            var lifted: [Double]
            /// The mean shade (0 none, 1 black) of the 8 pt of page beneath right next to the leaf,
            /// in rows where the leaf ends at least that far short of the window's edge.
            var besideEdge: [Double?]
        }

        /// The leaf turned `amount` of the way, held `grab` of the way down (0 top, 1 bottom).
        func render(amount: Double, grab: Double) -> Frame {
            let w = PageFlipShadowTests.width, h = PageFlipShadowTests.height
            let curl = PageCurl.solve(amount: amount, width: w)
            var u = FlipUniforms()
            u.viewWidth = Float(w); u.viewHeight = Float(h); u.scale = Float(PageFlipShadowTests.scale)
            u.leafX = 0; u.leafY = 0; u.leafWidth = Float(w); u.leafHeight = Float(h)
            u.hinge = 0; u.flip = 1
            u.flat = Float(curl.flat); u.radius = Float(curl.radius)
            u.tilt = Float(PageCurl.tilt(amount: amount, grab: grab, flat: curl.flat, height: h))
            u.grabY = Float(grab * h)
            u.inset = 0; u.hasBack = 2
            u.under0X = 0; u.under0Y = 0; u.under0Width = Float(w); u.under0Height = Float(h); u.under0On = 1
            u.paperR = 1; u.paperG = 0; u.paperB = 0; u.isDark = 0
            u.pageTop = 0; u.pageHeight = Float(h)

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
            else { return Frame(shadow: [], lifted: [], besideEdge: []) }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&u, length: MemoryLayout<FlipUniforms>.size, index: 0)
            encoder.setFragmentTexture(red, index: 0)
            encoder.setFragmentTexture(red, index: 1)
            encoder.setFragmentTexture(blue, index: 2)
            encoder.setFragmentTexture(blue, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            guard let blit = buffer.makeBlitCommandEncoder() else { return Frame(shadow: [], lifted: [], besideEdge: []) }
            blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: target.width, height: target.height, depth: 1),
                      to: readback, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                      destinationBytesPerImage: bytesPerRow * target.height)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()

            let pixels = readback.contents().assumingMemoryBound(to: UInt8.self)
            let points = 1 / PageFlipShadowTests.scale
            let beside = Int(8 * PageFlipShadowTests.scale)
            var frame = Frame(shadow: [Double](repeating: 0, count: target.height), lifted: [Double](repeating: 0, count: target.height),
                              besideEdge: [Double?](repeating: nil, count: target.height))
            for y in 0 ..< target.height {
                var sum = 0, lastLeaf = -1
                let row = pixels + y * bytesPerRow
                func shade(_ x: Int) -> Int { 255 - Int(row[x * 4]) }   // BGRA: blue is byte 0
                for x in 0 ..< target.width {
                    if row[x * 4 + 2] == 0 { sum += shade(x) } else { lastLeaf = x }   // page beneath has no red
                }
                frame.shadow[y] = Double(sum) / 255 * points
                frame.lifted[y] = Double(target.width - 1 - lastLeaf) * points
                if lastLeaf + beside < target.width {
                    let strip = (lastLeaf + 1 ... lastLeaf + beside).reduce(0) { $0 + shade($1) }
                    frame.besideEdge[y] = Double(strip) / 255 / Double(beside)
                }
            }
            return frame
        }
    }

    /// Held near the bottom (the recording), the middle and the top.
    static let grabs: [Double] = [0.9, 0.5, 0.1]

    /// A slow drag, 0.67 pt of edge travel a frame, from flat through the crest reaching every row.
    @Test func shadowNeverStepsThroughASlowDrag() throws {
        let renderer = try #require(Renderer(), "Metal or the flip shader is unavailable")
        for grab in Self.grabs {
            var previous: [Double]?
            var worst = (step: 0.0, amount: 0.0, row: 0)
            for amount in stride(from: 0.0, through: 0.15, by: 0.0005) {
                let rows = renderer.render(amount: amount, grab: grab).shadow
                try #require(rows.count == Self.pixelHeight)
                if let previous {
                    for y in 1 ..< rows.count - 1 {
                        let step = abs(rows[y] - previous[y])
                        if step > worst.step { worst = (step, amount, y) }
                    }
                }
                previous = rows
            }
            print("[flip shadow] grab \(grab): worst frame-to-frame step \(worst)")
            #expect(worst.step < 2, "grab \(grab): row \(worst.row)'s shadow jumps by \(worst.step) pt between frames at amount \(worst.amount)")
        }
    }

    /// Along the curled edge: rows 8 pt apart, over the middle 80% of the page (the top and bottom
    /// tenths hold the sheet's corners, where its top and bottom edges rightly end the shadow).
    @Test func shadowNeverStepsAlongTheEdge() throws {
        let renderer = try #require(Renderer(), "Metal or the flip shader is unavailable")
        let apart = Int(8 * Self.scale)
        for grab in Self.grabs {
            var worst = (step: 0.0, amount: 0.0, row: 0)
            for amount in stride(from: 0.0, through: 0.4, by: 0.0025) {
                let rows = renderer.render(amount: amount, grab: grab).shadow
                try #require(rows.count == Self.pixelHeight)
                for y in rows.count / 10 ..< rows.count * 9 / 10 - apart {
                    let step = abs(rows[y + apart] - rows[y])
                    if step > worst.step { worst = (step, amount, y) }
                }
            }
            print("[flip shadow] grab \(grab): worst step along the edge \(worst)")
            #expect(worst.step < 2, "grab \(grab): the shadow steps by \(worst.step) pt across 8 pt of edge at row \(worst.row), amount \(worst.amount)")
        }
    }

    /// The fix must not be "no shadow": next to an edge that has visibly lifted (the leaf ends 8 pt
    /// or more short of where it lay), the page beneath is in clear shadow, and a leaf lying flat
    /// throws none. (The bar, a mean shade of 0.15 over the 8 pt beside the edge, is under half of
    /// what the crest's shadow measures there, 0.35.)
    @Test func liftedEdgeThrowsAShadow() throws {
        let renderer = try #require(Renderer(), "Metal or the flip shader is unavailable")
        for grab in Self.grabs {
            let flat = renderer.render(amount: 0, grab: grab)
            #expect(flat.shadow.max() == 0, "grab \(grab): a flat leaf throws a shadow")
            var checked = 0
            for amount in [0.01, 0.02, 0.035, 0.05, 0.07, 0.1, 0.2, 0.4] {
                let frame = renderer.render(amount: amount, grab: grab)
                var weakest = (shade: Double.infinity, row: -1, lifted: 0.0)
                for y in frame.shadow.count / 10 ..< frame.shadow.count * 9 / 10 {
                    guard let shade = frame.besideEdge[y] else { continue }
                    checked += 1
                    if shade < weakest.shade { weakest = (shade, y, frame.lifted[y]) }
                }
                print("[flip shadow] grab \(grab) amount \(amount): weakest shade beside a lifted edge \(weakest)")
                if weakest.row >= 0 {
                    #expect(weakest.shade > 0.15, "grab \(grab) amount \(amount): row \(weakest.row), lifted \(weakest.lifted) pt, has only \(weakest.shade) shade beside the edge")
                }
            }
            #expect(checked > 1000, "grab \(grab): only \(checked) lifted rows were checked")
        }
    }
}
