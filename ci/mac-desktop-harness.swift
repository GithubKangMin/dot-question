// macOS 15+ only. Build with:
// xcrun swiftc -swift-version 5 -parse-as-library ci/mac-desktop-harness.swift \
//   -framework AppKit -framework ScreenCaptureKit -framework AVFoundation \
//   -o mac-desktop-harness
//
// The movie is a single, uninterrupted capture of the real display. The fixture
// is a real, separate AppKit window; the menu-bar icon belongs to DotQuestion.
// This program does not change permissions, request access, or render an answer.
import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

private struct HarnessError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Expected ordinals are test assertions only. They are never drawn, passed to
// DotQuestion, or included in a model prompt.
private struct QuestionFixture {
    let question: String
    let choices: [String]
    let expectedOrdinal: Int

    static let redPlanet = QuestionFixture(
        question: "Which planet is known as Red Planet?",
        choices: ["1. Venus", "2. Jupiter", "3. Mars", "4. Saturn", "5. Neptune"],
        expectedOrdinal: 3)
    static let sequence = [
        QuestionFixture(question: "Which number equals 2 + 2?",
                        choices: ["1. Three", "2. Four", "3. Five", "4. Six", "5. Seven"],
                        expectedOrdinal: 2),
        redPlanet,
        QuestionFixture(question: "Which animal is a mammal?",
                        choices: ["1. Trout", "2. Frog", "3. Lizard", "4. Eagle", "5. Dolphin"],
                        expectedOrdinal: 5)
    ]
}

private func permissionReport() -> [String: Any] {
    ["screenCaptureAllowed": CGPreflightScreenCaptureAccess(),
     "postEventAllowed": CGPreflightPostEventAccess(),
     "permissionsRequested": false,
     "securitySettingsChanged": false,
     "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString]
}

private func printJSON(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let string = String(data: data, encoding: .utf8) {
        print(string)
        fflush(stdout)
    }
}

@MainActor
private final class QuestionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class QuestionView: NSView {
    override var isOpaque: Bool { true }
    var question = ""
    var choices: [String] = []
    var questionNumber = 1
    var questionCount = 1
    var elapsedSeconds: TimeInterval = 0

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        let width = min(780.0, bounds.width - 64)
        let x = (bounds.width - width) / 2
        let top = bounds.midY + 170
        let questionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 31, weight: .semibold),
            .foregroundColor: NSColor.black]
        (question as NSString).draw(
            in: NSRect(x: x, y: top, width: width, height: 52),
            withAttributes: questionAttributes)
        let choiceAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black]
        for (index, choice) in choices.enumerated() {
            (choice as NSString).draw(
                at: NSPoint(x: x, y: top - 65 - CGFloat(index * 55)),
                withAttributes: choiceAttributes)
        }
        // This clock is ordinary live window content, captured by the same
        // display stream. Its changing pixels keep static waits visible in the
        // recording; no frames, time labels, or cuts are added after capture.
        let clock = String(format: "Question %d/%d   Elapsed %06.1fs", questionNumber, questionCount, elapsedSeconds)
        (clock as NSString).draw(
            at: NSPoint(x: max(16, bounds.width - 375), y: 16),
            withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .regular),
                             .foregroundColor: NSColor.darkGray])
    }
}

@available(macOS 15.0, *)
@MainActor
private final class DesktopHarness: NSObject, NSApplicationDelegate, SCStreamDelegate, SCRecordingOutputDelegate {
    private let directory: URL
    private let probeOnly: Bool
    private var fixture: QuestionWindow?
    private var fixtureView: QuestionView?
    private var clockTimer: Timer?
    private var currentQuestionNumber = 0
    private var stream: SCStream?
    private var recording: SCRecordingOutput?
    private var recordingStarted = false
    private var recordingFinished = false
    private var streamRunning = false
    private var asynchronousFailure: String?
    private var events: [[String: Any]] = []
    private let startTime = ProcessInfo.processInfo.systemUptime
    private var recordingStartTime: TimeInterval?
    private var shortcutPostTime: TimeInterval?
    private var resultTime: TimeInterval?
    private var captureDescription: [String: Any] = [:]
    private var result: [String: Any] = [:]
    private var questionResults: [[String: Any]] = []
    private var recordingStopTime: TimeInterval?
    private var watchdog: DispatchWorkItem?

