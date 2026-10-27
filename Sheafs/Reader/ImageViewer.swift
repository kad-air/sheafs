import SwiftUI
import UIKit

/// A picture open in the full-screen viewer.
struct ViewedImage: Identifiable {
    let id = UUID()
    /// The picture at its own resolution (`BookSession.fullImage`), not the page's downsampled attachment.
    var image: UIImage
    /// The image block's `alt`, shown as a caption.
    var alt: String?
    var source: String
    /// The tapped page's frame in the window; the viewer keeps to that page's side of a fold.
    var pageFrame: CGRect?
}

/// Where the viewer puts the picture, and how it decodes it.
enum ImageViewerLayout {
    /// The part of the window the picture may fill (window coordinates). Over a VERTICAL fold (the
    /// inner display in landscape, flat or in book pose, where the pages are a spread) it is the
    /// half of the window on the tapped page's side, so the picture never lies across the hinge:
    /// the same in both poses, like the spread itself. Over an ACTIVE horizontal fold (tabletop) it
    /// is the upper half, where the page is. Anywhere else, the whole window.
    static func viewport(window: CGSize, division: CGRect?, divisionIsActive: Bool, pageFrame: CGRect?) -> CGRect {
        let all = CGRect(origin: .zero, size: window)
        guard let fold = division else { return all }
        if fold.height >= fold.width {
            let left = CGRect(x: 0, y: 0, width: max(0, fold.minX), height: window.height)
            let right = CGRect(x: fold.maxX, y: 0, width: max(0, window.width - fold.maxX), height: window.height)
            guard left.width >= 200, right.width >= 200 else { return all }
            // Opened without a tap: the right page, which holds the reading position.
            let x = pageFrame?.midX ?? right.midX
            return x < fold.midX ? left : right
        }
        if divisionIsActive, fold.minY >= 200 {
            return CGRect(x: 0, y: 0, width: window.width, height: fold.minY)
        }
        return all
    }

    /// The picture's size inside `viewport` at 1×: as large as fits (`ZoomingImageView` centres it).
    static func fitted(_ image: CGSize, in viewport: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = min(viewport.width / image.width, viewport.height / image.height)
        // Whole points, rounded down, so it never pokes out of the viewport (a half-point fold edge).
        return CGSize(width: (image.width * scale).rounded(.down), height: (image.height * scale).rounded(.down))
    }

    /// The viewer stays open only while its picture would stay where it is: book pose ↔ flat keeps
    /// the same half, anything else (fold, unfold, rotation, tabletop) moves or resizes the viewport,
    /// and the tapped page's side is stale on the new display, so the viewer closes.
    static func staysOpen(openedIn opened: CGRect, now: CGRect) -> Bool { opened == now }

    /// Height of the band the ✕ and Share buttons sit in, and the band the caption may fill.
    static let buttonBand: CGFloat = 72
    static let captionBand: CGFloat = 160

    /// `band` narrowed to keep 8 pt clear of the cover display's camera hole when the hole is in it,
    /// the way `PageView.headFrame` keeps the running head clear: only the hole's side moves in, or
    /// both sides (`symmetric`, for something centred like the caption).
    static func clear(_ band: CGRect, ofCamera camera: CGRect?, symmetric: Bool) -> CGRect {
        guard let hole = camera, hole.intersects(band) else { return band }
        var left = band.minX, right = band.maxX
        if hole.midX >= band.midX { right = min(right, hole.minX - 8) } else { left = max(left, hole.maxX + 8) }
        if symmetric {
            let centre = band.midX
            let half = max(0, min(centre - left, right - centre))
            return CGRect(x: centre - half, y: band.minY, width: half * 2, height: band.height)
        }
        return CGRect(x: left, y: band.minY, width: max(0, right - left), height: band.height)
    }

    /// Where the buttons and the caption go: the top and bottom of the safe part of the viewport,
    /// clear of the camera hole.
    static func controls(safe: CGRect, camera: CGRect?) -> (buttons: CGRect, caption: CGRect) {
        let buttons = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: min(buttonBand, safe.height))
        let caption = CGRect(x: safe.minX, y: max(safe.minY, safe.maxY - captionBand), width: safe.width,
                             height: min(captionBand, safe.height))
        return (clear(buttons, ofCamera: camera, symmetric: false), clear(caption, ofCamera: camera, symmetric: true))
    }

    /// Decodes image data at its own size, or held to `maxPixelSize` on its long side when larger.
    nonisolated static func decode(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        if let size = ImageUtilities.pixelSize(of: data), max(size.width, size.height) > maxPixelSize {
            return ImageUtilities.downsampled(data, maxPixelSize: maxPixelSize)
        }
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}

