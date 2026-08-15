import Foundation

/// The routing decision for a transcript. This mirrors the JSON contract used by
/// the existing `plaud-sorter` (`classify-sort.py`) verbatim so the downstream
/// vault stays consistent and the two systems are interchangeable:
///
/// ```json
/// {"destination": "Cases/Acme/transcripts/", "primary_case": "Acme",
///  "confidence": 0.9, "note": "kickoff call"}
/// ```
///
/// `destination` is always constrained by the caller to an allowlist of active
/// case folders plus `transcripts/` and `personal/Plaud/`.
public struct RoutingDecision: Codable, Equatable, Sendable {
    public var destination: String
    public var primaryCase: String?
    public var confidence: Double?
    public var note: String?

    public init(
        destination: String,
        primaryCase: String? = nil,
        confidence: Double? = nil,
        note: String? = nil
    ) {
        self.destination = destination
        self.primaryCase = primaryCase
        self.confidence = confidence
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case destination
        case primaryCase = "primary_case"
        case confidence
        case note
    }
}
