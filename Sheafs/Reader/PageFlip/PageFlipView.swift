import Metal
import MetalKit
import UIKit
import os

/// What the shader needs, as plain floats in the order `FlipUniforms` in PageFlip.metal lists
/// them (all floats, so the two layouts agree byte for byte); the shader source is in PageFlipShader.swift.
struct FlipUniforms {
    var viewWidth: Float = 0, viewHeight: Float = 0, scale: Float = 1
    var leafX: Float = 0, leafY: Float = 0, leafWidth: Float = 0, leafHeight: Float = 0
    var hinge: Float = 0, flip: Float = 1
    var flat: Float = 0, radius: Float = 0, tilt: Float = 0, grabY: Float = 0
    var inset: Float = 0, hasBack: Float = 0
    var under0X: Float = 0, under0Y: Float = 0, under0Width: Float = 0, under0Height: Float = 0, under0On: Float = 0
    var under1X: Float = 0, under1Y: Float = 0, under1Width: Float = 0, under1Height: Float = 0, under1On: Float = 0
    var paperR: Float = 1, paperG: Float = 1, paperB: Float = 1, isDark: Float = 0
    var pageTop: Float = 0, pageHeight: Float = 1

    static let floatCount = 31
}

/// Everything one turn draws with: the leaf's frame and hinge, the textures, and the page(s)
/// lying beneath. The curl itself (`flat`, `radius`, `tilt`, `grabY`) changes every frame.
struct FlipScene {
    /// The whole leaf, spine to outer edge and the window's full height, when flat.
    var leafFrame: CGRect
    /// Where the printed page sits on the leaf, vertically (window coordinates).
    var pageTop: CGFloat
    var pageHeight: CGFloat
    var hinge: CGFloat
    /// +1 when the leaf extends to the right of the hinge, −1 to the left.
    var flip: CGFloat
    /// Blank margin from the hinge to the printed page on both faces (half the gutter).
    var inset: CGFloat
    var front: MTLTexture?
    /// The page that lands face up (nil for a blank page); ignored when `ghostBack` is set.
    var back: MTLTexture?
    /// A single page has no printed back: paper with the front showing through, mirrored.
    var ghostBack: Bool
    var under: [(frame: CGRect, texture: MTLTexture?)]
    var palette: ReaderPalette
}

/// Draws the flip: a full-view Metal pass that paints the pages beneath, then the bent leaf
/// over them (see PageFlip.metal). Opaque, so it covers the pager while a turn is in flight.
final class PageFlipView: MTKView {
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let blank: MTLTexture
    var scene: FlipScene?
    var curl = PageCurl(width: 0, flat: 0, radius: 0)
    var tilt: CGFloat = 0
    var grabY: CGFloat = 0
    private let log = Logger(subsystem: "io.sheafs.reader", category: "flip")

    /// Nil when Metal is unavailable or the shader does not compile (the pager then slides).
    static func make(frame: CGRect) -> PageFlipView? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: PageFlipShader.source, options: nil)
        } catch {
            Logger(subsystem: "io.sheafs.reader", category: "flip").error("shader failed to compile: \(error)")
            return nil
        }
        guard let vertex = library.makeFunction(name: "flipVertex"),
              let fragment = library.makeFunction(name: "flipFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        let blankDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        blankDescriptor.usage = .shaderRead
        guard let blank = device.makeTexture(descriptor: blankDescriptor) else { return nil }
        var white: UInt32 = 0xFFFF_FFFF
        blank.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4)
        return PageFlipView(frame: frame, device: device, queue: queue, pipeline: pipeline, blank: blank)
    }

    private init(frame: CGRect, device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState, blank: MTLTexture) {
        self.queue = queue
        self.pipeline = pipeline
        self.blank = blank
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isOpaque = true
        isPaused = true
        enableSetNeedsDisplay = true
        isUserInteractionEnabled = false
        assert(MemoryLayout<FlipUniforms>.size == FlipUniforms.floatCount * 4, "FlipUniforms must be plain floats")
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale
        if contentScaleFactor != scale { contentScaleFactor = scale }
    }

    override func draw(_ rect: CGRect) {
        guard let scene, let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
              let buffer = queue.makeCommandBuffer() else { return }
        let paper = scene.palette.background
        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        paper.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        pass.colorAttachments[0].clearColor = MTLClearColor(red: red, green: green, blue: blue, alpha: 1)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        var uniforms = FlipUniforms()
        uniforms.viewWidth = Float(bounds.width)
        uniforms.viewHeight = Float(bounds.height)
        uniforms.scale = Float(contentScaleFactor)
        uniforms.leafX = Float(scene.leafFrame.minX)
        uniforms.leafY = Float(scene.leafFrame.minY)
        uniforms.leafWidth = Float(scene.leafFrame.width)
        uniforms.leafHeight = Float(scene.leafFrame.height)
        uniforms.hinge = Float(scene.hinge)
        uniforms.flip = Float(scene.flip)
        uniforms.flat = Float(curl.flat)
        uniforms.radius = Float(curl.radius)
        uniforms.tilt = Float(tilt)
        uniforms.grabY = Float(grabY)
        uniforms.inset = Float(scene.inset)
        uniforms.hasBack = scene.ghostBack ? 0 : (scene.back == nil ? 2 : 1)
        if scene.under.count > 0 {
            let u = scene.under[0]
            uniforms.under0X = Float(u.frame.minX); uniforms.under0Y = Float(u.frame.minY)
            uniforms.under0Width = Float(u.frame.width); uniforms.under0Height = Float(u.frame.height)
            uniforms.under0On = u.texture == nil ? 0 : 1
        }
        if scene.under.count > 1 {
            let u = scene.under[1]
            uniforms.under1X = Float(u.frame.minX); uniforms.under1Y = Float(u.frame.minY)
            uniforms.under1Width = Float(u.frame.width); uniforms.under1Height = Float(u.frame.height)
            uniforms.under1On = u.texture == nil ? 0 : 1
        }
        uniforms.paperR = Float(red); uniforms.paperG = Float(green); uniforms.paperB = Float(blue)
        uniforms.isDark = scene.palette.isDark ? 1 : 0
        uniforms.pageTop = Float(scene.pageTop - scene.leafFrame.minY)
        uniforms.pageHeight = Float(scene.pageHeight)

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FlipUniforms>.size, index: 0)
        encoder.setFragmentTexture(scene.front ?? blank, index: 0)
        encoder.setFragmentTexture(scene.back ?? blank, index: 1)
        encoder.setFragmentTexture(scene.under.first?.texture ?? blank, index: 2)
        encoder.setFragmentTexture(scene.under.count > 1 ? scene.under[1].texture ?? blank : blank, index: 3)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    // MARK: Page textures

    /// Renders a page view into a texture at the display's scale, through the same `draw(_:)`
    /// the live page uses, so the leaf carries exactly what was on screen.
    func makeTexture(for page: PageView) -> MTLTexture? {
        guard let device else { return nil }
        let scale = traitCollection.displayScale
        let size = page.bounds.size
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        let started = CFAbsoluteTimeGetCurrent()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // UIKit draws y-down; row 0 of the bitmap is the top of the page, which is v = 0 in the shader.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        UIGraphicsPushContext(context)
        page.render(in: context)
        UIGraphicsPopContext()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let data = context.data else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: context.bytesPerRow)
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        log.debug("page texture \(width)×\(height) in \(ms, format: .fixed(precision: 1)) ms")
        return texture
    }
}
