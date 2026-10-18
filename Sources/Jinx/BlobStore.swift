import Foundation
import JinxJSON
import JinxStore
import JinxWire

public enum BlobError: Error, Sendable, Equatable {
  /// The server no longer has the blob; a superseded blobId.  The
  /// referencing objects are being refetched.
  case gone(String)
  case notPresent(String)
  case transport(String)
}

/// Files for blobs, keyed by blobId, with pinned and cached ones told
/// apart.  Pinned blobs stay until unpinned; cached ones are evicted
/// least recently used once the cache exceeds its limit.  Downloads
/// resume, and a range can be read before the whole blob is present,
/// which is what streaming playback needs.
///
/// The index lives in the sync store; the bytes live under `directory`,
/// one file per blob, written at byte offsets so a partial file is just
/// a file with holes.
public actor BlobStore<Store: SyncStore> {
  public struct Configuration: Sendable {
    public var directory: URL
    /// Bytes of cached (unpinned) blobs to keep; pinned blobs do not
    /// count.
    public var cacheLimit: Int64
    public var excludeFromBackup: Bool

    public init(directory: URL, cacheLimit: Int64 = 512 * 1024 * 1024, excludeFromBackup: Bool = true) {
      self.directory = directory
      self.cacheLimit = cacheLimit
      self.excludeFromBackup = excludeFromBackup
    }
  }

  public let configuration: Configuration
  let accountId: String
  let transport: any JMAPTransport
  let store: Store
  let session: @Sendable () async throws -> Session
  var onGone: (@Sendable (String) async -> Void)?
  private var prepared = false

  public init(
    configuration: Configuration,
    accountId: String,
    transport: any JMAPTransport,
    store: Store,
    session: @escaping @Sendable () async throws -> Session
  ) {
    self.configuration = configuration
    self.accountId = accountId
    self.transport = transport
    self.store = store
    self.session = session
  }

  /// Called when a download finds the blob gone from the server.
  public func setGoneHandler(_ handler: @escaping @Sendable (String) async -> Void) {
    onGone = handler
  }

  // MARK: - Reads

  public func status(_ blobId: String) async throws -> BlobRecord? {
    let accountId = accountId
    return try await store.read { tx in try tx.blob(accountId: accountId, blobId: blobId) }
  }

  /// The file holding a complete blob, or `nil` if it is not all here.
  public func url(for blobId: String) async throws -> URL? {
    guard let record = try await status(blobId), record.isComplete else { return nil }
    try await touch(record)
    return path(blobId)
  }

  /// Bytes of a range, downloading whatever part of it is missing.
  public func read(_ blobId: String, range: Range<Int>) async throws -> Data {
    try prepare()
    var record = try await status(blobId) ?? BlobRecord(accountId: accountId, blobId: blobId)
    if let total = record.totalLength, range.upperBound > total {
      throw BlobError.notPresent("\(blobId): range \(range) beyond length \(total)")
    }
    for gap in record.missing(in: range) {
      record = try await fetch(gap, into: record)
      if record.isComplete { break }
    }
    try await touch(record)
    let handle = try FileHandle(forReadingFrom: path(blobId))
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(range.lowerBound))
    let data = try handle.read(upToCount: range.count) ?? Data()
    return data
  }

  // MARK: - Downloads

  /// Fetches the whole blob, resuming any partial file, and returns its
  /// file.  `pin` keeps it out of cache eviction.
  @discardableResult
  public func download(_ blobId: String, contentType: String? = nil, pin: Bool = false) async throws -> URL {
    try prepare()
    var record = try await status(blobId) ?? BlobRecord(accountId: accountId, blobId: blobId)
    if let contentType { record.contentType = contentType }
    if pin { record.isPinned = true }
    if !record.isComplete {
      if let total = record.totalLength {
        for gap in record.missing(in: 0..<total) {
          record = try await fetch(gap, into: record)
        }
      } else {
        record = try await fetch(nil, into: record)
      }
    }
    try await touch(record)
    try await enforceCacheLimit()
    return path(blobId)
  }

  /// Marks blobs pinned and downloads any that are not complete.
  public func pin(_ blobIds: [String]) async throws {
    for blobId in blobIds {
      try await download(blobId, pin: true)
    }
  }

  /// Marks blobs cached, so eviction may take them.
  public func unpin(_ blobIds: [String]) async throws {
    let accountId = accountId
    try await store.write { tx in
      for blobId in blobIds {
        guard var record = try tx.blob(accountId: accountId, blobId: blobId) else { continue }
        record.isPinned = false
        try tx.setBlob(record)
      }
    }
  }

  /// Removes a blob's file and index entry, pinned or not.
  public func evict(_ blobId: String) async throws {
    let accountId = accountId
    try await store.write { tx in try tx.deleteBlob(accountId: accountId, blobId: blobId) }
    try? FileManager.default.removeItem(at: path(blobId))
  }

  /// Deletes least recently used cached blobs until the cache fits.
  public func enforceCacheLimit() async throws {
    let accountId = accountId
    let records = try await store.read { tx in try tx.blobs(accountId: accountId) }
    var cached = Int64(records.filter { !$0.isPinned }.reduce(0) { $0 + $1.bytesPresent })
    for record in records where !record.isPinned && cached > configuration.cacheLimit {
      try await evict(record.blobId)
      cached -= Int64(record.bytesPresent)
    }
  }

  public func upload(_ data: Data, contentType: String) async throws -> UploadResponse {
    let session = try await session()
    guard let url = session.uploadUrl.expand(["accountId": accountId]) else {
      throw JMAPError.badSession("uploadUrl")
    }
    return try await transport.upload(data, contentType: contentType, to: url)
  }

  // MARK: - Plumbing

  /// Fetches `range`, or everything when `nil`, writes it at its offset,
  /// and returns the updated record, saved.
  private func fetch(_ range: Range<Int>?, into record: BlobRecord) async throws -> BlobRecord {
    let session = try await session()
    guard let url = session.downloadUrl.expand([
      "accountId": accountId,
      "blobId": record.blobId,
      "name": "blob",
      "type": record.contentType ?? "application/octet-stream",
    ]) else { throw JMAPError.badSession("downloadUrl") }

    let download: BlobDownload
    do {
      download = try await transport.download(from: url, range: range)
    } catch JMAPError.httpStatus(404, _) {
      try await evict(record.blobId)
      await onGone?(record.blobId)
      throw BlobError.gone(record.blobId)
    } catch {
      throw BlobError.transport(String(describing: error))
    }

    var record = record
    let offset = download.range?.lowerBound ?? 0
    try write(download.data, at: offset, to: path(record.blobId))
    record.add(offset..<(offset + download.data.count))
    if let total = download.totalLength { record.totalLength = total }
    if download.range == nil { record.totalLength = download.data.count }
    if let type = download.contentType, record.contentType == nil { record.contentType = type }
    record.lastAccess = Date()
    let saved = record
    try await store.write { tx in try tx.setBlob(saved) }
    return record
  }

  private func write(_ data: Data, at offset: Int, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))
    try handle.write(contentsOf: data)
  }

  private func touch(_ record: BlobRecord) async throws {
    var record = record
    record.lastAccess = Date()
    let saved = record
    try await store.write { tx in try tx.setBlob(saved) }
  }

  private func path(_ blobId: String) -> URL {
    configuration.directory.appendingPathComponent(accountId, isDirectory: true).appendingPathComponent(blobId)
  }

  private func prepare() throws {
    guard !prepared else { return }
    var directory = configuration.directory.appendingPathComponent(accountId, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if configuration.excludeFromBackup {
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try directory.setResourceValues(values)
    }
    prepared = true
  }
}

