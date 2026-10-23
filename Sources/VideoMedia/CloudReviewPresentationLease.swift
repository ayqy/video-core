import Foundation
import VideoCore

/// A presentation lease never grants CloudKit access. It only prevents a
/// completed, previously authorized read from reviving an invalidated view.
public struct CloudReviewPresentationLease: Sendable {
    public struct Request: Equatable, Sendable {
        fileprivate let generation: UInt64
    }
    public enum Update: Equatable, Sendable {
        case initial, refreshed, stale, invalidated
    }
    private var generation: UInt64 = 0
    public private(set) var versionKey: String?
    public private(set) var authorizedUntil: Date?

    public init() {}

    public mutating func begin() -> Request {
        generation &+= 1
        return Request(generation: generation)
    }

    public func isCurrent(_ request: Request) -> Bool {
        request.generation == generation
    }

    /// A correctable local input error is not an authorization failure. Retain
    /// text only while the exact foreground presentation lease remains valid.
    public func canPreserveDraft(after error: Error, request: Request,
                                 active: Bool, now: Date = Date()) -> Bool {
        guard isCurrent(request), active, let authorizedUntil, now < authorizedUntil,
              let failure = error as? VideoError, case .invalid = failure else { return false }
        return true
    }

    public mutating func authorize(_ request: Request, versionKey: String,
                                   authorizedUntil: Date, active: Bool,
                                   now: Date = Date()) -> Update {
        guard isCurrent(request) else { return .stale }
        guard active, !versionKey.isEmpty, authorizedUntil > now,
              self.versionKey == nil || self.versionKey == versionKey else {
            invalidate()
            return .invalidated
        }
        let first = self.versionKey == nil
        self.versionKey = versionKey
        self.authorizedUntil = authorizedUntil
        return first ? .initial : .refreshed
    }

    public mutating func expire(now: Date = Date()) -> Bool {
        guard let authorizedUntil, now >= authorizedUntil else { return false }
        invalidate()
        return true
    }

    public mutating func invalidate() {
        generation &+= 1
        versionKey = nil
        authorizedUntil = nil
    }
}
