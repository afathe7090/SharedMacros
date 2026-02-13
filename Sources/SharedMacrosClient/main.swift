import Combine
import Foundation
import SharedMacros

// Completion-based protocol
@Spy
protocol Service {
  func load(id: Int, _ block: @escaping (Result<String, Error>) -> Void)
}

// Modern concurrency protocol
@Spy
protocol DataStore {
  func fetchItems() async throws -> [String]
  func deleteItem(id: String) async throws -> Bool
  func saveItem(name: String, value: Int) async throws
  func refresh() async
}

// Verify: completion-based spy
func testCompletionSpy() {
  let spy = ServiceSpy()
  spy.load(id: 1) { _ in }
  assert(spy.callCount == 1)
  assert(spy.loadReceivedIds == [1])
  spy.completeLoadWithSuccess("done", at: 0)
  print("Completion spy: passed")
}

// Verify: async spy with method-based complete API
func testAsyncSpy() async throws {
  let spy = DataStoreSpy()
  
  // Pre-configure via method call (before the async call)
  spy.completeFetchItemsWithSuccess(["a", "b"])
  let items = try await spy.fetchItems()
  assert(items == ["a", "b"])
  
  // Argument tracking (single param)
  spy.completeDeleteItemWithSuccess(true)
  let deleted = try await spy.deleteItem(id: "123")
  assert(deleted == true)
  assert(spy.deleteItemReceivedIds == ["123"])
  
  // Argument tracking (multi param tuple)
  spy.completeSaveItemWithSuccess()
  try await spy.saveItem(name: "test", value: 42)
  assert(spy.saveItemReceivedArguments.first?.name == "test")
  assert(spy.saveItemReceivedArguments.first?.value == 42)
  
  // async -> Void: completes immediately, no setup needed
  await spy.refresh()
  assert(spy.callCount == 4)
  
  // Error injection via method call
  spy.completeFetchItemsWithError(NSError(domain: "test", code: 1))
  do {
    _ = try await spy.fetchItems()
    assert(false, "Should have thrown")
  } catch {
    assert((error as NSError).domain == "test")
  }
  
  print("Async spy: passed")
}

// Run
testCompletionSpy()
Task {
  try await testAsyncSpy()
  exit(0)
}
RunLoop.main.run(until: Date().addingTimeInterval(5))
