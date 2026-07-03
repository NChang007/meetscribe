import Foundation

public enum MathUtil {
    public static func cosineSimilarity(_ left: [Float], _ right: [Float]) -> Float {
        guard left.count == right.count, !left.isEmpty else { return 0 }
        var dot: Float = 0
        var normLeft: Float = 0
        var normRight: Float = 0
        for index in 0..<left.count {
            dot += left[index] * right[index]
            normLeft += left[index] * left[index]
            normRight += right[index] * right[index]
        }
        let denominator = sqrt(normLeft) * sqrt(normRight)
        guard denominator > 0 else { return 0 }
        return dot / denominator
    }

    public static func mean(of vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        var accumulator = [Float](repeating: 0, count: first.count)
        for vector in vectors {
            guard vector.count == first.count else { continue }
            for index in 0..<vector.count {
                accumulator[index] += vector[index]
            }
        }
        let count = Float(vectors.count)
        return accumulator.map { $0 / count }
    }
}
