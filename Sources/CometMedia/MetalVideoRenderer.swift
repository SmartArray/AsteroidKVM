// Present shared decoder buffers with GPU color conversion and bounded GPU work.
import AppKit
import CometCore
import CoreVideo
import MetalKit
import simd

public final class MetalVideoRenderer: NSObject, MTKViewDelegate {
  public let mailbox: FrameMailbox
  public var scaleMode = ScaleMode.fit
  public var rotation = 0
  public var frozenFrame: VideoFrame?
  public var onGeometry: ((DisplayGeometry) -> Void)?
  public var onError: ((String) -> Void)?
  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private var cache: CVMetalTextureCache!
  private let inFlight = DispatchSemaphore(value: 2)
  private var lastFrame: VideoFrame?
  private var previousGeometry: DisplayGeometry?

  // Compile a small native shader once; per-frame work only creates texture views and command buffers.
  public init(mailbox: FrameMailbox, device: MTLDevice) throws {
    self.mailbox = mailbox
    self.device = device
    guard let queue = device.makeCommandQueue() else {
      throw CometError.unsupported("Metal command queue is unavailable.")
    }
    self.queue = queue
    let library = try device.makeLibrary(source: Self.shader, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "videoVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "videoFragment")
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    super.init()
    guard
      CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess
    else { throw CometError.unsupported("Core Video’s Metal texture cache is unavailable.") }
  }

  // Recompute presentation geometry when the drawable changes without replacing the stream or decoder.
  public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    previousGeometry = nil
  }

  // Draw the newest frame and never block the display thread behind GPU work.
  public func draw(in view: MTKView) {
    guard inFlight.wait(timeout: .now()) == .success else { return }
    var committed = false
    defer { if !committed { inFlight.signal() } }
    if let frozenFrame {
      lastFrame = frozenFrame
    } else if let frame = mailbox.next() {
      lastFrame = frame
    } else if mailbox.snapshot() == nil {
      lastFrame = nil
    }

    // Clear disconnected content instead of retaining the last remote image indefinitely.
    guard let frame = lastFrame else {
      if let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
        let command = queue.makeCommandBuffer(),
        let encoder = command.makeRenderCommandEncoder(descriptor: pass)
      {
        encoder.endEncoding()
        command.present(drawable)
        let semaphore = inFlight
        command.addCompletedHandler { _ in semaphore.signal() }
        committed = true
        command.commit()
      }
      return
    }
    let geometry = DisplayGeometry(
      source: frame.size, viewport: view.bounds.size, mode: scaleMode,
      rotation: rotation + frame.rotation, backingScale: view.window?.backingScaleFactor ?? 1,
      pixelAspect: frame.pixelAspect)
    if geometry != previousGeometry {
      previousGeometry = geometry
      onGeometry?(geometry)
    }
    guard geometry.valid, let pass = view.currentRenderPassDescriptor,
      let drawable = view.currentDrawable,
      let command = queue.makeCommandBuffer()
    else { return }
    // Let ColorSync interpret the shader output using the frame's primaries and transfer attachments.
    if let attachments = CVBufferCopyAttachments(frame.buffer, .shouldPropagate),
      let colorSpace = CVImageBufferCreateColorSpaceFromAttachments(attachments)?
        .takeRetainedValue()
    {
      view.colorspace = colorSpace
    }
    let pixelFormat = CVPixelBufferGetPixelFormatType(frame.buffer)
    let rgb = pixelFormat == kCVPixelFormatType_32BGRA
    let width = CVPixelBufferGetWidth(frame.buffer)
    let height = CVPixelBufferGetHeight(frame.buffer)
    guard
      let texture0 = texture(
        frame.buffer, plane: 0, format: rgb ? .bgra8Unorm : .r8Unorm, width: width, height: height)
    else {
      if frame.copied {
        onError?("Metal could not create a texture even after the pixel-buffer copy fallback.")
      } else {
        mailbox.enableTextureFallback(for: frame)
      }
      return
    }
    let texture1 =
      rgb
      ? texture0
      : texture(
        frame.buffer, plane: 1, format: .rg8Unorm, width: (width + 1) / 2, height: (height + 1) / 2)
    guard let texture1, let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
      return
    }
    var uniforms = uniforms(frame: frame, geometry: geometry, rgb: rgb)
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
    encoder.setFragmentTexture(CVMetalTextureGetTexture(texture0), index: 0)
    encoder.setFragmentTexture(CVMetalTextureGetTexture(texture1), index: 1)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.endEncoding()
    command.present(drawable)

