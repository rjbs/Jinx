import Jinx
import JinxJSON
import JinxPatch

/// Sync facts about the JMAP for Mail types (RFC 8621): what Jinx needs
/// to sync them correctly, and nothing about how an app models them.
/// Email's `/get` arguments and property list are the app's choice, so
/// `email(...)` takes them.
public enum MailTypes {
  public static let capability = "urn:ietf:params:jmap:mail"
  public static let submissionCapability = "urn:ietf:params:jmap:submission"

  /// Mailbox: the client may change name, parent, role, sort order and
  /// subscription; everything else is server-set.
  public static let mailbox = TypeDescriptor(
    name: "Mailbox",
    capability: capability,
    ownedProperties: ["name", "parentId", "role", "sortOrder", "isSubscribed"]
  )

  /// Thread is derived by the server from Emails and is read-only.  It
  /// is listed before Email because Email carries `threadId`; the
  /// reference the other way, `emailIds`, is tolerated as dangling
  /// until the same pass fetches the Email.
  public static let thread = TypeDescriptor(
    name: "Thread",
    capability: capability,
    ownedProperties: []
  )

  /// The properties of Email that are cheap and enough for a list:
  /// everything except body parts and values.
  public static let emailSummaryProperties: [String] = [
    "id", "blobId", "threadId", "mailboxIds", "keywords", "size", "receivedAt",
    "messageId", "inReplyTo", "references", "sender", "from", "to", "cc", "bcc",
    "replyTo", "subject", "sentAt", "hasAttachment", "preview",
  ]

  /// Email: only `keywords` and `mailboxIds` can change after creation.
  /// `properties` is the fetch list and `bodyProperties`,
  /// `fetchTextBodyValues`, `fetchHTMLBodyValues` and `maxBodyValueBytes`
  /// become `/get` arguments.
  public static func email(
    properties: [String]? = emailSummaryProperties,
    bodyProperties: [String]? = nil,
    fetchTextBodyValues: Bool = false,
    fetchHTMLBodyValues: Bool = false,
    fetchAllBodyValues: Bool = false,
    maxBodyValueBytes: Int? = nil
  ) -> TypeDescriptor {
    var arguments: [String: JSONValue] = [:]
    if let bodyProperties { arguments["bodyProperties"] = .array(bodyProperties.map(JSONValue.string)) }
    if fetchTextBodyValues { arguments["fetchTextBodyValues"] = true }
    if fetchHTMLBodyValues { arguments["fetchHTMLBodyValues"] = true }
    if fetchAllBodyValues { arguments["fetchAllBodyValues"] = true }
    if let maxBodyValueBytes { arguments["maxBodyValueBytes"] = .number(Double(maxBodyValueBytes)) }
    return TypeDescriptor(
      name: "Email",
      capability: capability,
      dependsOn: ["Mailbox", "Thread"],
      properties: properties,
      ownedProperties: ["keywords", "mailboxIds"],
      blobProperties: ["blobId"],
      getArguments: arguments
    )
  }

  public static let identity = TypeDescriptor(
    name: "Identity",
    capability: submissionCapability,
    ownedProperties: ["name", "replyTo", "bcc", "textSignature", "htmlSignature"]
  )

  /// EmailSubmission is created, never updated except to cancel.  The
  /// `onSuccessUpdateEmail` and `onSuccessDestroyEmail` arguments to
  /// `EmailSubmission/set` are not yet expressible through Jinx's
  /// write API.
  public static let emailSubmission = TypeDescriptor(
    name: "EmailSubmission",
    capability: submissionCapability,
    dependsOn: ["Identity", "Email"],
    ownedProperties: ["undoStatus"]
  )

  /// Every Mail type in dependency order, with Email as `email()` gives
  /// it by default.
  public static var all: [TypeDescriptor] {
    [mailbox, thread, email(), identity, emailSubmission]
  }
}
