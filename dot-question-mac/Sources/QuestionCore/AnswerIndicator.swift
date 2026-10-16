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
