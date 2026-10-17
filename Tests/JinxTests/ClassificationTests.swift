import Foundation
import Testing
import JinxWire
@testable import Jinx

private func assertMethod(_ type: String, is expected: FailureClass, sourceLocation: SourceLocation = #_sourceLocation) {
  #expect(Classification.classify(MethodError(type: type)) == expected, sourceLocation: sourceLocation)
}

private func assertSet(_ type: String, is expected: FailureClass, sourceLocation: SourceLocation = #_sourceLocation) {
  #expect(Classification.classify(SetError(type: type)) == expected, sourceLocation: sourceLocation)
}

@Test func methodErrorsClassify() {
  assertMethod(MethodError.serverUnavailable, is: .retryable)
  assertMethod(MethodError.serverFail, is: .retryable)
  assertMethod(MethodError.serverPartialFail, is: .retryable)
  assertMethod(MethodError.stateMismatch, is: .retryable)
  assertMethod(MethodError.requestTooLarge, is: .tooLarge)
  assertMethod(MethodError.invalidArguments, is: .permanent)
  assertMethod(MethodError.forbidden, is: .permanent)
  assertMethod("somethingNew", is: .permanent)
}

@Test func setErrorsClassify() {
  assertSet(SetError.rateLimit, is: .retryable)
  assertSet(SetError.notFound, is: .permanent)
  assertSet(SetError.invalidProperties, is: .permanent)
  assertSet(SetError.overQuota, is: .permanent)
}

@Test func transportErrorsClassify() {
  #expect(Classification.classify(JMAPError.transport(URLError(.timedOut))) == .retryable)
  #expect(Classification.classify(JMAPError.httpStatus(503, body: Data())) == .retryable)
  #expect(Classification.classify(JMAPError.httpStatus(429, body: Data())) == .retryable)
  #expect(Classification.classify(JMAPError.httpStatus(401, body: Data())) == .permanent)
  #expect(Classification.classify(JMAPError.request(RequestError(type: RequestError.urnPrefix + "limit"))) == .tooLarge)
  #expect(Classification.classify(JMAPError.request(RequestError(type: RequestError.urnPrefix + "notJSON"))) == .permanent)
  #expect(Classification.classify(JMAPError.malformed("x")) == .permanent)
}
