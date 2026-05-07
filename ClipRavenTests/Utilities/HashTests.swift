import XCTest
import ClipRavenSync
@testable import ClipRaven

final class HashTests: XCTestCase {

    // MARK: - XXHash64Wrapper

    func test_xxhash_isDeterministic() {
        XCTAssertEqual(
            XXHash64Wrapper.hash("hello"),
            XXHash64Wrapper.hash("hello")
        )
    }

    func test_xxhash_differentInputsProduceDifferentHashes() {
        XCTAssertNotEqual(
            XXHash64Wrapper.hash("hello"),
            XXHash64Wrapper.hash("world")
        )
    }

    func test_xxhash_caseSensitive() {
        XCTAssertNotEqual(
            XXHash64Wrapper.hash("Hello"),
            XXHash64Wrapper.hash("hello")
        )
    }

    func test_xxhash_returns16HexChars() {
        let result = XXHash64Wrapper.hash("test")
        XCTAssertEqual(result.count, 16, "xxHash64 output should be 16 hex chars")
        XCTAssertTrue(result.allSatisfy { $0.isHexDigit })
    }

    func test_xxhash_stringVsDataSameResult() {
        let text = "hello"
        let textHash = XXHash64Wrapper.hash(text)
        let dataHash = XXHash64Wrapper.hash(Data(text.utf8))
        XCTAssertEqual(textHash, dataHash,
                       "String overload should equal Data overload for UTF-8")
    }

    func test_xxhash_handlesEmptyString() {
        let result = XXHash64Wrapper.hash("")
        XCTAssertEqual(result.count, 16)
    }

    func test_xxhash_handlesKoreanText() {
        let a = XXHash64Wrapper.hash("안녕하세요")
        let b = XXHash64Wrapper.hash("안녕하세요")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, XXHash64Wrapper.hash("안녕"))
    }
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}
