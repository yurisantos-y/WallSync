import CoreVideo
import Foundation
import Metal

/// GPU processing of video frames in their native format, used only by the
/// optimizer — never during playback.
///
/// Frames stay biplanar Y'CbCr at their own bit depth (8-bit `420v` or
/// 10-bit `x420`) from the decoder to the encoder. Each plane is mapped as a
/// Metal texture and processed by a compute kernel, so:
///
/// * there is no round trip through RGB or through 8 bits: 10-bit and HDR
///   content keeps its precision, primaries and transfer function, which are
///   never interpreted, only carried over;
/// * pixels a kernel does not touch are copied bit for bit;
/// * a dissolve is a per-sample interpolation of the encoded values. For two
///   similar frames that cannot shift brightness (the mix of equal values is
///   that value), and because PQ, HLG and gamma encodings are perceptual, the
///   transition is perceptually even instead of bulging bright in the middle
///   as a linear-light mix does. Results are rounded to the 10-bit grid, so
///   no steps coarser than the source's own are introduced.
final class PlaneProcessor: @unchecked Sendable {
    enum Failure: Error {
        case unsupportedPixelFormat
        case textureUnavailable
        case bufferUnavailable
        case commandFailed
    }

    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private var pipelines: [String: any MTLComputePipelineState] = [:]
    private let library: any MTLLibrary
    private var pools: [String: CVPixelBufferPool] = [:]
    private let lock = NSLock()

