import Foundation
import Testing
import JinxJSON
import JinxStore
import JinxWire
import JinxScriptedServer
@testable import Jinx

let trackWithBlob = TypeDescriptor(name: "Track", capability: "urn:test:music", blobProperties: ["blobId"])

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("jinx-blobs-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func makeBlobs(_ h: Harness, cacheLimit: Int64 = 1 << 30) async throws -> (BlobStore<GRDBSyncStore>, URL) {
  let directory = try temporaryDirectory()
  let blobs = await h.engine.makeBlobStore(.init(directory: directory, cacheLimit: cacheLimit))
  return (blobs, directory)
}

@Test func wholeDownloadStoresTheFileAndServesItLocally() async throws {
  let h = try Harness(types: [trackWithBlob])
  let bytes = Data((0..<100).map { UInt8($0) })
  let blobId = h.server.addBlob(bytes, type: "audio/mpeg")
  let (blobs, directory) = try await makeBlobs(h)
  defer { try? FileManager.default.removeItem(at: directory) }

  #expect(try await blobs.url(for: blobId) == nil)
  let url = try await blobs.download(blobId)
  #expect(try Data(contentsOf: url) == bytes)
  let status = try #require(try await blobs.status(blobId))
  #expect(status.isComplete)
  #expect(status.totalLength == 100)
  #expect(status.contentType == nil, "the server echoes the type asked for, so it is not recorded")
  #expect(url.pathExtension == "")
  #expect(!status.isPinned)
  #expect(try await blobs.url(for: blobId) == url)

  try await blobs.download(blobId)
  #expect(h.server.downloads.count == 1, "a complete blob is not downloaded again")
  #expect(try await blobs.read(blobId, range: 10..<13) == Data([10, 11, 12]))
  #expect(h.server.downloads.count == 1)
}

@Test func rangedReadsFetchOnlyTheGapsAndResumeIntoAWholeDownload() async throws {
  let h = try Harness(types: [trackWithBlob])
  let bytes = Data((0..<100).map { UInt8($0) })
  let blobId = h.server.addBlob(bytes)
  let (blobs, directory) = try await makeBlobs(h)
  defer { try? FileManager.default.removeItem(at: directory) }

  #expect(try await blobs.read(blobId, range: 10..<20) == bytes[10..<20])
  #expect(try await blobs.read(blobId, range: 15..<30) == bytes[15..<30])
  #expect(h.server.downloads.map { $0.range } == [10..<20, 20..<30])
  let partial = try #require(try await blobs.status(blobId))
  #expect(partial.ranges == [10..<30])
  #expect(partial.totalLength == 100)
  #expect(!partial.isComplete)
  #expect(try await blobs.url(for: blobId) == nil)

  let url = try await blobs.download(blobId)
  #expect(h.server.downloads.map { $0.range } == [10..<20, 20..<30, 0..<10, 30..<100], "only the gaps")
  #expect(try Data(contentsOf: url) == bytes)
  #expect(try await blobs.status(blobId)?.isComplete == true)

  await #expect(throws: BlobError.self) { try await blobs.read(blobId, range: 90..<120) }
}

private func assertDownloadNamesFile(contentType: String?, pathExtension: String) async throws {
  let h = try Harness(types: [trackWithBlob])
  let bytes = Data([1, 2, 3])
  let blobId = h.server.addBlob(bytes)
  let (blobs, directory) = try await makeBlobs(h)
  defer { try? FileManager.default.removeItem(at: directory) }

  let url = try await blobs.download(blobId, contentType: contentType)
  #expect(url.pathExtension == pathExtension, "\(contentType ?? "no type")")
  #expect(try Data(contentsOf: url) == bytes)
  #expect(try await blobs.status(blobId)?.contentType == contentType)
  #expect(try await blobs.url(for: blobId) == url)
}

@Test func typedDownloadNamesTheFileWithTheTypesExtension() async throws {
  try await assertDownloadNamesFile(contentType: "audio/mpeg", pathExtension: "mp3")
  try await assertDownloadNamesFile(contentType: "audio/mp4", pathExtension: "mp4")
  try await assertDownloadNamesFile(contentType: "audio/x-m4a", pathExtension: "m4a")
  try await assertDownloadNamesFile(contentType: "application/octet-stream", pathExtension: "")
  try await assertDownloadNamesFile(contentType: "bogus/unknown", pathExtension: "")
  try await assertDownloadNamesFile(contentType: nil, pathExtension: "")
}

@Test func aTypeGivenLaterRenamesTheFileWithoutFetchingAgain() async throws {
  let h = try Harness(types: [trackWithBlob])
  let bytes = Data((0..<10).map { UInt8($0) })
  let blobId = h.server.addBlob(bytes)
  let (blobs, directory) = try await makeBlobs(h)
  defer { try? FileManager.default.removeItem(at: directory) }

  let bare = try await blobs.download(blobId)
  let typed = try await blobs.download(blobId, contentType: "audio/mpeg")
  #expect(typed.pathExtension == "mp3")
  #expect(!FileManager.default.fileExists(atPath: bare.path))
  #expect(try Data(contentsOf: typed) == bytes)
  #expect(h.server.downloads.count == 1)

  // A partial blob is renamed too, and resumes into its new name.
  let other = h.server.addBlob(bytes)
  _ = try await blobs.read(other, range: 0..<4)
  let resumed = try await blobs.download(other, contentType: "audio/mp4")
  #expect(try Data(contentsOf: resumed) == bytes)
  #expect(h.server.downloads.filter { $0.blobId == other }.map { $0.range } == [0..<4, 4..<10])
}

