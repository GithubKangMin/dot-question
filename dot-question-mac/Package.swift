// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "DotQuestion", platforms: [.macOS(.v13)],
    products: [.executable(name: "DotQuestion", targets: ["DotQuestion"])],
    targets: [
        .target(name: "QuestionCore"),
        .executableTarget(name: "DotQuestion", dependencies: ["QuestionCore"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Vision"), .linkedFramework("Carbon"), .linkedFramework("PDFKit")]),
        .testTarget(name: "QuestionCoreTests", dependencies: ["QuestionCore"]),
        .testTarget(name: "DotQuestionTests", dependencies: ["DotQuestion", "QuestionCore"])
    ]
)
