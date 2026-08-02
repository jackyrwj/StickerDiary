import CoreImage
import Foundation
import UIKit
import Vision

enum StickerForegroundExtractor {
    static func extract(from imageData: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: imageData),
                  let cgImage = image.cgImage else { return nil }

            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: image.imageOrientation.cgImageOrientation,
                options: [:]
            )
            let request = VNGenerateForegroundInstanceMaskRequest()

            let visionResult: UIImage?
            do {
                try handler.perform([request])
                guard let observation = request.results?.first,
                      !observation.allInstances.isEmpty else {
                    return removeConnectedBorderBackground(from: cgImage)
                }

                let pixelBuffer = try observation.generateMaskedImage(
                    ofInstances: observation.allInstances,
                    from: handler,
                    croppedToInstancesExtent: true
                )
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                let context = CIContext(options: [.cacheIntermediates: false])
                if let maskedCGImage = context.createCGImage(
                    ciImage,
                    from: ciImage.extent
                ) {
                    visionResult = UIImage(
                        cgImage: maskedCGImage,
                        scale: 1,
                        orientation: .up
                    )
                } else {
                    visionResult = nil
                }
            } catch {
                visionResult = nil
            }

            let candidate = visionResult?.cgImage ?? cgImage
            return removeConnectedBorderBackground(from: candidate) ?? visionResult
        }.value
    }

    private static func removeConnectedBorderBackground(
        from source: CGImage
    ) -> UIImage? {
        let width = source.width
        let height = source.height
        guard width > 1, height > 1 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        var redTotal = 0
        var greenTotal = 0
        var blueTotal = 0
        var sampleCount = 0
        let stride = max(1, min(width, height) / 80)

        func addSample(x: Int, y: Int) {
            let offset = y * bytesPerRow + x * bytesPerPixel
            guard pixels[offset + 3] > 200 else { return }
            redTotal += Int(pixels[offset])
            greenTotal += Int(pixels[offset + 1])
            blueTotal += Int(pixels[offset + 2])
            sampleCount += 1
        }

        for x in Swift.stride(from: 0, to: width, by: stride) {
            addSample(x: x, y: 0)
            addSample(x: x, y: height - 1)
        }
        for y in Swift.stride(from: 0, to: height, by: stride) {
            addSample(x: 0, y: y)
            addSample(x: width - 1, y: y)
        }
        guard sampleCount > 0 else { return UIImage(cgImage: source) }

        let background = (
            red: redTotal / sampleCount,
            green: greenTotal / sampleCount,
            blue: blueTotal / sampleCount
        )
        let thresholdSquared = 52 * 52
        var removed = [Bool](repeating: false, count: width * height)
        var queue: [Int] = []
        queue.reserveCapacity(width * height / 2)

        func resemblesBackground(_ index: Int) -> Bool {
            let offset = index * bytesPerPixel
            if pixels[offset + 3] < 24 { return true }
            let red = Int(pixels[offset]) - background.red
            let green = Int(pixels[offset + 1]) - background.green
            let blue = Int(pixels[offset + 2]) - background.blue
            return red * red + green * green + blue * blue <= thresholdSquared
        }

        func enqueue(_ index: Int) {
            guard !removed[index], resemblesBackground(index) else { return }
            removed[index] = true
            queue.append(index)
        }

        for x in 0..<width {
            enqueue(x)
            enqueue((height - 1) * width + x)
        }
        for y in 0..<height {
            enqueue(y * width)
            enqueue(y * width + width - 1)
        }

        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let x = index % width
            let y = index / width
            if x > 0 { enqueue(index - 1) }
            if x + 1 < width { enqueue(index + 1) }
            if y > 0 { enqueue(index - width) }
            if y + 1 < height { enqueue(index + width) }
        }

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for index in 0..<removed.count {
            let offset = index * bytesPerPixel
            if removed[index] {
                pixels[offset] = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
                pixels[offset + 3] = 0
                continue
            }
            guard pixels[offset + 3] >= 24 else { continue }
            let x = index % width
            let y = index / width
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }

        guard maxX >= minX, maxY >= minY,
              let cleaned = context.makeImage() else { return nil }
        let crop = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
        guard let cropped = cleaned.cropping(to: crop) else { return nil }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }
}

private extension UIImage.Orientation {
    var cgImageOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
