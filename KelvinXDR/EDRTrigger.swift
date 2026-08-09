//
//  EDRTrigger.swift
//  KelvinXDR
//
//  A 1x1 pixel EDR surface. Its only job is to make macOS put the display into HDR mode,
//  which opens the headroom GammaBoost then spends.
//
//  Deliberately one pixel and unblended. The original full-screen multiply overlay showed
//  as a white box over Apple TV+ fullscreen video: DRM video is composited on a protected
//  hardware plane the compositor may not read, so the multiply blend could not be evaluated
//  and silently degraded to normal compositing. One pixel in a corner cannot cover anything.
//

import Cocoa
import MetalKit

final class EDRTrigger: MTKView, MTKViewDelegate {
    private var commandQueue: MTLCommandQueue?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1),
                   device: MTLCreateSystemDefaultDevice())

        commandQueue = device?.makeCommandQueue()
        delegate = self

        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0)

        autoResizeDrawable = false
        drawableSize = CGSize(width: 1, height: 1)
        // ponytail: 5fps keeps the EDR request alive. At 1x1 the cost is noise; raise only
        // if the display ever drops out of HDR mode on its own.
        preferredFramesPerSecond = 5

        if let layer = layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.isOpaque = false
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Stop or resume asking the window server for EDR headroom.
    func setEDREnabled(_ enabled: Bool) {
        isPaused = !enabled
        (layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = enabled
    }

    func draw(in view: MTKView) {
        // clearColor alone fills the single pixel — no geometry to draw.
        guard let commandQueue = commandQueue,
              let descriptor = currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor),
              let drawable = currentDrawable else { return }

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }
}
