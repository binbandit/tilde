import Foundation
import NaturalLanguage

/// On-device meaning vectors from Apple's contextual (transformer) embedding,
/// mean-pooled over tokens. Nothing leaves the Mac.
///
/// Raw pooled vectors all point roughly the same way (unrelated sentences
/// still score ~0.75), so search subtracts the corpus mean before comparing,
/// which restores a useful ranking. Raw similarity stays useful at the very
/// top end, for spotting the same fact said twice.
final class Embedder {
    private let model: NLContextualEmbedding? = {
        guard let model = NLContextualEmbedding(language: .english), model.hasAvailableAssets else {
            NLContextualEmbedding(language: .english)?.requestAssets { _, _ in }
            return nil
        }
        return (try? model.load()) != nil ? model : nil
    }()

    var isAvailable: Bool { model != nil }

    /// A unit-length, mean-pooled vector for `text`.
    func vector(_ text: String) -> [Float]? {
        let clipped = String(text.prefix(1_000))
        guard let model, !clipped.isEmpty,
            let result = try? model.embeddingResult(for: clipped, language: .english)
        else { return nil }
        var sum = [Float](repeating: 0, count: model.dimension)
        var count: Float = 0
        result.enumerateTokenVectors(in: clipped.startIndex..<clipped.endIndex) { vector, _ in
            for i in vector.indices where i < sum.count { sum[i] += Float(vector[i]) }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        return Embedder.normalized(sum.map { $0 / count })
    }

    /// Generic sentences that steady the corpus mean while the notebook is still small.
    private(set) lazy var background: [[Float]] = [
        "Prefers short commit messages.", "The project builds with a single command.", "Tests run in CI on every push.",
        "Uses a dark theme everywhere.", "The app is written in Swift.", "Meetings happen on Monday mornings.",
        "Deploys go out from the main branch.", "Likes concise answers.", "The website uses Next.js.",
        "Bugs are tracked in Linear.", "Works from home on Fridays.", "The repo lives under the Developer folder.",
    ].compactMap(vector)

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    static func mean(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == sum.count { for i in v.indices { sum[i] += v[i] } }
        return sum.map { $0 / Float(vectors.count) }
    }

    static func centered(_ v: [Float], _ mean: [Float]) -> [Float] {
        normalized(zip(v, mean).map { $0 - $1 })
    }

    /// Cosine similarity of two unit vectors.
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in a.indices { sum += a[i] * b[i] }
        return sum
    }

    static func encode(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }

    static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
