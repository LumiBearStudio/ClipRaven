import XCTest
@testable import ClipRaven

final class CodeLanguageDetectorTests: XCTestCase {

    // MARK: - isCode

    func test_isCode_detectsSwiftFunction() {
        let code = """
        func greet(name: String) -> String {
            return "Hello, \\(name)"
        }
        """
        XCTAssertTrue(CodeLanguageDetector.isCode(code))
    }

    func test_isCode_detectsPythonFunction() {
        let code = """
        def greet(name):
            print(f"Hello, {name}")
            return name
        """
        XCTAssertTrue(CodeLanguageDetector.isCode(code))
    }

    func test_isCode_detectsJSWithArrowFunction() {
        let code = """
        const greet = (name) => {
            console.log("Hello");
            return name;
        };
        """
        XCTAssertTrue(CodeLanguageDetector.isCode(code))
    }

    func test_isCode_rejectsProse() {
        let prose = """
        The quick brown fox jumps over the lazy dog.
        This sentence has no code patterns at all.
        Just plain English text here.
        """
        XCTAssertFalse(CodeLanguageDetector.isCode(prose))
    }

    func test_isCode_rejectsSingleLine() {
        XCTAssertFalse(CodeLanguageDetector.isCode("func greet() {}"),
                       "requires ≥ 2 lines to count as code")
    }

    // MARK: - detectLanguage

    func test_detectLanguage_swift() {
        let code = """
        import SwiftUI
        struct ContentView: View {
            var body: some View { Text("Hello") }
        }
        """
        XCTAssertEqual(CodeLanguageDetector.detectLanguage(code), "swift")
    }

    func test_detectLanguage_python() {
        let code = """
        import os
        from pathlib import Path
        def main():
            print("hi")
            return 0
        """
        XCTAssertEqual(CodeLanguageDetector.detectLanguage(code), "python")
    }

    func test_detectLanguage_rust() {
        let code = """
        use std::io;
        pub fn main() {
            let mut s = String::new();
        }
        impl Foo for Bar {}
        """
        XCTAssertEqual(CodeLanguageDetector.detectLanguage(code), "rust")
    }

    func test_detectLanguage_nilForTooFewHits() {
        XCTAssertNil(CodeLanguageDetector.detectLanguage("plain text with no code markers"))
    }

    func test_detectLanguage_typescriptOverJS() {
        let code = """
        interface User {
            name: string;
            age: number;
        }
        export const fetchUser = async (): Promise<User> => {
            return { name: "a", age: 1 };
        };
        """
        XCTAssertEqual(CodeLanguageDetector.detectLanguage(code), "typescript")
    }
}