/// The full-screen picture: pinch (1× to 4×) and pan, double-tap to zoom in or out, a single tap
/// shows or hides the controls, swipe down or ✕ to close. The alt text is the caption. It covers the
/// whole window in the page's colour, so it reads in the reader's (forced) colour scheme. A display
/// change that moves its viewport (fold, unfold, rotation) closes it (`staysOpen`).
struct ImageViewer: View {
    let viewed: ViewedImage
    let palette: ReaderPalette
    /// The window's fold (`WindowRegions`), in window coordinates.
    let division: CGRect?
    let divisionIsActive: Bool
    /// The window scene's interface orientation, which turns the cover display's camera hole.
    let orientation: UIInterfaceOrientation
    var onClose: () -> Void
    @State private var dragProgress: CGFloat = 0
    @State private var controlsVisible = true
    @State private var openedViewport: CGRect?

    var body: some View {
        // Window coordinates, as the reader's pages do it: the proxy's size plus its insets.
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let window = CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                                height: proxy.size.height + insets.top + insets.bottom)
            let viewport = ImageViewerLayout.viewport(window: window, division: division,
                                                      divisionIsActive: divisionIsActive, pageFrame: viewed.pageFrame)
            let safe = CGRect(origin: .zero, size: window)
                .inset(by: UIEdgeInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing))
                .intersection(viewport)
            // The cover display's camera hole, as the pages place it (`CoverCamera`).
            let camera = CoverCamera.hole(window: window, hasFold: division != nil, orientation: orientation)
            let controls = safe.isNull ? nil : ImageViewerLayout.controls(safe: safe, camera: camera)
            ZStack(alignment: .topLeading) {
                Color(uiColor: palette.background)
                    .opacity(1 - 0.8 * dragProgress)
                ZoomingImage(image: viewed.image, onToggleControls: {
                    withAnimation(.snappy) { controlsVisible.toggle() }
                }, onDragProgress: { dragProgress = $0 }, onDismiss: onClose)
                .accessibilityLabel(viewed.alt.map { Text($0) } ?? Text("Picture"))
                .accessibilityAddTraits(.isImage)
                .frame(width: viewport.width, height: viewport.height)
                .offset(x: viewport.minX, y: viewport.minY)
                if controlsVisible, let controls {
                    buttons
                        .frame(width: controls.buttons.width, height: controls.buttons.height, alignment: .top)
                        .offset(x: controls.buttons.minX, y: controls.buttons.minY)
                        .opacity(1 - dragProgress)
                        .transition(.opacity)
                    caption
                        .frame(width: controls.caption.width, height: controls.caption.height, alignment: .bottom)
                        .offset(x: controls.caption.minX, y: controls.caption.minY)
                        .opacity(1 - dragProgress)
                        .transition(.opacity)
                }
            }
            .frame(width: window.width, height: window.height, alignment: .topLeading)
            .offset(x: -insets.leading, y: -insets.top)
            .onChange(of: viewport) { _, now in
                guard let opened = openedViewport, !ImageViewerLayout.staysOpen(openedIn: opened, now: now) else { return }
                print("[image] the display changed under the viewer (viewport \(opened) → \(now)): closing it")
                openedViewport = nil
                onClose()
            }
            .onAppear {
                openedViewport = viewport
                print("[image] viewer shown \(viewed.source) pixels=\(Int(viewed.image.size.width * viewed.image.scale))x"
                    + "\(Int(viewed.image.size.height * viewed.image.scale)) window=\(window) viewport=\(viewport) "
                    + "fold=\(String(describing: division)) active=\(divisionIsActive) alt=\(viewed.alt ?? "-")")
            }
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onClose)
    }

    private var buttons: some View {
        HStack {
            ShareLink(item: Image(uiImage: viewed.image),
                      preview: SharePreview(viewed.alt ?? "Picture", image: Image(uiImage: viewed.image))) {
                Image(systemName: "square.and.arrow.up")
                    .accessibilityLabel("Share")
            }
            Spacer()
            Button("Close", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
        }
        .font(.title3)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .padding(12)
    }

    @ViewBuilder
    private var caption: some View {
        if let alt = viewed.alt?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty {
            Text(alt)
                .font(.callout)
                .foregroundStyle(Color(uiColor: palette.text))
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(in: .rect(cornerRadius: 18))
                .padding(12)
        }
    }
}

