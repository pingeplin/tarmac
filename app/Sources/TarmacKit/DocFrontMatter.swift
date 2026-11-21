import Foundation

/// A markdown doc's front matter (spec 2611.0022, D1–D3): the fields a block
/// between two fences at the doc's top holds, and the body after it.
public enum DocFrontMatter {
    public enum Value: Equatable, Sendable {
        case text(String)
        case list([String])
    }

    public struct Field: Equatable, Sendable {
        public let key: String
        public let value: Value

        public init(key: String, value: Value) {
            self.key = key
            self.value = value
        }
    }

    public static func split(_ markdown: String) -> (fields: [Field], body: String) {
        ([], "")
    }
}
