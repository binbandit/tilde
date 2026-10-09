import Foundation

/// Something only Brayden can answer.
public struct Attention: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public var jobID: String?
    public var question: String
    public var options: [String]
    /// Index into `options` of what tilde would pick.
    public var recommended: Int?
    /// Why it's asking, or what exactly is at stake (e.g. the command).
    public var detail: String?
    /// A worker request to answer directly with Brayden's reply.
    public var requestID: String?
    public var isApproval: Bool
    public var createdAt: Date

    public init(
        id: String, jobID: String?, question: String, options: [String], recommended: Int?, detail: String?,
        requestID: String?, isApproval: Bool
    ) {
        self.id = id
        self.jobID = jobID
        self.question = question
        self.options = options
        self.recommended = recommended
        self.detail = detail
        self.requestID = requestID
        self.isApproval = isApproval
        createdAt = .now
    }
}