    init(directory: URL, probeOnly: Bool) {
        self.directory = directory
        self.probeOnly = probeOnly
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Includes preparation and encoder finalization. Never wait indefinitely
        // for a permission dialog or an unavailable WindowServer.
        let watchdog = DispatchWorkItem { [weak self] in
            self?.failAndExit("Harness exceeded the 600-second safety deadline.")
        }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: watchdog)
        Task { @MainActor in
            do {
                try await self.run()
                self.watchdog?.cancel()
                self.clockTimer?.invalidate()
                self.fixture?.orderOut(nil)
                exit(0)
            } catch {
                // Preserve the actual partial recording when a test fails, if
                // the stream can still finalize. Never substitute fake frames.
                self.note("failure", ["message": error.localizedDescription])
                if self.streamRunning {
                    try? await self.stopRecording()
                }
                self.failAndExit(error.localizedDescription)
            }
        }
    }

    private func run() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let permissions = permissionReport()
        try saveJSON(permissions, as: "permissions.json")
        guard permissions["screenCaptureAllowed"] as? Bool == true,
              permissions["postEventAllowed"] as? Bool == true else {
            throw HarnessError(message: "Required Screen Recording or event-posting access is absent. No access request or settings change was attempted.")
        }
        // Reusing evidence from another invocation could falsely pass the test.
        for name in ["actual-desktop.mp4", "hotkey-received.txt", "live-start.json", "live-result.json", "harness-result.json"] {
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) else {
                throw HarnessError(message: "Refusing existing evidence file: \(name). Use a fresh output directory.")
            }
        }
        try await waitFor("production app-ready.json", seconds: 15) {
            FileManager.default.fileExists(atPath: self.directory.appendingPathComponent("app-ready.json").path)
        }
        let readyData = try Data(contentsOf: directory.appendingPathComponent("app-ready.json"))
        guard let ready = try JSONSerialization.jsonObject(with: readyData) as? [String: Any],
              ready["hotkeyStatus"] as? Int == 0,
              ready["screenCaptureAllowed"] as? Bool == true,
              ready["windowVisible"] as? Bool == false else {
            throw HarnessError(message: "The production app is not ready: global hotkey registration, screen permission, or hidden-window assertion failed. Inspect app-ready.json. No permission change was attempted.")
        }

        // App-scoped presentation hides the Dock only while this fixture is
        // active. Menu bar remains visible; no system preference is changed.
        NSApp.presentationOptions = [.hideDock]
        let displayID = CGMainDisplayID()
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }), screen.visibleFrame.width >= 900, screen.visibleFrame.height >= 680 else {
            throw HarnessError(message: "A visible desktop at least 900 by 680 points is required, so the live clock stays below the centered 900 by 600 OCR region.")
        }
        let window = QuestionWindow(contentRect: screen.visibleFrame, styleMask: .borderless,
                                    backing: .buffered, defer: false, screen: screen)
        window.title = "Synthetic question fixture"
        window.level = .normal
        window.backgroundColor = .white
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        let questions = probeOnly ? [QuestionFixture.redPlanet] : QuestionFixture.sequence
        let view = QuestionView(frame: NSRect(origin: .zero, size: screen.visibleFrame.size))
        view.question = questions[0].question
        view.choices = questions[0].choices
        view.questionCount = questions.count
        view.elapsedSeconds = elapsed
        window.contentView = view
        fixtureView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        fixture = window
        let clockTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let view = self.fixtureView else { return }
                view.elapsedSeconds = self.elapsed
                view.needsDisplay = true
                view.displayIfNeeded()
            }
        }
        self.clockTimer = clockTimer
        RunLoop.main.add(clockTimer, forMode: .common)
        window.contentView?.displayIfNeeded()
        let displayBounds = CGDisplayBounds(displayID)
        let point = CGPoint(x: displayBounds.minX + window.frame.midX - screen.frame.minX,
                            y: displayBounds.minY + screen.frame.maxY - window.frame.midY)
        // Real mouse movement puts the production cursor-region capture over
        // the question. It does not send clicks or call the app's action method.
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left) else {
            throw HarnessError(message: "Could not construct the pointer movement event.")
        }
        move.post(tap: .cghidEventTap)
        try await pause(1)

        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw HarnessError(message: "ScreenCaptureKit did not expose the main display.")
        }
        // No excluded windows, application filtering, crop, or fake menu bar.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = CGDisplayPixelsWide(displayID)
        configuration.height = CGDisplayPixelsHigh(displayID)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.captureDynamicRange = .SDR
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = directory.appendingPathComponent("actual-desktop.mp4")
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = .h264
        guard recordingConfiguration.availableOutputFileTypes.contains(.mp4),
              recordingConfiguration.availableVideoCodecTypes.contains(.h264) else {
            throw HarnessError(message: "This runner cannot record H.264 MP4 with ScreenCaptureKit.")
        }
        let recording = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.recording = recording
        self.stream = stream
        try stream.addRecordingOutput(recording)
        captureDescription = [
            "method": "ScreenCaptureKit SCStream with SCRecordingOutput",
            "displayID": displayID,
            "pixelWidth": configuration.width, "pixelHeight": configuration.height,
            "requestedFramesPerSecond": 30,
            "liveWindowClockUpdateSeconds": 0.5,
            "questionCount": questions.count,
            "fullDisplay": true, "excludedWindowCount": 0,
            "audioRecorded": false, "compositedAfterCapture": false,
            "fixtureWindowNumber": window.windowNumber,
            "fixtureWindowLevel": window.level.rawValue,
            "fixtureFramePoints": NSStringFromRect(window.frame),
            "pointerX": point.x, "pointerY": point.y]
        try saveJSON(captureDescription, as: "capture-context.json")
        note("fixture-visible")
        try await stream.startCapture()
        streamRunning = true
        try await waitFor("recording-start callback", seconds: 20) { self.recordingStarted }
        // The stream, fixture window, production app and model all stay alive
        // through this loop. Only the question's ordinary view content changes.
        for (index, question) in questions.enumerated() {
            currentQuestionNumber = index + 1
            let prefix = String(format: "question-%02d", currentQuestionNumber)
            for name in ["hotkey-received.txt", "live-start.json", "live-result.json"] {
                let file = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            }
            view.question = question.question
            view.choices = question.choices
            view.questionNumber = currentQuestionNumber
            view.elapsedSeconds = elapsed
            view.needsDisplay = true
            view.displayIfNeeded()
            let shownAt = elapsed
            note("question-shown", ["question": question.question])
            move.post(tap: .cghidEventTap)
            try await pause(index == 0 ? 5 : 1)
            let beforeName = probeOnly ? "before-shortcut.png" : "\(prefix)-before-shortcut.png"
            try await saveScreenshot(filter: filter, configuration: configuration, name: beforeName)

            // Both receipt and answer waits share one 180-second deadline.
            let deadline = ProcessInfo.processInfo.systemUptime + 180
            let postedAt = elapsed
            try await postShortcut()
            shortcutPostTime = postedAt
            note("global-shortcut-posted", ["key": "Control+Option+Command+R", "keyCode": 15,
                                            "transport": "CGEvent.post(cghidEventTap)"])
            try await waitFor("question \(currentQuestionNumber) real callback and reset", seconds: min(15, deadline - ProcessInfo.processInfo.systemUptime)) {
                FileManager.default.fileExists(atPath: self.directory.appendingPathComponent("hotkey-received.txt").path)
                    && FileManager.default.fileExists(atPath: self.directory.appendingPathComponent("live-start.json").path)
            }
            let start = try readJSON(named: "live-start.json")
            try saveJSON(start, as: "\(prefix)-start.json")
            guard start["ordinal"] as? Int == 0, start["windowVisible"] as? Bool == false else {
                throw HarnessError(message: "Question \(currentQuestionNumber) failed to reset the menu answer to ordinal 0 with the app window hidden.")
            }
            let resetAt = elapsed
            note("production-reset-observed", ["ordinal": 0, "windowVisible": false])
            try await pause(0.5)
            let waitingName = "\(prefix)-waiting.png"
            let finishedBeforeWaitingScreenshot = FileManager.default.fileExists(atPath: directory.appendingPathComponent("live-result.json").path)
            try await saveScreenshot(filter: filter, configuration: configuration, name: waitingName)
            note("waiting-state-captured", ["resultAlreadyAvailable": finishedBeforeWaitingScreenshot])
            try await waitFor("question \(currentQuestionNumber) live result", seconds: max(0, deadline - ProcessInfo.processInfo.systemUptime)) {
                FileManager.default.fileExists(atPath: self.directory.appendingPathComponent("live-result.json").path)
            }
            let result = try readJSON(named: "live-result.json")
            self.result = result
            let observedAt = elapsed
            resultTime = observedAt
            try saveJSON(result, as: "\(prefix)-result.json")
            let receipt = try Data(contentsOf: directory.appendingPathComponent("hotkey-received.txt"))
            guard !receipt.isEmpty else {
                throw HarnessError(message: "Question \(currentQuestionNumber) has an empty hotkey receipt.")
            }
            try receipt.write(to: directory.appendingPathComponent("\(prefix)-hotkey-received.txt"), options: .atomic)
            note("production-result-observed", ["ordinal": result["ordinal"] ?? NSNull(),
                                                 "successful": result["successful"] ?? NSNull()])
            // Hold every actual result for five real seconds before replacing
            // the question, including a wrong result that will fail the run.
            try await pause(probeOnly ? 3 : 5)
            let afterName = probeOnly ? "after-answer.png" : "\(prefix)-after-answer.png"
            try await saveScreenshot(filter: filter, configuration: configuration, name: afterName)
            let valid = result["windowVisible"] as? Bool == false
                && result["successful"] is Bool
                && (probeOnly || (result["successful"] as? Bool == true
                                 && result["ordinal"] as? Int == question.expectedOrdinal))
            let entry: [String: Any] = [
                "questionNumber": currentQuestionNumber,
                "question": question.question, "choices": question.choices,
                "expectedOrdinal": question.expectedOrdinal, "assertionsPassed": valid,
                "questionShownAtSeconds": shownAt, "shortcutPostedAtSeconds": postedAt,
                "resetObservedAtSeconds": resetAt, "resultObservedAtSeconds": observedAt,
                "resultHeldUntilSeconds": elapsed,
                "waitingScreenshotResultAlreadyAvailable": finishedBeforeWaitingScreenshot,
                "beforeScreenshot": beforeName, "waitingScreenshot": waitingName,
                "afterScreenshot": afterName, "productionStart": start,
                "productionResult": result]
            questionResults.append(entry)
            try saveJSON(["questions": questionResults], as: "question-results.json")
            guard valid else {
                let requirement = probeOnly ? "a Boolean successful field" : "successful true and ordinal \(question.expectedOrdinal)"
                throw HarnessError(message: "Question \(currentQuestionNumber) failed: require windowVisible false and \(requirement). Inspect \(prefix)-result.json and the uninterrupted movie.")
            }
            note("question-validated", ["expectedOrdinal": question.expectedOrdinal])
        }
        currentQuestionNumber = 0
        try await stopRecording()
        let file = directory.appendingPathComponent("actual-desktop.mp4")
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        // Validate the finalized container itself, not just a recorder counter.
        let asset = AVURLAsset(url: file)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard videoTracks.count == 1 else {
            throw HarnessError(message: "The finalized movie must contain one actual display video track.")
        }
        let videoSize = try await videoTracks[0].load(.naturalSize)
        let wallSeconds = (recordingStopTime ?? elapsed) - (recordingStartTime ?? elapsed)
        guard size > 1_000, duration.isFinite, duration >= (probeOnly ? 7 : 20),
              abs(duration - wallSeconds) <= 2 else {
            throw HarnessError(message: "The recording is missing, empty, too short, or disagrees with wall time (\(size) bytes, movie \(duration)s, wall \(wallSeconds)s).")
        }
        try saveJSON([
            "successful": true, "continuousActualDesktop": true,
            "mode": probeOnly ? "permission-and-hotkey-probe" : "three-live-model-answers",
            "modelAnswerRequired": !probeOnly,
            "questionCount": questions.count, "questions": questionResults,
            "movie": file.lastPathComponent, "movieBytes": size,
            "recordedSeconds": duration,
            "recordingWallSeconds": wallSeconds,
            "movieVideoWidth": videoSize.width, "movieVideoHeight": videoSize.height,
            "recordingStartedAtSeconds": recordingStartTime ?? -1,
            "shortcutPostedAtSeconds": shortcutPostTime ?? -1,
            "resultObservedAtSeconds": resultTime ?? -1,
            "productionResult": result, "capture": captureDescription,
            "events": events], as: "harness-result.json")
        printJSON(["successful": true, "probeOnly": probeOnly, "questionCount": questions.count,
                   "movie": file.path, "recordedSeconds": duration])
    }

    private func postShortcut() async throws {
        guard CGPreflightPostEventAccess() else {
            throw HarnessError(message: "Event-posting permission is absent; the shortcut was not sent.")
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 15, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 15, keyDown: false) else {
            throw HarnessError(message: "Could not construct global keyboard events.")
        }
        let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        // Always release R even if the sleep is cancelled. No event tap,
        // AppleScript, direct callback, or application-specific IPC is used.
        defer { up.post(tap: .cghidEventTap) }
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    private func saveScreenshot(filter: SCContentFilter, configuration: SCStreamConfiguration, name: String) async throws {
        // Captures the same actual desktop independently while the movie keeps
        // recording. These PNGs are evidence, never movie input frames.
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw HarnessError(message: "Could not encode desktop screenshot \(name).")
        }
        try png.write(to: directory.appendingPathComponent(name), options: .atomic)
        note("desktop-screenshot", ["file": name])
    }

    private func stopRecording() async throws {
        guard streamRunning, let stream else { return }
        streamRunning = false
        recordingStopTime = elapsed
        note("recording-stop-requested")
        try await stream.stopCapture()
        // stopCapture returning does not mean the output file has finalized.
        try await waitFor("recording-finish callback", seconds: 20, checkFailure: false) { self.recordingFinished }
        if let failure = asynchronousFailure { throw HarnessError(message: failure) }
    }

    private func pause(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if let failure = asynchronousFailure { throw HarnessError(message: failure) }
    }

    private func waitFor(_ description: String, seconds: TimeInterval, checkFailure: Bool = true,
                         condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            if checkFailure, let failure = asynchronousFailure { throw HarnessError(message: failure) }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw HarnessError(message: "Timed out waiting for \(description).")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private var elapsed: TimeInterval { ProcessInfo.processInfo.systemUptime - startTime }

    private func note(_ event: String, _ fields: [String: Any] = [:]) {
        var value = fields
        value["event"] = event
        value["elapsedSeconds"] = elapsed
        if currentQuestionNumber > 0 { value["questionNumber"] = currentQuestionNumber }
        events.append(value)
        printJSON(value)
        try? saveJSON(["events": events], as: "harness-events.json")
    }

    private func saveJSON(_ value: [String: Any], as name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func readJSON(named name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarnessError(message: "Production \(name) is not a JSON object.")
        }
        return value
    }

    private func failAndExit(_ message: String) {
        watchdog?.cancel()
        clockTimer?.invalidate()
        try? saveJSON(["successful": false, "error": message, "events": events,
                       "capture": captureDescription, "productionResult": result,
                       "questions": questionResults], as: "harness-result.json")
        fputs("DESKTOP HARNESS FAILED: \(message)\n", stderr)
        fflush(stderr)
        fixture?.orderOut(nil)
        exit(1)
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recordingStarted = true
            self.recordingStartTime = self.elapsed
            self.note("recording-started")
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            self?.recordingFinished = true
            self?.note("recording-finished")
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.asynchronousFailure = "ScreenCaptureKit recording error: \(message)"
            self?.note("recording-error", ["message": message])
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.asynchronousFailure = "ScreenCaptureKit stream error: \(message)"
            self?.note("stream-error", ["message": message])
        }
    }
}

@main
private struct Main {
    @MainActor
    static func main() {
        guard #available(macOS 15.0, *) else {
            fputs("This harness requires macOS 15 or newer.\n", stderr)
            exit(2)
        }
        if CommandLine.arguments == [CommandLine.arguments[0], "--preflight"] {
            let report = permissionReport()
            printJSON(report)
            exit(report["screenCaptureAllowed"] as? Bool == true && report["postEventAllowed"] as? Bool == true ? 0 : 3)
        }
        guard CommandLine.arguments.count == 3, ["--record", "--probe"].contains(CommandLine.arguments[1]) else {
            fputs("Usage: mac-desktop-harness --preflight | --record OUTPUT_DIRECTORY | --probe OUTPUT_DIRECTORY\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = DesktopHarness(directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
                                      probeOnly: CommandLine.arguments[1] == "--probe")
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
