import Foundation
import os.log

enum LogCategory: String, CaseIterable {
    case general
    case download
    case server
    case transcription
    case model
    case tts
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let category: LogCategory
    let level: OSLogType
    let message: String

    var levelString: String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        default: return "LOG"
        }
    }
}

@MainActor
@Observable
final class TranscriptionLogger {
    static let shared = TranscriptionLogger()

    private let subsystem = "com.openwhisper.OpenWhisper"
    private var loggers: [LogCategory: Logger] = [:]
    private(set) var entries: [LogEntry] = []
    private let maxEntries = 1000

    private init() {
        for cat in LogCategory.allCases {
            loggers[cat] = Logger(subsystem: subsystem, category: cat.rawValue)
        }
    }

    func log(_ message: String, category: LogCategory = .general, level: OSLogType = .info) {
        let entry = LogEntry(timestamp: Date(), category: category, level: level, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        loggers[category]?.log(level: level, "\(message, privacy: .public)")
    }

    func debug(_ message: String, category: LogCategory = .general) {
        log(message, category: category, level: .debug)
    }

    func info(_ message: String, category: LogCategory = .general) {
        log(message, category: category, level: .info)
    }

    func error(_ message: String, category: LogCategory = .general) {
        log(message, category: category, level: .error)
    }

    func clearEntries() {
        entries.removeAll()
    }
}