@Test func filesUnderTheBareIdMoveAndMissingFilesAreFetchedAgain() async throws {
  let h = try Harness(types: [trackWithBlob])
  let bytes = Data([7, 8, 9])
  let blobId = h.server.addBlob(bytes)
  let (blobs, directory) = try await makeBlobs(h)
  defer { try? FileManager.default.removeItem(at: directory) }

  // A typed blob cached before files had extensions sits under its id.
  let typed = try await blobs.download(blobId, contentType: "audio/mpeg")
  let bare = typed.deletingPathExtension()
  try FileManager.default.moveItem(at: typed, to: bare)
  #expect(try await blobs.url(for: blobId) == typed)
  #expect(try Data(contentsOf: typed) == bytes)
  #expect(!FileManager.default.fileExists(atPath: bare.path))

  // A file the system purged is fetched again, not read as holes.
  try FileManager.default.removeItem(at: typed)
  #expect(try await blobs.url(for: blobId) == nil)
  #expect(try await blobs.read(blobId, range: 0..<3) == bytes)
  #expect(h.server.downloads.count == 2)
}

@Test func cacheEvictsLeastRecentlyUsedButNeverPinned() async throws {
  let h = try Harness(types: [trackWithBlob])
  let a = h.server.addBlob(Data(repeating: 1, count: 40))
  let b = h.server.addBlob(Data(repeating: 2, count: 40))
  let c = h.server.addBlob(Data(repeating: 3, count: 40))
  let (blobs, directory) = try await makeBlobs(h, cacheLimit: 90)
  defer { try? FileManager.default.removeItem(at: directory) }

  try await blobs.download(a, pin: true)
  try await blobs.download(b)
  try await blobs.download(c)
  #expect(try await blobs.status(a)?.isComplete == true, "pinned, and not counted")
  #expect(try await blobs.status(b)?.isComplete == true)
  #expect(try await blobs.status(c)?.isComplete == true)

  _ = try await blobs.url(for: b)  // touch b, making c the oldest
  let d = h.server.addBlob(Data(repeating: 4, count: 40))
  try await blobs.download(d)
  #expect(try await blobs.status(c) == nil, "the least recently used cached blob was evicted")
  #expect(try await blobs.status(b) != nil)
  #expect(try await blobs.status(a) != nil)
  #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("acct").appendingPathComponent(c).path))

  try await blobs.unpin([a])
  try await blobs.enforceCacheLimit()
  #expect(try await blobs.status(a) == nil, "once unpinned, it is the oldest")

  try await blobs.pin([c])
  #expect(try await blobs.status(c)?.isPinned == true)
  #expect(h.server.downloads.filter { $0.blobId == c }.count == 2, "pinning a missing blob downloads it")
}

@Test func supersededBlobIsReportedOnPullAndGoneOnDownloadTriggersRefetch() async throws {
  let h = try Harness(types: [trackWithBlob])
  let v1 = h.server.addBlob(Data([1]))
  let v2 = h.server.addBlob(Data([2]))
  let id = h.server.create("Track", ["title": "t", "blobId": .string(v1)])
  try await h.engine.sync()
  let key = try #require(try await h.engine.object(type: "Track", id: id)).key
  let (blobs, directory) = try await makeBlobs(h)
  defer { try? FileManager.default.removeItem(at: directory) }
  try await blobs.download(v1, pin: true)

  // A retag on the server: the Track now names v2 and v1 is gone.  A
  // client that has not synced in yet and asks for v1 learns it is gone,
  // and the engine refetches the Track that named it.
  h.server.update("Track", id) { $0["blobId"] = .string(v2); $0["title"] = "renamed" }
  h.server.removeBlob(v1)
  try await blobs.evict(v1)
  await #expect(throws: BlobError.gone(v1)) { try await blobs.download(v1) }
  #expect(try await blobs.status(v1) == nil)
  let refetched = try #require(try await h.engine.object(key: key))
  #expect(refetched.value["title"] == "renamed")
  #expect(refetched.value["blobId"] == .string(v2))
  let last = try #require(try await h.journal().last)
  #expect(last.blobs == [BlobChange(type: "Track", key: key, property: "blobId", oldBlobId: v1, newBlobId: v2)])

  // The same change arriving through a sync-in is reported the same way.
  let v3 = h.server.addBlob(Data([3]))
  h.server.update("Track", id) { $0["blobId"] = .string(v3) }
  try await h.engine.sync()
  let syncedIn = try #require(try await h.journal().last { $0.source == .syncIn })
  #expect(syncedIn.blobs == [BlobChange(type: "Track", key: key, property: "blobId", oldBlobId: v2, newBlobId: v3)])
}

@Test func uploadUsesTheSessionUploadUrl() async throws {
  let h = try Harness(types: [trackWithBlob])
  let (blobs, directory) = try await makeBlobs(h)
  defer { try? FileManager.default.removeItem(at: directory) }
  let upload = try await blobs.upload(Data([9, 9]), contentType: "audio/mpeg")
  #expect(upload.size == 2)
  #expect(try await blobs.read(upload.blobId, range: 0..<2) == Data([9, 9]))
}
