import CoreVideo
import Foundation
import Metal
import simd

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
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            return nil
        }
        let library: any MTLLibrary
        do {
            library = try Self.compileShaders(on: device)
        } catch {
            Log.importing.error("frame processing shaders did not compile: \(error.localizedDescription, privacy: .public)")
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

    /// Compiles the kernels; throws the compiler's diagnostics on failure.
    static func compileShaders(on device: any MTLDevice) throws -> any MTLLibrary {
        try device.makeLibrary(source: PlaneShaders.source, options: nil)
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

    // MARK: - Mark removal

    /// Slope and intercept of a translucent mark for one plane, as textures
    /// the size of the mark's rectangle in that plane.
    struct BlendMaps {
        var slope: any MTLTexture
        var intercept: any MTLTexture
    }

    /// A neighbouring frame's pixels around the mark, in the frame's own
    /// sample format, with where to read them.
    struct Candidate {
        /// Raw rows of the luma and chroma crops.
        var planes: [Data]
        /// Crop rectangle in luma pixels (even origin and size).
        var crop: PixelRect
        /// Content at `p` in the current frame is at `p + (dx, dy)` here.
        var dx: Int
        var dy: Int
        var weight: Float
    }

    struct MarkJob {
        /// The mark in luma pixels; origin and size are even.
        var rect: PixelRect
        /// Luma maps, then chroma maps; `nil` when the mark is not un-mixed.
        var maps: [BlendMaps]?
        /// Up to two neighbouring frames that show what is behind the mark.
        var candidates: [Candidate] = []
        /// How much of the fill comes from the neighbouring frames, 0 … 1.
        var temporalMix: Float = 1
    }

    /// Texture holding per-pixel values for a plane (one or two components).
    func makeMapTexture(width: Int, height: Int, components: [[Float]]) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: max(1, width), height: max(1, height), mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.textureUnavailable }

        var packed = [Float](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            for component in 0..<4 {
                // Components a plane does not have behave as "untouched".
                packed[index * 4 + component] = component < components.count ? components[component][index] : 1
            }
        }
        packed.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: width * 4 * MemoryLayout<Float>.size
            )
        }
        return texture
    }

    /// Copies one plane's rectangle out of a frame, in its native format.
    static func copyPlane(of buffer: CVPixelBuffer, plane: Int, rect: PixelRect) -> Data {
        let bytesPerSample = (planeFormat(of: buffer)?.levels ?? 0) > 0 ? 2 : 1
        let bytesPerPixel = bytesPerSample * (plane == 0 ? 1 : 2)
        var data = Data(count: rect.width * rect.height * bytesPerPixel)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return data }
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        data.withUnsafeMutableBytes { destination in
            for row in 0..<rect.height {
                memcpy(
                    destination.baseAddress! + row * rect.width * bytesPerPixel,
                    base + (rect.y + row) * rowBytes + rect.x * bytesPerPixel,
                    rect.width * bytesPerPixel
                )
            }
        }
        return data
    }

    /// The same rectangle as floating-point samples, 0 … 1 in the scale the
    /// kernels work in. `component` selects Cb or Cr in the chroma plane.
    static func planeImage(of buffer: CVPixelBuffer, plane: Int, rect: PixelRect, component: Int = 0) -> PlaneImage {
        let wide = (planeFormat(of: buffer)?.levels ?? 0) > 0
        let components = plane == 0 ? 1 : 2
        var image = PlaneImage(width: rect.width, height: rect.height)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return image }
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        for row in 0..<rect.height {
            let line = base + (rect.y + row) * rowBytes
            for column in 0..<rect.width {
                let index = (rect.x + column) * components + component
                image.pixels[row * rect.width + column] = wide
                    ? Float(line.load(fromByteOffset: index * 2, as: UInt16.self)) / 65535
                    : Float(line.load(fromByteOffset: index, as: UInt8.self)) / 255
            }
        }
        return image
    }

    func removeMark(in frame: CVPixelBuffer, job: MarkJob) throws -> CVPixelBuffer {
        guard let format = Self.planeFormat(of: frame) else { throw Failure.unsupportedPixelFormat }
        let output = try makeBuffer(like: frame)

        try run { pass in
            for plane in 0..<2 {
                let divisor = plane == 0 ? 1 : 2
                let planeFormat = plane == 0 ? format.luma : format.chroma
                let bytesPerPixel = (format.levels > 0 ? 2 : 1) * (plane == 0 ? 1 : 2)

                // Candidate crops become textures for the duration of the pass.
                var candidateTextures: [any MTLTexture] = []
                var candidateParameters: [SIMD4<Float>] = []
                for candidate in job.candidates.prefix(2) {
                    let crop = PixelRect(
                        x: candidate.crop.x / divisor, y: candidate.crop.y / divisor,
                        width: candidate.crop.width / divisor, height: candidate.crop.height / divisor
                    )
                    let texture = try pass.makeTexture(format: planeFormat, width: crop.width, height: crop.height)
                    candidate.planes[plane].withUnsafeBytes { bytes in
                        texture.replace(
                            region: MTLRegionMake2D(0, 0, crop.width, crop.height), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: crop.width * bytesPerPixel
                        )
                    }
                    candidateTextures.append(texture)
                    candidateParameters.append(
                        SIMD4(
                            Float(candidate.dx) / Float(divisor) - Float(crop.x),
                            Float(candidate.dy) / Float(divisor) - Float(crop.y),
                            candidate.weight, 0
                        )
                    )
                }
                let placeholder = try pass.makeTexture(format: planeFormat, width: 1, height: 1)
                while candidateTextures.count < 2 {
                    candidateTextures.append(placeholder)
                    candidateParameters.append(.zero)
                }

                let rect = PixelRect(
                    x: job.rect.x / divisor, y: job.rect.y / divisor,
                    width: job.rect.width / divisor, height: job.rect.height / divisor
                )
                let mapPlaceholder = try pass.makeTexture(format: .rgba32Float, width: 1, height: 1)
                var parameters = MarkParameters(
                    rect: SIMD4(Int32(rect.x), Int32(rect.y), Int32(rect.width), Int32(rect.height)),
                    candidateA: candidateParameters[0],
                    candidateB: candidateParameters[1],
                    usesMaps: job.maps == nil ? 0 : 1,
                    stride: Int32(SpatialFill.stride(for: rect)),
                    levels: format.levels,
                    minimumSlope: BlendEstimator.minimumSlope,
                    temporalMix: min(max(job.temporalMix, 0), 1)
                )
                try pass.dispatch(
                    kernel: "removeMark",
                    textures: [
                        try pass.texture(frame, plane: plane),
                        job.maps?[plane].slope ?? mapPlaceholder,
                        job.maps?[plane].intercept ?? mapPlaceholder,
                        candidateTextures[0],
                        candidateTextures[1],
                        try pass.texture(output, plane: plane)
                    ],
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

/// Mirrors `MarkParameters` in the shader source, field for field.
struct MarkParameters {
    var rect: SIMD4<Int32>
    var candidateA: SIMD4<Float>
    var candidateB: SIMD4<Float>
    var usesMaps: Int32
    var stride: Int32
    var levels: Float
    var minimumSlope: Float
    var temporalMix: Float
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

    /// Removes a fixed mark inside a rectangle of one plane and copies every
    /// other pixel unchanged. Per pixel, in order of fidelity:
    ///
    /// 1. un-mix a translucent mark with the measured slope and intercept;
    /// 2. take real content from up to two neighbouring frames, shifted by
    ///    the motion between the frames;
    /// 3. fill from the border of the rectangle (same samples and weights
    ///    as `SpatialFill`).
    static let removeMark = """

    struct MarkParameters {
        int4 rect;          // x, y, width, height in this plane
        float4 candidateA;  // xy: added to the pixel position, z: weight
        float4 candidateB;
        int usesMaps;
        int stride;
        float levels;
        float minimumSlope;
        float temporalMix;  // 1: neighbouring frames only, 0: surroundings only
    };

    static float4 borderSample(texture2d<float, access::read> image, int2 position, int2 direction) {
        int2 limit = int2(image.get_width() - 1, image.get_height() - 1);
        float4 total = float4(0.0);
        for (int depth = 0; depth < 3; depth++) {
            total += image.read(uint2(clamp(position + direction * depth, int2(0), limit)));
        }
        return total / 3.0;
    }

    static void accumulate(float4 value, float2 position, float2 pixel, thread float4 &total, thread float &weights) {
        float2 delta = position - pixel;
        float squared = dot(delta, delta) + 0.25;
        float weight = 1.0 / (squared * sqrt(squared));
        total += weight * value;
        weights += weight;
    }

    static float4 spatialFill(texture2d<float, access::read> image, int4 rect, int stride, float2 pixel) {
        int width = int(image.get_width());
        int height = int(image.get_height());
        int maxX = rect.x + rect.z;
        int maxY = rect.y + rect.w;
        float4 total = float4(0.0);
        float weights = 0.0;

        for (int position = rect.x; position < maxX; position += stride) {
            int x = min(position + stride / 2, maxX - 1);
            if (rect.y >= 1) {
                accumulate(borderSample(image, int2(x, rect.y - 1), int2(0, -1)), float2(x, rect.y - 1), pixel, total, weights);
            }
            if (maxY < height) {
                accumulate(borderSample(image, int2(x, maxY), int2(0, 1)), float2(x, maxY), pixel, total, weights);
            }
        }
        for (int position = rect.y; position < maxY; position += stride) {
            int y = min(position + stride / 2, maxY - 1);
            if (rect.x >= 1) {
                accumulate(borderSample(image, int2(rect.x - 1, y), int2(-1, 0)), float2(rect.x - 1, y), pixel, total, weights);
            }
            if (maxX < width) {
                accumulate(borderSample(image, int2(maxX, y), int2(1, 0)), float2(maxX, y), pixel, total, weights);
            }
        }
        return weights > 0.0 ? total / weights : image.read(uint2(pixel));
    }

    kernel void removeMark(texture2d<float, access::read> image,
                           texture2d<float, access::read> slopeMap,
                           texture2d<float, access::read> interceptMap,
                           texture2d<float, access::sample> candidateA,
                           texture2d<float, access::sample> candidateB,
                           texture2d<float, access::write> result,
                           constant MarkParameters &parameters [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= result.get_width() || gid.y >= result.get_height()) { return; }
        float4 value = image.read(gid);
        int2 local = int2(gid) - parameters.rect.xy;
        if (local.x < 0 || local.y < 0 || local.x >= parameters.rect.z || local.y >= parameters.rect.w) {
            // Outside the mark: bit for bit the input.
            result.write(value, gid);
            return;
        }

        float4 slope = float4(0.0);
        float4 intercept = float4(0.0);
        if (parameters.usesMaps != 0) {
            slope = slopeMap.read(uint2(local));
            intercept = interceptMap.read(uint2(local));
        }
        bool4 unmixed = slope >= float4(parameters.minimumSlope);
        float4 output = (value - intercept) / max(slope, float4(parameters.minimumSlope));

        if (!all(unmixed)) {
            float4 fill;
            float weightA = parameters.candidateA.z;
            float weightB = parameters.candidateB.z;
            if (weightA + weightB > 0.0 && parameters.temporalMix > 0.0) {
                constexpr sampler linear(coord::pixel, address::clamp_to_edge, filter::linear);
                float2 centre = float2(gid) + 0.5;
                fill = float4(0.0);
                if (weightA > 0.0) { fill += weightA * candidateA.sample(linear, centre + parameters.candidateA.xy); }
                if (weightB > 0.0) { fill += weightB * candidateB.sample(linear, centre + parameters.candidateB.xy); }
                fill /= (weightA + weightB);
                if (parameters.temporalMix < 1.0) {
                    // Easing between the two kinds of fill over a few frames
                    // instead of switching from one frame to the next.
                    float4 surroundings = spatialFill(image, parameters.rect, max(parameters.stride, 1), float2(gid));
                    fill = mix(surroundings, fill, parameters.temporalMix);
                }
            } else {
                fill = spatialFill(image, parameters.rect, max(parameters.stride, 1), float2(gid));
            }
            output = select(fill, output, unmixed);
        }

        // Pixels the maps mark as untouched (slope 1, intercept 0) come out
        // exactly as they went in.
        bool4 untouched = select(bool4(false), intercept == float4(0.0), slope == float4(1.0));
        output = select(output, value, untouched);
        result.write(quantize(output, parameters.levels), gid);
    }
    """

    static var source: String { common + removeMark }
}
