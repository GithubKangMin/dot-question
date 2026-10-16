import Foundation

/// An explicit launch check uses an empty, temporary store and preferences.
/// It never reads or changes the user's existing study materials or settings.
enum RuntimeConfiguration {
    static let isSmokeTest = CommandLine.arguments.contains("--smoke-test")
    static let smokeDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DotQuestion-Smoke-\(UUID().uuidString)", isDirectory: true)
    static let preferences: UserDefaults = isSmokeTest
        ? UserDefaults(suiteName: "local.dot.question.smoke.\(UUID().uuidString)")!
        : .standard
    static var documentDirectory: URL? { isSmokeTest ? smokeDirectory : nil }
}
