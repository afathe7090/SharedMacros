import Combine
import SharedMacros

@MockData
struct AnyModel {
  let name: String
  let id: Int
  let email: String
  let gender: Bool
  let new: NewANy
}

@MockData
struct NewANy {
  let value: String
  let newValue: String
}

let access = AnyModel.mock()
print(access)

@Spy
protocol FeedLoader {
  func loadFeeds(page: Int) -> AnyPublisher<String, Error>
}

class RealFeedLoader: FeedLoader {
  func loadFeeds(page: Int) -> AnyPublisher<String, any Error> {
    CurrentValueSubject<String, Error>("").eraseToAnyPublisher()
  }
}

@Spy
class ViewModel {
  let repo: FeedLoader
  init(repo: FeedLoader = FeedLoaderSpy()) {
    self.repo = repo
  }

  private func loadViews() {}

  private func newLoad() {}
}
