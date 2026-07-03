import MeetscribeCore
import XCTest

final class MathUtilTests: XCTestCase {
    func testCosineSimilarityIdenticalVectors() {
        let vector: [Float] = [1, 0, 0]
        XCTAssertEqual(MathUtil.cosineSimilarity(vector, vector), 1.0, accuracy: 0.0001)
    }
}
