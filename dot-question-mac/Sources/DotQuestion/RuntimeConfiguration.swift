import Foundation

/// An explicit launch check uses an empty, temporary store and preferences.
/// It never reads or changes the user's existing study materials or settings.
enum RuntimeConfiguration {
    static let isSmokeTest = CommandLine.arguments.contains("--smoke-test")
    static let liveDirectory: URL? = {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              let index = CommandLine.arguments.firstIndex(of: "--ci-live-test"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    }()
    static var isLiveTest: Bool { liveDirectory != nil }
    static let smokeDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DotQuestion-Smoke-\(UUID().uuidString)", isDirectory: true)
    static let preferences: UserDefaults = (isSmokeTest || isLiveTest)
        ? UserDefaults(suiteName: "local.dot.question.smoke.\(UUID().uuidString)")!
        : .standard
    static var documentDirectory: URL? { (isSmokeTest || isLiveTest) ? smokeDirectory : nil }
}
