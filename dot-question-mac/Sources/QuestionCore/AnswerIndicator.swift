/// Answer encodings for the app's own menu item, never device telemetry.
public struct AnswerIndicator: Equatable {
    public let ordinal: Int
    public var wifiBars: Int? { ordinal <= 5 ? ordinal : nil }
    public var batteryPercent: Int { ordinal * 10 }

    public init?(choice: String?, options: [String]) {
        guard (2...10).contains(options.count), Set(options).count == options.count,
              let choice, let index = options.firstIndex(of: choice) else { return nil }
        ordinal = index + 1
    }
}

/// Retained state for the app's five-bar Wi-Fi-shaped indicator. No automatic expiry.
public enum WifiAnswerState: Equatable {
    case idle
    case pending
    case answer(AnswerIndicator)
    case unavailable

    public init(choice: String?, options: [String], uncertain: Bool = false) {
        guard !uncertain, let indicator = AnswerIndicator(choice: choice, options: options) else {
            self = .unavailable
            return
        }
        self = .answer(indicator)
    }

    public var filledBars: Int {
        guard case .answer(let indicator) = self else { return 0 }
        // Unsupported choices never saturate to five or replace the bars with text.
        return indicator.wifiBars ?? 0
    }
}