    /// `nil` when the Mac has no usable Metal device.
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: PlaneShaders.source, options: nil) else {
            return nil
        }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let cache else { return nil }

        self.device = device
        self.queue = queue
        self.library = library
        self.textureCache = cache
    }

    // MARK: - Formats

    struct PlaneFormat {
        var luma: MTLPixelFormat
        var chroma: MTLPixelFormat
        /// Quantization grid of the samples inside the texture's storage
        /// (10-bit samples sit in the high bits of 16); 0 for none.
        var levels: Float
    }

    static func planeFormat(of buffer: CVPixelBuffer) -> PlaneFormat? {
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return PlaneFormat(luma: .r8Unorm, chroma: .rg8Unorm, levels: 0)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return PlaneFormat(luma: .r16Unorm, chroma: .rg16Unorm, levels: 65535.0 / 64.0)
        default:
            return nil
        }
    }

    /// Attributes a buffer needs to be processed here.
    static func bufferAttributes(pixelFormat: OSType, width: Int? = nil, height: Int? = nil) -> [String: Any] {
        var attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        if let width { attributes[kCVPixelBufferWidthKey as String] = width }
        if let height { attributes[kCVPixelBufferHeightKey as String] = height }
        return attributes
    }

    /// A new buffer with the format, size and colour attachments of `buffer`.
    func makeBuffer(like buffer: CVPixelBuffer) throws -> CVPixelBuffer {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let key = "\(format)-\(width)x\(height)"

        let pool: CVPixelBufferPool = try lock.withLock {
            if let existing = pools[key] { return existing }
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(
                kCFAllocatorDefault, nil,
                Self.bufferAttributes(pixelFormat: format, width: width, height: height) as CFDictionary,
                &created
            )
            guard let created else { throw Failure.bufferUnavailable }
            pools[key] = created
            return created
        }

        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        guard let output else { throw Failure.bufferUnavailable }
        CVBufferPropagateAttachments(buffer, output)
        return output
    }

    // MARK: - Kernels

    /// `a` dissolved towards `b`: 0 gives `a`, 1 gives `b`.
    func crossfade(_ a: CVPixelBuffer, _ b: CVPixelBuffer, weight: Float) throws -> CVPixelBuffer {
        guard let format = Self.planeFormat(of: a),
              CVPixelBufferGetPixelFormatType(a) == CVPixelBufferGetPixelFormatType(b),
              CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b),
              CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b) else {
            throw Failure.unsupportedPixelFormat
        }

        let output = try makeBuffer(like: a)
        var parameters = MixParameters(weight: min(max(weight, 0), 1), levels: format.levels)
        try run { pass in
            for plane in 0..<2 {
                try pass.dispatch(
                    kernel: "crossfade",
                    textures: [try pass.texture(a, plane: plane), try pass.texture(b, plane: plane), try pass.texture(output, plane: plane)],
                    parameters: &parameters
                )
            }
        }
        return output
    }

    // MARK: - Plumbing

    /// One command buffer; textures created through it stay alive until the
    /// GPU has finished.
    final class Pass {
        fileprivate let processor: PlaneProcessor
        fileprivate let commandBuffer: any MTLCommandBuffer
        fileprivate var retained: [CVMetalTexture] = []

        fileprivate init(processor: PlaneProcessor, commandBuffer: any MTLCommandBuffer) {
            self.processor = processor
            self.commandBuffer = commandBuffer
        }

        func texture(_ buffer: CVPixelBuffer, plane: Int) throws -> any MTLTexture {
            guard let format = PlaneProcessor.planeFormat(of: buffer) else { throw Failure.unsupportedPixelFormat }
            var wrapped: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, processor.textureCache, buffer, nil,
                plane == 0 ? format.luma : format.chroma,
                CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane),
                plane, &wrapped
            )
            guard let wrapped, let texture = CVMetalTextureGetTexture(wrapped) else { throw Failure.textureUnavailable }
            retained.append(wrapped)
            return texture
        }

        /// Runs `kernel` over the whole of the last texture, which is the output.
        func dispatch<Parameters>(kernel: String, textures: [any MTLTexture], parameters: inout Parameters) throws {
            let pipeline = try processor.pipeline(named: kernel)
            guard let output = textures.last, let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw Failure.commandFailed
            }
            encoder.setComputePipelineState(pipeline)
            for (index, texture) in textures.enumerated() {
                encoder.setTexture(texture, index: index)
            }
            withUnsafeBytes(of: &parameters) { bytes in
                encoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            }
            let width = pipeline.threadExecutionWidth
            let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
            encoder.dispatchThreadgroups(
                MTLSize(width: (output.width + width - 1) / width, height: (output.height + height - 1) / height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
            )
            encoder.endEncoding()
        }

        /// A texture owned by the processor, for data that is not a frame.
        func makeTexture(format: MTLPixelFormat, width: Int, height: Int) throws -> any MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: max(1, width), height: max(1, height), mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            guard let texture = processor.device.makeTexture(descriptor: descriptor) else { throw Failure.textureUnavailable }
            return texture
        }
    }

    func run(_ body: (Pass) throws -> Void) throws {
        guard let commandBuffer = queue.makeCommandBuffer() else { throw Failure.commandFailed }
        let pass = Pass(processor: self, commandBuffer: commandBuffer)
        try body(pass)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { throw Failure.commandFailed }
        // Finished: the wrapped textures may now be recycled.
        pass.retained.removeAll()
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    fileprivate func pipeline(named name: String) throws -> any MTLComputePipelineState {
        try lock.withLock {
            if let existing = pipelines[name] { return existing }
            guard let function = library.makeFunction(name: name) else { throw Failure.commandFailed }
            let created = try device.makeComputePipelineState(function: function)
            pipelines[name] = created
            return created
        }
    }
}

struct MixParameters {
    var weight: Float
    var levels: Float
}

/// Metal Shading Language source, compiled once at first use. Keeping it as
/// source avoids a build rule and a bundled `.metallib`.
enum PlaneShaders {
    static let common = """
    #include <metal_stdlib>
    using namespace metal;

    static inline float4 quantize(float4 value, float levels) {
        return levels > 0.0 ? round(saturate(value) * levels) / levels : value;
    }

    struct MixParameters {
        float weight;
        float levels;
    };

    kernel void crossfade(texture2d<float, access::read> a,
                          texture2d<float, access::read> b,
                          texture2d<float, access::write> result,
                          constant MixParameters &parameters [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= result.get_width() || gid.y >= result.get_height()) { return; }
        float4 value = mix(a.read(gid), b.read(gid), parameters.weight);
        result.write(quantize(value, parameters.levels), gid);
    }
    """

    static var source: String { common }
}
