import Foundation

struct DictionaryEntry: Codable, Identifiable {
    let id: UUID
    var spelling: String
    var audioFilename: String?
    var phoneticAnnotation: String?
    var phoneticMethod: PhoneticMethod?
    var contextDescription: String?
    var soundexCode: String
    var metaphoneCode: String
    var tags: [String]
    var usageCount: Int
    var lastUsedDate: Date?
    var appContexts: [String]
    var createdDate: Date
    var tierOverride: TierOverride?

    init(
        id: UUID = UUID(),
        spelling: String,
        audioFilename: String? = nil,
        phoneticAnnotation: String? = nil,
        phoneticMethod: PhoneticMethod? = nil,
        contextDescription: String? = nil,
        tags: [String] = [],
        tierOverride: TierOverride? = nil
    ) {
        self.id = id
        self.spelling = spelling
        self.audioFilename = audioFilename
        self.phoneticAnnotation = phoneticAnnotation
        self.phoneticMethod = phoneticMethod
        self.contextDescription = contextDescription
        self.soundexCode = PhoneticEngine.soundex(spelling)
        self.metaphoneCode = PhoneticEngine.metaphone(spelling)
        self.tags = tags
        self.usageCount = 0
        self.lastUsedDate = nil
        self.appContexts = []
        self.createdDate = Date()
        self.tierOverride = tierOverride
    }

    mutating func recomputePhoneticCodes() {
        soundexCode = PhoneticEngine.soundex(spelling)
        metaphoneCode = PhoneticEngine.metaphone(spelling)
    }
}

enum PhoneticMethod: String, Codable, CaseIterable {
    case regular
    case nato
    case ipa

    var displayName: String {
        switch self {
        case .regular: return "Regular Alphabet"
        case .nato: return "NATO Alphabet"
        case .ipa: return "IPA"
        }
    }
}

enum TierOverride: String, Codable, CaseIterable {
    case alwaysActive
    case postProcessOnly

    var displayName: String {
        switch self {
        case .alwaysActive: return "Always Active (Tier 1)"
        case .postProcessOnly: return "Post-Processing Only (Tier 3)"
        }
    }
}

enum ActivationTier: String {
    case tier1
    case tier2
    case tier3

    var displayName: String {
        switch self {
        case .tier1: return "Tier 1"
        case .tier2: return "Tier 2"
        case .tier3: return "Tier 3"
        }
    }
}
