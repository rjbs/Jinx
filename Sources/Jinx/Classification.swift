import JinxWire

/// How a failure is handled: retry later with the entry kept, or give
/// up on this item and revert it.
public enum FailureClass: Sendable, Hashable {
  case retryable
  case permanent
  /// The batch was too big; retry with smaller batches.
  case tooLarge
}

public enum Classification {
  /// For a method-level error on a `/set` call.
  public static func classify(_ error: MethodError) -> FailureClass {
    switch error.type {
    case MethodError.serverUnavailable, MethodError.serverFail, MethodError.serverPartialFail, MethodError.stateMismatch:
      return .retryable
    case MethodError.requestTooLarge:
      return .tooLarge
    default:
      return .permanent
    }
  }

  /// For a per-object `SetError`.
  public static func classify(_ error: SetError) -> FailureClass {
    switch error.type {
    case SetError.rateLimit:
      return .retryable
    default:
      return .permanent
    }
  }

  /// For an error from the transport, before any method ran.
  public static func classify(_ error: JMAPError) -> FailureClass {
    switch error {
    case .transport:
      return .retryable
    case .httpStatus(let status, _):
      return status >= 500 || status == 429 ? .retryable : .permanent
    case .request(let request):
      return request.kind == .limit ? .tooLarge : .permanent
    case .malformed, .badSession:
      return .permanent
    }
  }
}
