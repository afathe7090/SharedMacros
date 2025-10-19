// The Swift Programming Language
// https://docs.swift.org/swift-book

/// A macro that produces both a value and a string containing the
/// source code that generated the value. For example,
///
///     #stringify(x + y)
///
/// produces a tuple `(x + y, "x + y")`.
@freestanding(expression)
public macro stringify<T>(_ value: T) -> (T, String) = #externalMacro(module: "SharedMacrosMacros", type: "StringifyMacro")

/// A macro that generates setter methods for all variable properties
/// and adds a Builder typealias. For example:
///
///     @Setable
///     struct Request {
///       var value: Int?
///     }
///
/// expands to:
///
///     struct Request {
///       var value: Int?
///       typealias Builder = (Self) -> Self
///       
///       @discardableResult
///       func setValue(_ value: Int?) -> Self {
///         var copy = self
///         copy.value = value
///         return copy
///       }
///     }
@attached(member, names: arbitrary)
public macro Setable() = #externalMacro(module: "SharedMacrosMacros", type: "SetableMacro")

/// A macro that generates mock data methods for testing purposes.
/// For example:
///
///     @MockData
///     struct User {
///       var name: String?
///       var age: Int?
///     }
///
/// expands to:
///
///     struct User {
///       var name: String?
///       var age: Int?
///       
///       static func mock() -> User {
///         User(name: "Mock Name", age: 25)
///       }
///       
///       static var preview: User {
///         User(name: "Preview Name", age: 30)
///       }
///     }
@attached(member, names: arbitrary)
public macro MockData() = #externalMacro(module: "SharedMacrosMacros", type: "MockDataMacro")

/// A macro that automatically generates a complete spy implementation for testing.
/// Works on protocols, classes, and structs. Tracks method calls, captures arguments,
/// and provides simulation helpers. Supports completion handlers, async/await, and Combine.
///
/// Usage on Protocols - Just add @Spy:
///
///     @Spy
///     protocol FeedLoader {
///       func fetchData(completion: @escaping (Result<[FeedItem], Error>) -> Void)
///       func deleteData(id: String) async throws -> Bool
///     }
///
/// Usage on Classes - Add @Spy:
///
///     @Spy
///     class DataService {
///       init(apiKey: String) { }
///       func loadData() async throws -> [Item] { }
///     }
///
/// Usage on Structs - Add @Spy:
///
///     @Spy
///     struct APIClient {
///       var baseURL: String
///       func request(_ endpoint: String) async throws -> Data { }
///     }
///
/// This automatically generates a `TypeNameSpy` class with:
/// - ✅ Complete implementation of all methods
/// - ✅ Same initializer signature (for classes/structs)
/// - ✅ State enum tracking all method calls with arguments
/// - ✅ Completion handlers storage and simulation methods
/// - ✅ Async continuations and resume methods
/// - ✅ Combine publisher subjects and simulation helpers
/// - ✅ Call count and verification helpers
///
/// Then use it in tests:
///
///     let spy = FeedLoaderSpy()
///     let serviceSpy = DataServiceSpy(apiKey: "test")
///     spy.fetchData { result in }
///     spy.completeFetchDataWithSuccess([item])
///
@attached(peer, names: suffixed(Spy))
public macro Spy() = #externalMacro(module: "SharedMacrosMacros", type: "SpyMacro")