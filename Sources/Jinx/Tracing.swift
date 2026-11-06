import Foundation
import JinxJSON
import JinxWire
import os
import Synchronization

/// Signposts for Instruments.  They cost next to nothing when nothing is
/// recording, so they are always on.  The "step" intervals nest the way
/// a pass does, and each "request" interval names its step, so a pass
/// timeline shows which step made which round trip and how long each
/// took.
enum Trace {
  static let signposter = OSSignposter(subsystem: "Jinx", category: "sync")
}

/// Runs `body` as a named step: a signpost interval, and a transport
/// purpose that a recording transport stamps on every request made
/// inside it.  Steps nest, and a nested step's purpose names its parents,
/// as in `sync-in › windowed › query inbox`.
func traced<T, E: Error>(
  _ step: String,
  isolation: isolated (any Actor)? = #isolation,
  _ body: () async throws(E) -> T
) async throws(E) -> T {
  let purpose = TransportContext.purpose.map { "\($0) › \(step)" } ?? step
  let state = Trace.signposter.beginInterval("step", id: Trace.signposter.makeSignpostID(), "\(purpose, privacy: .public)")
  defer { Trace.signposter.endInterval("step", state) }
  // TaskLocal.withValue rethrows untyped, which would lose a typed
  // error such as connect's JMAPError, so the result travels out as
  // a Result. -- claude, 2026-11-05
  let result: Result<T, E> = await TransportContext.$purpose.withValue(purpose) { () async -> Result<T, E> in
    do throws(E) { return .success(try await body()) } catch { return .failure(error) }
  }
  return try result.get()
}

/// The taps attached to one engine.  With none attached, a request costs
/// one lock to find that out, and no exchange is built.
final class WireTaps: Sendable {
  private struct State {
    var nextExchangeId = 1
    var taps: [UUID: any WireTap] = [:]
  }

  private let state = Mutex(State())

  func add(_ tap: any WireTap) -> WireTapToken {
    let id = UUID()
    state.withLock { $0.taps[id] = tap }
    return WireTapToken { [weak self] in
      _ = self?.state.withLock { $0.taps.removeValue(forKey: id) }
    }
  }

  /// Starts an exchange and tells every tap, or returns `nil` when there
  /// are none to tell.  The id is assigned here, not by a tap, so that
  /// every tap means the same exchange by it.
  func begin(_ kind: TransportExchange.Kind) -> TransportExchange? {
    let purpose = TransportContext.purpose
    let (exchange, taps) = state.withLock { state -> (TransportExchange?, [any WireTap]) in
      guard !state.taps.isEmpty else { return (nil, []) }
      defer { state.nextExchangeId += 1 }
      let exchange = TransportExchange(id: state.nextExchangeId, purpose: purpose, kind: kind, started: Date(), outcome: .pending)
      return (exchange, Array(state.taps.values))
    }
    guard let exchange else { return nil }
    for tap in taps { tap.observe(exchange) }
    return exchange
  }

  func finish(_ exchange: TransportExchange?, _ outcome: TransportExchange.Outcome) {
    guard var exchange else { return }
    exchange.outcome = outcome
    exchange.finished = Date()
    let taps = state.withLock { Array($0.taps.values) }
    for tap in taps { tap.observe(exchange) }
  }
}

/// The engine's own wrapper around its transport.  Each exchange is a
/// signpost interval named for the current step, and is reported to
/// whatever taps are attached.  The blob store and push go through it
/// too, since they use the engine's transport.
struct EngineTransport: JMAPTransport {
  let inner: any JMAPTransport
  let taps: WireTaps

  private func exchange<T>(
    _ kind: TransportExchange.Kind,
    _ signpost: String,
    outcome: (T) -> TransportExchange.Outcome,
    _ body: () async throws(JMAPError) -> T
  ) async throws(JMAPError) -> T {
    let purpose = TransportContext.purpose ?? "-"
    let state = Trace.signposter.beginInterval(
      "request", id: Trace.signposter.makeSignpostID(),
      "\(signpost, privacy: .public) for \(purpose, privacy: .public)"
    )
    defer { Trace.signposter.endInterval("request", state) }
    let exchange = taps.begin(kind)
    do {
      let result = try await body()
      taps.finish(exchange, outcome(result))
      return result
    } catch {
      taps.finish(exchange, .failed(String(describing: error)))
      throw error
    }
  }

  func fetchSession() async throws(JMAPError) -> Session {
    try await exchange(.session, "session", outcome: { .session($0) }) { () async throws(JMAPError) in
      try await inner.fetchSession()
    }
  }

  func send(_ request: Request, to apiUrl: URL) async throws(JMAPError) -> Response {
    let names = request.methodCalls.map(\.name).joined(separator: ",")
    return try await exchange(.api(request, url: apiUrl), names, outcome: { .api($0) }) { () async throws(JMAPError) in
      try await inner.send(request, to: apiUrl)
    }
  }

  func upload(_ data: Data, contentType: String, to uploadUrl: URL) async throws(JMAPError) -> UploadResponse {
    let kind = TransportExchange.Kind.upload(contentType: contentType, size: data.count, url: uploadUrl)
    return try await exchange(kind, "upload", outcome: { .upload($0) }) { () async throws(JMAPError) in
      try await inner.upload(data, contentType: contentType, to: uploadUrl)
    }
  }

  func download(from url: URL, range: Range<Int>?) async throws(JMAPError) -> BlobDownload {
    let outcome = { (download: BlobDownload) in
      TransportExchange.Outcome.download(
        contentType: download.contentType,
        size: download.data.count,
        range: download.range,
        totalLength: download.totalLength
      )
    }
    return try await exchange(.download(url, range: range), "download", outcome: outcome) { () async throws(JMAPError) in
      try await inner.download(from: url, range: range)
    }
  }

  func events(from url: URL) -> AsyncThrowingStream<ServerSentEvent, any Error> {
    let upstream = inner.events(from: url)
    guard let exchange = taps.begin(.events(url)) else { return upstream }
    let taps = taps
    return AsyncThrowingStream { continuation in
      let task = Task {
        var count = 0
        do {
          for try await event in upstream {
            count += 1
            continuation.yield(event)
          }
          taps.finish(exchange, .eventStreamEnded(eventCount: count))
          continuation.finish()
        } catch {
          taps.finish(exchange, .failed(String(describing: error)))
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

extension SyncEngine {
  /// Attaches a tap that sees every exchange with the server from now
  /// on, until the token is cancelled or released.
  public nonisolated func addWireTap(_ tap: any WireTap) -> WireTapToken {
    wireTaps.add(tap)
  }
}