/// `ZoomingImageView` in SwiftUI.
struct ZoomingImage: UIViewRepresentable {
    let image: UIImage
    var onToggleControls: () -> Void
    var onDragProgress: (CGFloat) -> Void
    var onDismiss: () -> Void

    func makeUIView(context: Context) -> ZoomingImageView {
        ZoomingImageView(image: image)
    }

    func updateUIView(_ view: ZoomingImageView, context: Context) {
        if view.image !== image { view.image = image }
        view.onToggleControls = onToggleControls
        view.onDragProgress = onDragProgress
        view.onDismiss = onDismiss
    }
}

/// A picture in a zooming scroll view, fitted to the bounds at 1× and centred at every scale, with
/// a downward drag (at 1× only) that closes it.
final class ZoomingImageView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    static let maximumZoom: CGFloat = 4
    static let doubleTapZoom: CGFloat = 2.5

    let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let dismissPan = UIPanGestureRecognizer()
    private var fittedFor: CGSize = .zero
    var onToggleControls: (() -> Void)?
    var onDragProgress: ((CGFloat) -> Void)?
    var onDismiss: (() -> Void)?

    var image: UIImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            fittedFor = .zero
            setNeedsLayout()
        }
    }

    init(image: UIImage) {
        super.init(frame: .zero)
        backgroundColor = .clear
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = Self.maximumZoom
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        scrollView.backgroundColor = .clear
        addSubview(scrollView)
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.accessibilityIgnoresInvertColors = true
        scrollView.addSubview(imageView)

        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        single.require(toFail: double)
        scrollView.addGestureRecognizer(single)
        dismissPan.addTarget(self, action: #selector(dragged(_:)))
        dismissPan.maximumNumberOfTouches = 1
        dismissPan.delegate = self
        addGestureRecognizer(dismissPan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scrollView.frame != bounds { scrollView.frame = bounds }
        // Fit again (at 1×) only when the size changes: a fold, unfold or rotation.
        guard bounds.size != fittedFor, bounds.width > 0, bounds.height > 0, let image = imageView.image else { return }
        fittedFor = bounds.size
        scrollView.zoomScale = 1
        let fit = ImageViewerLayout.fitted(image.size, in: bounds.size)
        imageView.frame = CGRect(origin: .zero, size: fit)
        scrollView.contentSize = fit
        centre()
        // Show the centring insets: contentInset alone leaves the offset at the top-left corner.
        scrollView.contentOffset = CGPoint(x: -scrollView.contentInset.left, y: -scrollView.contentInset.top)
    }

    /// Where the picture is on screen, in this view's coordinates (zoom and scroll included).
    var imageFrame: CGRect { imageView.convert(imageView.bounds, to: self) }

    /// Insets that keep a picture smaller than the view in its middle.
    private func centre() {
        let dx = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let dy = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }
        // Zoom in around the tapped point (the zoom rect is in the image view's own coordinates).
        let point = gesture.location(in: imageView)
        let size = CGSize(width: scrollView.bounds.width / Self.doubleTapZoom, height: scrollView.bounds.height / Self.doubleTapZoom)
        scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                   width: size.width, height: size.height), animated: true)
    }

    @objc private func singleTapped() { onToggleControls?() }

    // MARK: Swipe down to close

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        // Only at 1× (zoomed, a drag pans the picture) and only downward.
        guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return false }
        let velocity = dismissPan.velocity(in: self)
        return velocity.y > abs(velocity.x)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // At 1× the scroll view has nothing to scroll; its pan must not keep this one from starting.
        otherGestureRecognizer === scrollView.panGestureRecognizer
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .changed:
            let down = max(0, translation.y)
            scrollView.transform = CGAffineTransform(translationX: translation.x * 0.3, y: down)
            onDragProgress?(min(1, down / 300))
        case .ended, .cancelled, .failed:
            let velocity = gesture.velocity(in: self).y
            if gesture.state == .ended, translation.y > 120 || velocity > 900 {
                UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseIn) {
                    self.scrollView.transform = CGAffineTransform(translationX: 0, y: self.bounds.height)
                } completion: { _ in
                    print("[image] viewer closed by a swipe down")
                    self.onDismiss?()
                }
                onDragProgress?(1)
            } else {
                UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                    self.scrollView.transform = .identity
                }
                onDragProgress?(0)
            }
        default:
            break
        }
    }
}