    // Captured resources outlive GPU execution; a two-slot semaphore bounds outstanding command buffers.
    let mailbox = self.mailbox
    let semaphore = inFlight
    command.addCompletedHandler { [frame, texture0, texture1] buffer in
      withExtendedLifetime((frame, texture0, texture1)) {}
      mailbox.presented(milliseconds: max(0, buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
      semaphore.signal()
    }
    committed = true
    command.commit()
  }

  // Create a Metal view over a retained pixel-buffer plane instead of copying its pixels.
  private func texture(
    _ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, width: Int, height: Int
  ) -> CVMetalTexture? {
    var result: CVMetalTexture?
    guard
      CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, cache, buffer, nil, format, width, height, plane, &result)
        == kCVReturnSuccess
    else { return nil }
    return result
  }

  // Matrix coefficients honor Rec.601/709/2020 attachments and limited versus full-range YUV.
  private struct Uniforms {
    var rect: SIMD4<Float>
    var red: SIMD4<Float>
    var green: SIMD4<Float>
    var blue: SIMD4<Float>
    var options: SIMD4<Float>
  }

  // Select color coefficients and geometry from the frame metadata for GPU conversion.
  private func uniforms(frame: VideoFrame, geometry: DisplayGeometry, rgb: Bool) -> Uniforms {
    let matrix = CVBufferCopyAttachment(frame.buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
    let coefficients: (Float, Float) =
      matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
      ? (0.299, 0.114)
      : matrix == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
        ? (0.2627, 0.0593) : (0.2126, 0.0722)
    let (kr, kb) = coefficients
    let kg = 1 - kr - kb
    let full =
      CVPixelBufferGetPixelFormatType(frame.buffer)
      == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    let yScale: Float = full ? 1 : 255 / 219
    let cScale: Float = full ? 1 : 255 / 224
    let yOffset: Float = full ? 0 : 16 / 255
    let cOffset: Float = 128 / 255

    // Fold video-range offsets into the matrix so each shader sample needs one affine conversion.
    func row(_ u: Float, _ v: Float) -> SIMD4<Float> {
      SIMD4(yScale, u * cScale, v * cScale, -yScale * yOffset - (u + v) * cScale * cOffset)
    }
    let r = geometry.imageRect
    let w = geometry.viewport.width
    let h = geometry.viewport.height
    return Uniforms(
      rect: SIMD4(
        Float(r.minX / w * 2 - 1), Float(1 - r.minY / h * 2), Float(r.width / w * 2),
        Float(r.height / h * 2)),
      red: row(0, 2 * (1 - kr)), green: row(-2 * kb * (1 - kb) / kg, -2 * kr * (1 - kr) / kg),
      blue: row(2 * (1 - kb), 0),
      options: SIMD4(Float(geometry.rotation), rgb ? 1 : 0, 0, 0))
  }

  // Rotate texture coordinates on the GPU so source pixels stay untouched for OCR and pointer mapping.
  private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float4 rect; float4 red; float4 green; float4 blue; float4 options; };
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex videoVertex(uint id [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
        float2 p = float2(id & 1, id >> 1);
        Vertex out; out.position = float4(u.rect.x + p.x * u.rect.z, u.rect.y - p.y * u.rect.w, 0, 1);
        if (u.options.x == 90) out.uv = float2(p.y, 1 - p.x);
        else if (u.options.x == 180) out.uv = 1 - p;
        else if (u.options.x == 270) out.uv = float2(1 - p.y, p.x);
        else out.uv = p;
        return out;
    }
    fragment float4 videoFragment(Vertex in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                  texture2d<float> plane0 [[texture(0)]], texture2d<float> plane1 [[texture(1)]]) {
        constexpr sampler sampleFilter(filter::linear, address::clamp_to_edge);
        if (u.options.y == 1) return float4(plane0.sample(sampleFilter, in.uv).rgb, 1);
        float4 yuv = float4(plane0.sample(sampleFilter, in.uv).r, plane1.sample(sampleFilter, in.uv).rg, 1);
        return float4(saturate(float3(dot(yuv, u.red), dot(yuv, u.green), dot(yuv, u.blue))), 1);
    }
    """
}