extension SyncEngine {
  /// A blob store wired to this engine's transport, store and session,
  /// whose gone-blob handler refetches the objects that named the blob.
  public func makeBlobStore(_ configuration: BlobStore<Store>.Configuration) async -> BlobStore<Store> {
    let blobs = BlobStore(
      configuration: configuration,
      accountId: accountId,
      transport: transport,
      store: store,
      session: { [weak self] in
        guard let self else { throw SyncError.notConnected }
        return try await self.currentSession()
      }
    )
    await blobs.setGoneHandler { [weak self] blobId in
      try? await self?.refetchReferrers(of: blobId)
    }
    return blobs
  }

  /// Refetches every held object whose blob-valued property names
  /// `blobId`, so that a superseded blob is replaced by its successor.
  public func refetchReferrers(of blobId: String) async throws {
    let accountId = accountId
    for descriptor in orderedTypes where !descriptor.blobProperties.isEmpty {
      let properties = descriptor.blobProperties
      let ids = try await store.read { tx in
        try tx.objects(accountId: accountId, type: descriptor.name)
          .filter { object in properties.contains { object.local[$0]?.stringValue == blobId } }
          .compactMap(\.id)
      }
      if !ids.isEmpty {
        try await fetch(descriptor.name, ids: ids)
      }
    }
  }
}
