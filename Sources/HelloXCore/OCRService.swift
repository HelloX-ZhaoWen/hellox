@preconcurrency import Vision
import CoreGraphics
import Foundation
import NaturalLanguage

public protocol TextRecognizing: Sendable {
    func recognizeText(in image: CGImage) async throws -> OCRResult
}

public struct VisionOCRService: TextRecognizing, Sendable {
    public init() {}

    public func recognizeText(in image: CGImage) async throws -> OCRResult {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.minimumTextHeight = 0.01
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])

            let blocks = (request.results ?? []).compactMap { observation -> RecognizedTextBlock? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return RecognizedTextBlock(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    boundingBox: observation.boundingBox
                )
            }.sorted(by: Self.readingOrder)

            guard !blocks.isEmpty else { throw HelloXError.noTextFound }
            let text = Self.join(blocks)
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            let language = recognizer.dominantLanguage?.rawValue
            let average = blocks.reduce(Float.zero) { $0 + $1.confidence } / Float(blocks.count)
            return OCRResult(text: text, language: language, averageConfidence: average, blocks: blocks)
        }.value
    }

    public static func readingOrder(_ lhs: RecognizedTextBlock, _ rhs: RecognizedTextBlock) -> Bool {
        let lineTolerance = max(lhs.boundingBox.height, rhs.boundingBox.height) * 0.55
        if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > lineTolerance {
            return lhs.boundingBox.midY > rhs.boundingBox.midY
        }
        return lhs.boundingBox.minX < rhs.boundingBox.minX
    }

    public static func join(_ blocks: [RecognizedTextBlock]) -> String {
        guard let first = blocks.first else { return "" }
        var result = first.text
        var previous = first
        for block in blocks.dropFirst() {
            let tolerance = max(previous.boundingBox.height, block.boundingBox.height) * 0.55
            result += abs(previous.boundingBox.midY - block.boundingBox.midY) > tolerance ? "\n" : " "
            result += block.text
            previous = block
        }
        return result
    }
}
