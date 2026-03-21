import Foundation

struct CouncilConfig: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var memberProviderIDs: [String]
    var chairmanProviderID: String
    var reviewAnonymized: Bool
    var timeoutSeconds: TimeInterval
    var costWarningThreshold: Double?

    init(
        id: UUID = UUID(),
        name: String,
        memberProviderIDs: [String],
        chairmanProviderID: String,
        reviewAnonymized: Bool = true,
        timeoutSeconds: TimeInterval = 60,
        costWarningThreshold: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.memberProviderIDs = memberProviderIDs
        self.chairmanProviderID = chairmanProviderID
        self.reviewAnonymized = reviewAnonymized
        self.timeoutSeconds = timeoutSeconds
        self.costWarningThreshold = costWarningThreshold
    }
}
