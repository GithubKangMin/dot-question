/// UI policy for a request, fixed at capture/send time, independent of later settings.
public enum RequestOrigin: Equatable {
    case manual
    case quick

    public var shouldRevealWindow: Bool { self == .manual }
    public func allowsAutomaticSend(usingAPI: Bool) -> Bool {
        self == .quick && !usingAPI
    }
}
