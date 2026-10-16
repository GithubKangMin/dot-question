import AppKit
import CoreGraphics
import Carbon
import UniformTypeIdentifiers
import QuestionCore

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Used only by --smoke-test screenshot evidence; uses the production icon renderers.
private final class SmokeIconPreviewView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black]
        ("앱 아이콘 렌더링 · 시스템 메뉴바 캡처 아님" as NSString)
            .draw(at: NSPoint(x: 20, y: 143), withAttributes: attributes)
        let icons: [(String, NSImage)] = [
            ("Wi-Fi형 · 보기 2", AnswerStatusIcon.wifi(bars: 2)),
            ("배터리형 · 보기 2", AnswerStatusIcon.battery(percent: 20)),
            ("고양이 · 활성 프레임", CharacterStatusIcon.image(style: .cat, active: true)),
            ("피카츄 · 활성 프레임", CharacterStatusIcon.image(style: .pikachu, active: true))]
        for (index, entry) in icons.enumerated() {
            let x = CGFloat(index * 185 + 20)
            entry.1.draw(in: NSRect(x: x + 35, y: 55, width: entry.1.size.width * 2,
                                   height: entry.1.size.height * 2))
            (entry.0 as NSString).draw(at: NSPoint(x: x, y: 24), withAttributes: attributes)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var hotKey: HotKey?
    private let capture = ScreenshotService()
    private let client = OllamaClient()
    private let apiClient = OpenAIClient()
    private let provider = NSPopUpButton(frame: .zero, pullsDown: false)
    private let apiKey = NSSecureTextField(string: "")
    private let apiModel = NSTextField(string: RuntimeConfiguration.preferences.string(forKey: "apiModel") ?? "gpt-4.1-mini")
    private let privacy = NSTextField(wrappingLabelWithString: "")
    private var settingsRow: NSStackView!
    private var apiRow: NSStackView!
    private let question = NSTextView()
    private let answer = NSTextView()
    private let endpoint = NSTextField(string: RuntimeConfiguration.preferences.string(forKey: "endpoint") ?? "http://127.0.0.1:11434")
    private let model = NSTextField(string: RuntimeConfiguration.preferences.string(forKey: "model") ?? "qwen3:4b-instruct")
    private let status = NSTextField(wrappingLabelWithString: "영역을 캡처하거나 질문을 입력하세요. 전송 버튼을 눌러야 AI에 전달됩니다.")
    private var captureButton: NSButton!
    private var sendButton: NSButton!
    private var cancelButton: NSButton!
    private var apiConfirmationOpen = false
    private var settingsPanel: NSStackView!
    private var busy = false
    private var generation = 0
    private var activeCapture = false
    private var captureCancelled = false
    private var closingWindow = false
    private var requestOrigin: RequestOrigin = .manual
    private let quickMode = NSButton(checkboxWithTitle: "로컬 빠른 모드 · 단축키 → 커서 OCR → 자동 풀이 (창 안 열기)", target: nil, action: nil)
    private var lastExternalApplication: NSRunningApplication?
    private var menuMessage: String?
    private let menuStatus = NSMenuItem(title: "대기 중 · 아직 답 없음", action: nil, keyEquivalent: "")

    private let documents = DocumentStore(directory: RuntimeConfiguration.documentDirectory)
    private let documentList = NSPopUpButton(frame: .zero, pullsDown: false)
    private let documentStatus = NSTextField(wrappingLabelWithString: "자료 없음 · PDF/TXT/MD를 가져오세요")
    private var importButton: NSButton!
    private var removeDocumentButton: NSButton!
    private let groundedOnly = NSButton(checkboxWithTitle: "자료 근거 모드 (관련 자료 없으면 전송 안 함)", target: nil, action: nil)
    private let cursorMode = NSButton(checkboxWithTitle: "커서 중심 캡처", target: nil, action: nil)
    private let captureWidth = NSTextField(string: "900")
    private let captureHeight = NSTextField(string: "600")
    private let shortcut = NSPopUpButton(frame: .zero, pullsDown: false)
    private let armedEnter = NSButton(checkboxWithTitle: "단축키 → Enter 준비 (10초)", target: nil, action: nil)
    private let autoCopy = NSButton(checkboxWithTitle: "완료 시 자동 복사 (기존 클립보드 덮어씀)", target: nil, action: nil)
    private let menuAnswer = NSButton(checkboxWithTitle: "메뉴 막대에 선택 답 표시", target: nil, action: nil)
    private let menuStyle = NSPopUpButton(frame: .zero, pullsDown: false)
    private var lastOptions: [String] = []
    private var wifiAnswerState: WifiAnswerState = .idle
    private let characterStyle = NSPopUpButton(frame: .zero, pullsDown: false)
    private let reduceMotion = NSButton(checkboxWithTitle: "움직임 줄이기 (정적 번호 표시)", target: nil, action: nil)
    private var armedReturnKey: HotKey?
    private var armedEscapeKey: HotKey?
    private var armTimer: Timer?
    private var importing = false
    private var animationTimer: Timer?
    private var lastChoice: String?
    private var animationStep = 0
    private var animationCount = 0
    private var lastCaptureRect: CGRect?

    func applicationDidFinishLaunching(_ notification: Notification) {
        rememberExternalApplication()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSApp.setActivationPolicy(.accessory)
        RuntimeConfiguration.preferences.register(defaults: ["menuAnswer": true, "quickMode": false])
        if RuntimeConfiguration.isLiveTest {
            RuntimeConfiguration.preferences.set(true, forKey: "quickMode")
            RuntimeConfiguration.preferences.set(1, forKey: "menuStyle")
            RuntimeConfiguration.preferences.set("qwen2.5:7b", forKey: "model")
            model.stringValue = "qwen2.5:7b"
        }
        buildWindow()
        statusItem = NSStatusBar.system.statusItem(withLength: usesPersistentWifi ? AnswerStatusIcon.wifiStatusItemLength : NSStatusItem.variableLength)
        renderMenuAnswer()
        let menu = NSMenu()
        let open = NSMenuItem(title: "질문 창 열기", action: #selector(showWindow), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        let captureItem = NSMenuItem(title: "캡처 (설정한 모드)", action: #selector(captureRegion), keyEquivalent: "")
        captureItem.target = self; menu.addItem(captureItem)
        menuStatus.isEnabled = false; menu.addItem(menuStatus)
        let cancel = NSMenuItem(title: "진행 중 작업 취소", action: #selector(cancelWork), keyEquivalent: "")
        cancel.target = self; menu.addItem(cancel)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        if !RuntimeConfiguration.isSmokeTest {
            hotKey = HotKey { [weak self] in self?.shortcutTriggered() }
        }
        let code = hotKey?.register(keyCode: shortcutKeyCode) ?? 0
        if code != 0 { status.stringValue = "단축키 등록 실패 (\(code)). 메뉴의 영역 캡처를 이용하세요." }
        if RuntimeConfiguration.isLiveTest {
            let ready: [String: Any] = ["hotkeyStatus": code, "screenCaptureAllowed": CGPreflightScreenCaptureAccess(),
                                        "windowVisible": window.isVisible, "model": model.stringValue,
                                        "wifiFilledBars": wifiAnswerState.filledBars, "persistentWifi": usesPersistentWifi,
                                        "statusItemWidth": statusItem.length, "menuTitle": statusItem.button?.title ?? ""]
            writeLiveEvidence(ready, filename: "app-ready.json")
        }
        if let error = documents.loadError { documentStatus.stringValue = error }
        refreshDocuments()
        if quickMode.state != .on || RuntimeConfiguration.isSmokeTest { showWindow() }
        if RuntimeConfiguration.isSmokeTest {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.window.contentView?.layoutSubtreeIfNeeded()
                print("SMOKE: window=\(self.window.isVisible), title=\(self.window.title), menu=\(self.statusItem.button?.title ?? "missing"), documents=\(self.documents.documents.count)")
                print("SMOKE: isolated preferences/store; global shortcut, capture, clipboard and network unused")
                fflush(stdout)
                if let index = CommandLine.arguments.firstIndex(of: "--smoke-image"),
                   CommandLine.arguments.indices.contains(index + 1),
                   let view = self.window.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    }
                }
                if let index = CommandLine.arguments.firstIndex(of: "--screenshots-dir") {
                    do {
                        guard CommandLine.arguments.indices.contains(index + 1) else {
                            throw AppError(message: "--screenshots-dir requires a path")
                        }
                        try self.saveSmokeScreenshots(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    } catch {
                        fputs("SCREENSHOT ERROR: \(error)\n", stderr)
                        exit(1)
                    }
                }
                try? FileManager.default.removeItem(at: RuntimeConfiguration.smokeDirectory)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }
    /// Captures the running app's real AppKit views using synthetic local fixtures.
    /// This is app-view rendering, not a whole-desktop or OS-menu-bar capture.
    private func saveSmokeScreenshots(to directory: URL) throws {
        precondition(RuntimeConfiguration.isSmokeTest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = RuntimeConfiguration.smokeDirectory.appendingPathComponent("CI-synthetic-study.txt")
        try "광합성은 빛 에너지를 이용해 이산화탄소와 물로 포도당과 산소를 만듭니다.".write(to: fixture, atomically: true, encoding: .utf8)
        try documents.importDocument(fixture)
        refreshDocuments()
        question.string = "[CI 합성 질문] 광합성에 필요한 에너지는?\n1. 소리\n2. 빛\n3. 바람"
        let sources = documents.retrieve(query: question.string)
        let prepared = try StudyPromptBuilder.build(question: question.string, sources: sources, requiresSources: true)
        let payload: [String: Any] = ["selected_choice": "2", "answer": "빛 에너지", "explanation": "합성 자료에서 광합성은 빛 에너지를 이용한다고 설명합니다. (CI 고정 응답, 실제 AI 호출 아님)", "citations": sources.map { $0.id }, "uncertainty": NSNull()]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let result = try StructuredAnswerParser.parse(String(decoding: data, as: UTF8.self), question: prepared.question, sources: sources)
        answer.string = result.formattedText
        groundedOnly.state = .on
        lastChoice = result.selectedChoice
        lastOptions = prepared.question.choices.map { $0.label }
        wifiAnswerState = WifiAnswerState(choice: lastChoice, options: lastOptions)
        menuAnswer.state = .on
        renderMenuAnswer()
        status.stringValue = "CI 합성 자료 · 고정 응답 검증 완료 · 네트워크/API 호출 없음"
        // Capture only the laid-out viewport. Caching the whole scroll document
        // includes clipped/offscreen regions which AppKit may leave transparent.
        func save(_ view: NSView, _ filename: String) throws {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw AppError(message: "Cannot render \(filename)")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            // Reject blank/mostly transparent renders; PNG byte size is not evidence.
            var visible = 0, ink = 0, samples = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                    samples += 1
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          color.alphaComponent > 0.9 else { continue }
                    visible += 1
                    if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.7 { ink += 1 }
                }
            }
            guard samples > 0, visible > samples * 9 / 10, ink > samples / 500 else {
                throw AppError(message: "Blank or clipped render \(filename): visible=\(visible)/\(samples), ink=\(ink)")
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw AppError(message: "Cannot encode \(filename)")
            }
            try png.write(to: directory.appendingPathComponent(filename))
            print("SCREENSHOT PIXELS: \(filename) visible=\(visible)/\(samples), ink=\(ink)")
        }
        guard let content = window.contentView,
              let scroll = content.subviews.first as? NSScrollView else {
            throw AppError(message: "Missing app viewport")
        }
        // Deterministic light appearance makes both text and template icon evidence legible.
        window.appearance = NSAppearance(named: .aqua)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        guard let settingsToggle = (settingsPanel.superview as? NSStackView)?.arrangedSubviews
            .compactMap({ $0 as? NSButton }).first(where: { $0.action == #selector(toggleSettings(_:)) }) else {
            throw AppError(message: "Missing settings control")
        }
        settingsToggle.state = .on
        settingsPanel.isHidden = false
        content.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try save(content, "macos-settings-window-app-view.png")
        settingsToggle.state = .off
        settingsPanel.isHidden = true
        content.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        answer.scrollRangeToVisible(NSRange(location: 0, length: 0))
        try save(content, "macos-answer-window-app-view.png")

        // A real application-owned preview, never a fabricated OS menu bar.
        let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 180),
                               styleMask: [.titled], backing: .buffered, defer: false)
        preview.isReleasedWhenClosed = false
        preview.appearance = NSAppearance(named: .aqua)
        preview.contentView = SmokeIconPreviewView(frame: NSRect(x: 0, y: 0, width: 760, height: 180))
        preview.orderFront(nil)
        defer { preview.orderOut(nil) }
        try save(preview.contentView!, "macos-app-icon-preview.png")
        try "Real AppKit visible window view renders: settings expanded and compact question/answer. Synthetic imported source and validated fixed response, not a live AI result. Icon panel draws the existing app icon implementations; it is not an OS menu-bar capture or proof of placement. Pixel assertions reject blank/transparent artifacts. No OCR, live model, API, clipboard or global shortcut operation.\n".write(to: directory.appendingPathComponent("capture-context.txt"), atomically: true, encoding: .utf8)
        print("SCREENSHOTS: saved real AppKit views to \(directory.path)")
    }
    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: min(820, (NSScreen.main?.visibleFrame.height ?? 900) - 80)), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "dot question · 학습 도우미"
        window.minSize = NSSize(width: 760, height: 580)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        let outerScroll = NSScrollView(frame: window.contentView!.bounds)
        outerScroll.autoresizingMask = [.width, .height]
        outerScroll.hasVerticalScroller = true
        let content = FlippedDocumentView()
        content.translatesAutoresizingMaskIntoConstraints = false
        outerScroll.documentView = content
        window.contentView!.addSubview(outerScroll)
        content.addSubview(root)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: outerScroll.contentView.widthAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        outerScroll.contentView.scroll(to: .zero)
        let title = NSTextField(labelWithString: "화면 속 질문, 이해할 수 있는 풀이로")
        title.font = .systemFont(ofSize: 23, weight: .bold)
        root.addArrangedSubview(title)
        let intro = NSTextField(wrappingLabelWithString: "⌃⌥⌘R → 영역 선택 → OCR 확인·수정 → AI로 전송\n창은 일반 앱처럼 보이며 화면 공유에도 나타날 수 있습니다.")
        intro.textColor = .secondaryLabelColor; root.addArrangedSubview(intro)
        let settingsToggle = NSButton(checkboxWithTitle: "설정 펼치기 · 모델 / 자료 / 캡처 / 답 표시", target: self, action: #selector(toggleSettings(_:)))
        root.addArrangedSubview(settingsToggle)
        settingsPanel = NSStackView()
        settingsPanel.orientation = .vertical; settingsPanel.alignment = .leading; settingsPanel.spacing = 8
        root.addArrangedSubview(settingsPanel)
        settingsPanel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        settingsPanel.isHidden = true
        provider.addItems(withTitles: ["로컬 · Ollama", "API · OpenAI (유료)"])
        provider.target = self; provider.action = #selector(providerChanged)
        settingsPanel.addArrangedSubview(provider)
        let settings = NSStackView(views: [NSTextField(labelWithString: "서버"), endpoint, NSTextField(labelWithString: "모델"), model])
        settingsRow = settings
        settings.spacing = 8; settingsPanel.addArrangedSubview(settings)
        endpoint.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        model.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        settings.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        apiKey.placeholderString = "API 키 · 메모리에만 유지"
        let clearKey = NSButton(title: "키 지우기", target: self, action: #selector(clearAPIKey))
        apiRow = NSStackView(views: [NSTextField(labelWithString: "API 모델"), apiModel, apiKey, clearKey])
        apiRow.spacing = 8
        apiModel.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        apiKey.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        settingsPanel.addArrangedSubview(apiRow)
        apiRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        privacy.font = .systemFont(ofSize: 12); privacy.textColor = .secondaryLabelColor
        settingsPanel.addArrangedSubview(privacy)
        privacy.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        importButton = NSButton(title: "자료 가져오기", target: self, action: #selector(importDocuments))
        removeDocumentButton = NSButton(title: "선택 자료 삭제", target: self, action: #selector(removeDocument))
        let docsRow = NSStackView(views: [importButton, documentList, removeDocumentButton, groundedOnly]); docsRow.spacing = 8
        documentList.widthAnchor.constraint(equalToConstant: 220).isActive = true
        settingsPanel.addArrangedSubview(docsRow)
        documentStatus.font = .systemFont(ofSize: 11); settingsPanel.addArrangedSubview(documentStatus)
        documentStatus.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        shortcut.addItems(withTitles: ["⌃⌥⌘R", "⌃⌥⌘Space", "⌃⌥⌘Enter"])
        shortcut.selectItem(at: min(2, max(0, RuntimeConfiguration.preferences.integer(forKey: "shortcut"))))
        shortcut.target = self; shortcut.action = #selector(shortcutChanged)
        captureWidth.widthAnchor.constraint(equalToConstant: 60).isActive = true
        captureHeight.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let captureSettings = NSStackView(views: [cursorMode, captureWidth, NSTextField(labelWithString: "×"), captureHeight, NSTextField(labelWithString: "pt"), shortcut, armedEnter]); captureSettings.spacing = 6
        settingsPanel.addArrangedSubview(captureSettings)
        quickMode.state = RuntimeConfiguration.preferences.bool(forKey: "quickMode") ? .on : .off
        quickMode.target = self; quickMode.action = #selector(quickModeChanged)
        settingsPanel.addArrangedSubview(quickMode)
        settingsPanel.addArrangedSubview(NSTextField(wrappingLabelWithString: "빠른 모드는 로컬 Ollama만 사용합니다. 화면 기록 권한은 미리 허용하세요. API는 자동 전송하지 않습니다. 메뉴의 질문 창 열기로 설정·오류를 확인하세요."))
        menuStyle.addItems(withTitles: ["숫자", "Wi-Fi형 막대 (1–5)", "배터리형 (번호 × 10%)"])
        menuStyle.target = self; menuStyle.action = #selector(outputModeChanged)
        let outputSettings = NSStackView(views: [autoCopy, menuAnswer]); outputSettings.spacing = 8
        settingsPanel.addArrangedSubview(outputSettings)
        settingsPanel.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "메뉴 답 표시 모양"), menuStyle]))
        settingsPanel.addArrangedSubview(NSTextField(wrappingLabelWithString: "앱 자체 답 표시입니다. 실제 Wi-Fi/배터리 상태가 아닙니다. Wi-Fi형은 항상 같은 5칸: 대기·처리·오류는 0칸, 보기 순서 1–5는 해당 칸을 채워 다음 명령까지 유지합니다. 6–10은 0칸과 메뉴 상세로 표시합니다. 배터리형은 1–10 → 10–100%."))
        characterStyle.addItems(withTitles: ["캐릭터 끄기", "고양이 · 꼬리 흔들기", "피카츄 · 전기 펄스"])
        characterStyle.target = self; characterStyle.action = #selector(outputModeChanged)
        reduceMotion.target = self; reduceMotion.action = #selector(outputModeChanged)
        settingsPanel.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "메뉴 캐릭터"), characterStyle, reduceMotion]))
        settingsPanel.addArrangedSubview(NSTextField(wrappingLabelWithString: "검증된 보기 순서만큼 초당 1회, 최대 10회 움직인 뒤 선택한 메뉴 답 모양으로 복원됩니다. Wi-Fi형에서는 막대를 유지하며 캐릭터로 바꾸지 않습니다. 다른 모양의 메뉴 답 끄기 상태에서는 캐릭터와 번호를 유지합니다. 시스템 동작 줄이기도 따릅니다."))
        for checkbox in [menuAnswer] { checkbox.target = self; checkbox.action = #selector(outputModeChanged) }
        settingsPanel.addArrangedSubview(NSTextField(labelWithString: "Enter 준비를 켜면 단축키 후 10초 동안 Return을 캡처용으로 사용합니다. Esc로 해제. 표시는 화면 공유에 보일 수 있습니다."))
        root.addArrangedSubview(NSTextField(labelWithString: "질문 · OCR은 오인식할 수 있어요"))
        question.delegate = self
        let qScroll = textScroll(question, editable: true)
        root.addArrangedSubview(qScroll)
        qScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        qScroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        captureButton = NSButton(title: "영역 캡처", target: self, action: #selector(captureRegion))
        sendButton = NSButton(title: "로컬 AI로 전송", target: self, action: #selector(sendQuestion))
        sendButton.bezelColor = .systemIndigo
        cancelButton = NSButton(title: "취소", target: self, action: #selector(cancelWork))
        cancelButton.isEnabled = false
        let clear = NSButton(title: "내용 지우기", target: self, action: #selector(clearContent))
        let copy = NSButton(title: "답변 복사", target: self, action: #selector(copyAnswer))
        let buttons = NSStackView(views: [captureButton, sendButton, cancelButton, clear, copy]); buttons.spacing = 8
        root.addArrangedSubview(buttons)
        root.addArrangedSubview(status)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        root.addArrangedSubview(NSTextField(labelWithString: "답변 / 풀이 · AI 답변은 직접 확인하세요"))
        let aScroll = textScroll(answer, editable: false)
        root.addArrangedSubview(aScroll)
        aScroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        aScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        aScroll.heightAnchor.constraint(equalTo: qScroll.heightAnchor, multiplier: 1.25).isActive = true
        menuAnswer.state = RuntimeConfiguration.preferences.bool(forKey: "menuAnswer") ? .on : .off
        menuStyle.selectItem(at: max(0, min(2, RuntimeConfiguration.preferences.integer(forKey: "menuStyle"))))
        characterStyle.selectItem(at: max(0, min(2, RuntimeConfiguration.preferences.integer(forKey: "characterStyle"))))
        reduceMotion.state = RuntimeConfiguration.preferences.bool(forKey: "reduceMotion") ? .on : .off
        providerChanged()
        window.center()
    }
    private func textScroll(_ view: NSTextView, editable: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        view.isEditable = editable; view.isSelectable = true; view.isRichText = false
        view.font = .systemFont(ofSize: 15)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 170)
        view.minSize = NSSize(width: 0, height: 170)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }
    private func rememberExternalApplication() {
        if let application = NSWorkspace.shared.frontmostApplication,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApplication = application
        }
    }
    @objc private func applicationActivated(_ notification: Notification) { rememberExternalApplication() }
    private func hideForCapture() {
        rememberExternalApplication()
        let wasFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        window.orderOut(nil)
        if wasFrontmost, let previous = lastExternalApplication, !previous.isTerminated {
            previous.activate(options: [.activateIgnoringOtherApps])
        }
    }
    @objc private func showWindow() {
        closingWindow = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    private func setBusy(_ value: Bool) {
        busy = value; captureButton.isEnabled = !value; sendButton.isEnabled = !value
        cancelButton.isEnabled = value; endpoint.isEnabled = !value; model.isEnabled = !value
        provider.isEnabled = !value; apiKey.isEnabled = !value; apiModel.isEnabled = !value
        importButton.isEnabled = !value; removeDocumentButton.isEnabled = !value
        documentList.isEnabled = !value; groundedOnly.isEnabled = !value
        cursorMode.isEnabled = !value; captureWidth.isEnabled = !value; captureHeight.isEnabled = !value
        question.isEditable = !value; armedEnter.isEnabled = !value; quickMode.isEnabled = !value
    }
    @objc private func captureRegion() { beginCapture(origin: .manual) }
    private func beginCapture(origin: RequestOrigin) {
        disarmReturn()
        guard NSApp.modalWindow == nil else { NSSound.beep(); return }
        guard !busy else { NSSound.beep(); return }
        requestOrigin = origin
        resetOutput(wifiState: .pending)
        if RuntimeConfiguration.isLiveTest {
            writeLiveEvidence(["ordinal": AnswerIndicator(choice: lastChoice, options: lastOptions)?.ordinal ?? 0,
                               "wifiFilledBars": wifiAnswerState.filledBars, "persistentWifi": usesPersistentWifi,
                               "statusItemWidth": statusItem.length, "menuTitle": statusItem.button?.title ?? "",
                               "windowVisible": window.isVisible, "phase": "capture-started-after-output-reset"],
                              filename: "live-start.json")
        }
        if origin == .quick {
            hideForCapture()
            guard origin.allowsAutomaticSend(usingAPI: provider.indexOfSelectedItem == 1) else {
                finish("빠른 모드는 로컬 Ollama 전용입니다. 질문 창에서 로컬 공급자를 선택하세요."); return
            }
        }
        guard CGPreflightScreenCaptureAccess() else {
            if origin != .quick { _ = CGRequestScreenCaptureAccess() }
            finish("시스템 설정 → 개인정보 보호 및 보안 → 화면 기록에서 허용한 뒤 앱을 다시 실행하세요."); return
        }
        lastCaptureRect = nil
        if origin == .quick || cursorMode.state == .on {
            guard let width = Double(captureWidth.stringValue), let height = Double(captureHeight.stringValue),
                  width.isFinite, height.isFinite, (100...4000).contains(width), (100...4000).contains(height),
                  let point = CGEvent(source: nil)?.location else {
                finish("캡처 크기는 100–4000 pt 사이 숫자로 입력하세요."); return
            }
            let display = NSScreen.screens.compactMap { screen -> CGRect? in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                return CGDisplayBounds(CGDirectDisplayID(id.uint32Value))
            }.first(where: { $0.contains(point) })
            guard let display else { finish("커서의 화면을 찾지 못했습니다."); return }
            lastCaptureRect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height).intersection(display).integral
        }
        closingWindow = false
        generation += 1; let token = generation
        activeCapture = true; captureCancelled = false
        setBusy(true); status.stringValue = lastCaptureRect == nil ? "영역을 드래그하세요. Esc로 캡처 취소." : "커서 주변을 캡처합니다…"
        hideForCapture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.generation == token else { return }
            if self.captureCancelled { self.finish("캡처 취소됨"); return }
            self.capture.capture(rect: self.lastCaptureRect) { [weak self] result in
                guard let self else { return }
                guard self.generation == token else { self.capture.cleanup(); return }
                if self.captureCancelled { self.capture.cleanup(); self.finish("캡처 취소됨"); return }
                switch result {
                case .success(let file):
                    guard let file else { self.finish("캡처가 취소되었거나 이미지가 없습니다. 권한도 확인하세요."); return }
                    self.status.stringValue = "한국어·영어 텍스트 인식 중…"
                    OCRService.recognize(file) { [weak self] result in
                        guard let self else { return }
                        self.capture.cleanup()
                        guard self.generation == token else { return }
                        if self.captureCancelled { self.finish("텍스트 인식 취소됨"); return }
                        switch result {
                        case .success(let text):
                            self.question.string = text
                            self.answer.string = ""; self.resetOutput(wifiState: .pending)
                            if origin == .quick && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                self.activeCapture = false; self.setBusy(false)
                                self.prepareQuestion(origin: origin)
                            } else {
                                self.finish(text.isEmpty ? "텍스트를 찾지 못했습니다. 직접 입력하거나 더 큰 영역을 캡처하세요." : "OCR 완료. 질문을 확인·수정한 뒤 전송하세요. 이미지는 삭제했습니다.", successful: !text.isEmpty)
                            }
                        case .failure(let error): self.finish(error.localizedDescription)
                        }
                    }
                case .failure(let error): self.finish(error.localizedDescription)
                }
            }
        }
    }
    @objc private func providerChanged() {
        let api = provider.indexOfSelectedItem == 1
        settingsRow.isHidden = api; apiRow.isHidden = !api
        sendButton.title = api ? "OpenAI API로 전송 (유료)" : "로컬 AI로 전송"
        privacy.stringValue = api
            ? "API 모드: 질문과 검색된 자료 발췌가 승인 후 OpenAI로 전송되며 사용량에 따라 과금됩니다. 키는 앱 메모리에만 유지됩니다. 민감한 정보는 제거하세요."
            : "로컬 모드: 신뢰하는 Ollama와 클라우드 비활성화 설정을 사용하세요. 이미지 대신 질문과 검색된 자료 발췌를 전송합니다."
    }
    @objc private func toggleSettings(_ sender: NSButton) {
        settingsPanel.isHidden = sender.state != .on
        window.contentView?.layoutSubtreeIfNeeded()
    }
    @objc private func clearAPIKey() { apiKey.stringValue = "" }
    @objc private func sendQuestion() { prepareQuestion(origin: .manual) }
    private func prepareQuestion(origin: RequestOrigin) {
        disarmReturn()
        guard !busy else { return }
        resetOutput(wifiState: .pending)
        requestOrigin = origin
        let rawQuestion = question.string
        let requiresSources = groundedOnly.state == .on
        let useAPI = provider.indexOfSelectedItem == 1
        guard origin != .quick || origin.allowsAutomaticSend(usingAPI: useAPI) else {
            finish("API는 빠른 모드에서 자동 전송하지 않습니다."); return
        }
        do { _ = try LocalEndpoint.question(rawQuestion) }
        catch { finish(error.localizedDescription); return }
        generation += 1; let token = generation
        setBusy(true); status.stringValue = "관련 자료 검색 및 전송 내용 준비 중…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let prepared = Result<StudyPrompt, Error> {
                let sources = self.documents.retrieve(query: rawQuestion, limit: useAPI ? 6 : 3, maxCharacters: useAPI ? 7200 : 2400)
                let prompt = try StudyPromptBuilder.build(question: rawQuestion, sources: sources, requiresSources: requiresSources)
                _ = try LocalEndpoint.question(prompt.user)
                if !useAPI && prompt.user.utf8.count + prompt.system.utf8.count > 14_000 {
                    throw AppError(message: "로컬 모델의 문맥 한도를 안전하게 유지하려면 질문을 줄여 주세요. 질문과 자료의 UTF-8 합계가 14KB를 초과했습니다.")
                }
                return prompt
            }
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                self.setBusy(false)
                switch prepared {
                case .success(let prompt): self.sendPrepared(prompt, useAPI: useAPI)
                case .failure(let error): self.finish(error.localizedDescription)
                }
            }
        }
    }
    private func sendPrepared(_ prepared: StudyPrompt, useAPI: Bool) {
        guard requestOrigin != .quick || requestOrigin.allowsAutomaticSend(usingAPI: useAPI) else {
            finish("API는 빠른 모드에서 자동 전송하지 않습니다."); return
        }
        setBusy(true)
        let consentGeneration = generation
        if useAPI {
            apiConfirmationOpen = true
            defer { apiConfirmationOpen = false }
            let alert = NSAlert()
            alert.messageText = "OpenAI에 질문과 선택한 자료 발췌를 전송할까요?"
            let filenames = Set(prepared.sources.map { $0.filename }).sorted().joined(separator: ", ")
            alert.informativeText = "현재 질문 및 검색된 자료 발췌 \(prepared.sources.count)개가 api.openai.com으로 전송됩니다. 자료: \(filenames.isEmpty ? "없음" : filenames). 사용량에 따른 API 요금이 발생할 수 있으며 ChatGPT 구독과 별도입니다. 아래 전송 내용을 확인하고 민감한 정보가 있으면 취소하세요. 취소 시 이미 처리된 요청 비용은 발생할 수 있습니다."
            let preview = NSTextView()
            let scroll = textScroll(preview, editable: false)
            scroll.frame = NSRect(x: 0, y: 0, width: 620, height: 280)
            preview.frame = NSRect(x: 0, y: 0, width: 620, height: 280)
            preview.string = prepared.user
            preview.font = .systemFont(ofSize: 12)
            alert.accessoryView = scroll
            alert.addButton(withTitle: "전송 (유료)"); alert.addButton(withTitle: "취소")
            let decision = alert.runModal()
            guard generation == consentGeneration, !closingWindow else { return }
            guard decision == .alertFirstButtonReturn else { setBusy(false); status.stringValue = "전송하지 않았습니다."; return }
        }
        generation += 1; let token = generation
        let completion: (Result<String, Error>) -> Void = { [weak self] result in
            guard let self, self.generation == token else { return }
            switch result {
            case .success(let text):
                do {
                    let result = try StructuredAnswerParser.parse(text, question: prepared.question, sources: prepared.sources)
                    self.answer.string = result.formattedText
                    self.lastChoice = result.confirmedChoice
                    self.showChoice(self.lastChoice, options: prepared.question.choices.map { $0.label })
                    if self.autoCopy.state == .on, let copyText = result.automaticCopyText {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copyText, forType: .string)
                    }
                    self.finish(self.lastChoice == nil && (self.requestOrigin == .quick || self.usesPersistentWifi) ? "확정된 선택 답이 없습니다. 질문 창에서 답변과 불확실성 설명을 확인하세요." : "답변 완료. 출처 표시는 원문 대조를 돕는 기능이며 정확성을 보증하지 않습니다.", successful: self.requestOrigin != .quick || self.lastChoice != nil)
                } catch {
                    self.answer.string = "[형식/선택지/출처 검증 실패: 자동 복사와 번호 표시는 하지 않습니다.]\n\(error.localizedDescription)\n\n모델 원문 (미검증):\n\(text)"
                    self.resetOutput(); self.finish("응답 검증 실패. 원문을 검토하거나 다시 질문하세요.")
                }
            case .failure(let error): self.finish("요청 실패: \(error.localizedDescription)")
            }
        }
        do {
            if useAPI {
                try apiClient.answer(key: apiKey.stringValue, model: apiModel.stringValue, question: prepared.user, system: prepared.system, completion: completion)
                RuntimeConfiguration.preferences.set(apiModel.stringValue, forKey: "apiModel")
            } else {
                try client.answer(endpoint: endpoint.stringValue, model: model.stringValue, question: prepared.user, system: prepared.system, completion: completion)
                RuntimeConfiguration.preferences.set(endpoint.stringValue, forKey: "endpoint")
                RuntimeConfiguration.preferences.set(model.stringValue, forKey: "model")
            }
            answer.string = ""; resetOutput(wifiState: .pending); setBusy(true)
            status.stringValue = useAPI ? "OpenAI API에서 풀이 중…" : "로컬 Ollama에서 풀이 중…"
        } catch { finish(error.localizedDescription) }
    }
    private func finish(_ message: String, successful: Bool = false) {
        activeCapture = false; setBusy(false); status.stringValue = message
        menuStatus.title = message
        if requestOrigin == .quick && !successful {
            resetOutput(); menuMessage = message; menuStatus.title = message; renderMenuAnswer()
            // A native notification is best effort; the persistent menu error is always available.
            let notification = NSUserNotification()
            notification.title = "dot question · 확인 필요"; notification.informativeText = message
            NSUserNotificationCenter.default.deliver(notification)
            NSSound.beep()
        }
        if usesPersistentWifi {
            if !successful {
                wifiAnswerState = .unavailable
                menuMessage = message
            } else if let indicator = AnswerIndicator(choice: lastChoice, options: lastOptions), let choice = lastChoice {
                menuStatus.title = "선택 답 \(choice) · 보기 순서 \(indicator.ordinal)" + (indicator.wifiBars == nil ? " · 5칸 범위 밖: 상세 답을 확인하세요." : " · 다음 명령까지 유지")
            }
            renderMenuAnswer()
        }
        if requestOrigin.shouldRevealWindow && !closingWindow { showWindow() }
        if RuntimeConfiguration.isLiveTest {
            writeLiveEvidence(["successful": successful, "ordinal": AnswerIndicator(choice: lastChoice, options: lastOptions)?.ordinal ?? 0,
                               "wifiFilledBars": wifiAnswerState.filledBars, "persistentWifi": usesPersistentWifi,
                               "statusItemWidth": statusItem.length, "menuTitle": statusItem.button?.title ?? "",
                               "windowVisible": window.isVisible, "questionOCR": question.string,
                               "validatedAnswer": answer.string, "status": message,
                               "parsedChoiceLabels": MCQParser.parse(question.string).choices.map { $0.label },
                               "provider": "local Ollama", "model": model.stringValue], filename: "live-result.json")
        }
    }
    private func writeLiveEvidence(_ value: [String: Any], filename: String) {
        guard let directory = RuntimeConfiguration.liveDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent(filename), options: .atomic)
        } catch { fputs("Live evidence write failed: \(error)\n", stderr) }
    }
    @objc private func quickModeChanged() {
        RuntimeConfiguration.preferences.set(quickMode.state == .on, forKey: "quickMode")
        if quickMode.state == .on {
            menuAnswer.state = .on; outputModeChanged()
            status.stringValue = "로컬 빠른 모드 켜짐. 다른 앱의 문제 위에 커서를 놓고 단축키를 누르세요."
        }
    }
    @objc private func cancelWork() {
        resetOutput()
        disarmReturn()
        guard !importing else { return }
        if activeCapture {
            captureCancelled = true; capture.cancel()
            status.stringValue = "취소 중… 현재 캡처/인식 정리가 끝나면 다시 시작할 수 있습니다."
            return
        }
        generation += 1; client.cancel(); apiClient.cancel()
        if apiConfirmationOpen { NSApp.abortModal() }
        setBusy(false); status.stringValue = "취소했습니다. 늦게 도착한 답변은 표시하지 않습니다."; if requestOrigin.shouldRevealWindow && !closingWindow { showWindow() }
    }
    @objc private func copyAnswer() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(answer.string, forType: .string) }
    @objc private func clearContent() { cancelWork(); question.string = ""; answer.string = ""; resetOutput(); status.stringValue = "내용을 지웠습니다." }
    private func shortcutTriggered() {
        if let directory = RuntimeConfiguration.liveDirectory {
            try? "Real Carbon hotkey callback received\n".write(to: directory.appendingPathComponent("hotkey-received.txt"), atomically: true, encoding: .utf8)
        }
        guard NSApp.modalWindow == nil else { NSSound.beep(); return }
        guard !busy else { NSSound.beep(); return }
        if armedEnter.state == .on { armReturn() } else { beginCapture(origin: quickMode.state == .on ? .quick : .manual) }
    }
    private func armReturn() {
        stopCharacterAnimation()
        disarmReturn()
        if usesPersistentWifi { resetOutput(wifiState: .pending) }
        let returnKey = HotKey { [weak self] in
            guard let self else { return }
            self.disarmReturn()
            self.cursorMode.state = .on
            self.beginCapture(origin: self.quickMode.state == .on ? .quick : .manual)
        }
        let escapeKey = HotKey { [weak self] in
            self?.disarmReturn(); self?.status.stringValue = "Enter 준비를 취소했습니다."
        }
        let returnResult = returnKey.register(keyCode: UInt32(kVK_Return), modifiers: 0)
        let escapeResult = escapeKey.register(keyCode: UInt32(kVK_Escape), modifiers: 0)
        guard returnResult == noErr, escapeResult == noErr else {
            returnKey.unregister(); escapeKey.unregister()
            requestOrigin = quickMode.state == .on ? .quick : .manual
            finish("Enter 준비 키 등록 실패. 체크를 끄고 보조키 단축키로 직접 캡처하세요."); return
        }
        armedReturnKey = returnKey; armedEscapeKey = escapeKey
        if usesPersistentWifi {
            menuStatus.title = "Enter 캡처 준비 · 10초 안에 Return, Esc로 취소"
            renderMenuAnswer()
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = "Q ⏎ 10s"
        }
        status.stringValue = "10초 동안 Enter 캡처 준비. 다른 앱의 질문 위에 커서를 놓고 Return을 누르세요. Esc로 취소."
        let timer = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
            self?.disarmReturn(); self?.status.stringValue = "Enter 준비 시간이 끝났습니다."
        }
        armTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func disarmReturn() {
        armTimer?.invalidate(); armTimer = nil
        armedReturnKey?.unregister(); armedReturnKey = nil
        armedEscapeKey?.unregister(); armedEscapeKey = nil
        renderMenuAnswer()
    }
    private var shortcutKeyCode: UInt32 {
        [UInt32(kVK_ANSI_R), UInt32(kVK_Space), UInt32(kVK_Return)][max(0, min(2, shortcut.indexOfSelectedItem))]
    }
    @objc private func shortcutChanged() {
        disarmReturn()
        let result = hotKey?.register(keyCode: shortcutKeyCode) ?? -1
        if result == noErr { RuntimeConfiguration.preferences.set(shortcut.indexOfSelectedItem, forKey: "shortcut"); status.stringValue = "단축키를 변경했습니다." }
        else { status.stringValue = "단축키 등록 실패 (\(result)). 메뉴 캡처를 이용하세요." }
    }
    private func refreshDocuments() {
        documentList.removeAllItems()
        documentList.addItems(withTitles: documents.documents.map { $0.name })
        if let error = documents.loadError { documentStatus.stringValue = error }
        else { documentStatus.stringValue = "로컬 자료 \(documents.documents.count)개 · 가져온 텍스트는 이 Mac의 Application Support에 저장됩니다. 삭제 버튼으로 제거할 수 있습니다." }
    }
    @objc private func importDocuments() {
        disarmReturn()
        guard !busy else { return }
        setBusy(true)
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK else { setBusy(false); return }
        let urls = panel.urls
        importing = true; setBusy(true); cancelButton.isEnabled = false; status.stringValue = "자료를 로컬에서 읽고 색인하는 중…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var failures: [String] = []
            var imported = 0
            for url in urls {
                do { _ = try self.documents.importDocument(url); imported += 1 }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            DispatchQueue.main.async {
                self.importing = false; self.refreshDocuments(); self.setBusy(false)
                self.status.stringValue = "자료 \(imported)개 가져옴." + (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n"))
            }
        }
    }
    @objc private func removeDocument() {
        disarmReturn()
        guard !busy, documents.documents.indices.contains(documentList.indexOfSelectedItem) else { return }
        let document = documents.documents[documentList.indexOfSelectedItem]
        setBusy(true)
        let alert = NSAlert(); alert.messageText = "가져온 자료를 삭제할까요?"
        alert.informativeText = "\(document.name)의 로컬 색인과 저장 텍스트를 제거합니다. 원본 파일은 변경하지 않습니다."
        alert.addButton(withTitle: "삭제"); alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { setBusy(false); return }
        defer { setBusy(false) }
        do { try documents.remove(document.id); refreshDocuments(); status.stringValue = "가져온 자료를 삭제했습니다." }
        catch { status.stringValue = error.localizedDescription }
    }
    private func resetOutput(wifiState: WifiAnswerState = .idle) {
        stopCharacterAnimation(); lastChoice = nil; lastOptions = []; menuMessage = nil
        wifiAnswerState = wifiState
        menuStatus.title = wifiState == .pending ? "처리 중 · 아직 확정된 답 없음" : "대기 중 · 아직 답 없음"
        renderMenuAnswer()
    }
    private var usesPersistentWifi: Bool { menuStyle.indexOfSelectedItem == 1 }
    private func renderMenuAnswer() {
        guard let button = statusItem?.button else { return }
        if usesPersistentWifi {
            // Fixed width, image-only alignment, and no Q/Q?/Q! or empty-image state.
            statusItem.length = AnswerStatusIcon.wifiStatusItemLength
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.image = AnswerStatusIcon.wifi(bars: menuAnswer.state == .on ? wifiAnswerState.filledBars : 0)
            let detail = menuAnswer.state == .on ? (menuMessage ?? menuStatus.title) : "답 표시 꺼짐 · 0칸"
            button.toolTip = "dot question • \(detail) • not actual battery/network · 실제 Wi-Fi 상태 아님"
            return
        }
        statusItem.length = NSStatusItem.variableLength
        button.image = nil
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.title = "Q?"
        button.toolTip = "dot question • answer unknown • not actual battery/network · 실제 배터리/네트워크 상태 아님"
        if let message = menuMessage {
            button.title = "Q!"; button.toolTip = message; return
        }
        guard let indicator = AnswerIndicator(choice: lastChoice, options: lastOptions),
              let choice = lastChoice else { return }
        button.toolTip = "dot question • answer \(choice) (보기 순서 \(indicator.ordinal)) • not actual battery/network · AI 답은 검토하세요"
        if menuAnswer.state != .on {
            if selectedCharacter != .off {
                button.image = CharacterStatusIcon.image(style: selectedCharacter, active: false)
                button.title = "Q \(indicator.ordinal)"
            } else { button.toolTip = "dot question • answer display off" }
            return
        }
        switch menuStyle.indexOfSelectedItem {
        case 2:
            button.image = AnswerStatusIcon.battery(percent: indicator.batteryPercent)
            button.title = "Q \(indicator.batteryPercent)%"
        default:
            button.title = "Q \(choice)"
        }
    }
    private var selectedCharacter: CharacterStatusIcon.Style {
        CharacterStatusIcon.Style(rawValue: characterStyle.indexOfSelectedItem) ?? .off
    }
    private var motionReduced: Bool {
        reduceMotion.state == .on || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    private func stopCharacterAnimation() {
        animationTimer?.invalidate(); animationTimer = nil
        animationStep = 0; animationCount = 0
    }
    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView, view === question else { return }
        // Draft edits are not a new capture/send command.
        guard !usesPersistentWifi else { return }
        resetOutput()
    }
    @objc private func outputModeChanged() {
        RuntimeConfiguration.preferences.set(menuAnswer.state == .on, forKey: "menuAnswer")
        RuntimeConfiguration.preferences.set(menuStyle.indexOfSelectedItem, forKey: "menuStyle")
        RuntimeConfiguration.preferences.set(characterStyle.indexOfSelectedItem, forKey: "characterStyle")
        RuntimeConfiguration.preferences.set(reduceMotion.state == .on, forKey: "reduceMotion")
        stopCharacterAnimation()
        if armedReturnKey != nil { disarmReturn() }
        renderMenuAnswer()
    }
    private func showChoice(_ choice: String?, options: [String]) {
        stopCharacterAnimation()
        lastChoice = choice; lastOptions = options
        wifiAnswerState = WifiAnswerState(choice: choice, options: options)
        renderMenuAnswer()
        guard !usesPersistentWifi, selectedCharacter != .off,
              let indicator = AnswerIndicator(choice: choice, options: options) else { return }
        guard !motionReduced else { return }
        animationCount = indicator.ordinal; animationStep = 0
        // Two half-second frames make one pulse; no full-screen flashing.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard !self.motionReduced, self.animationStep < self.animationCount * 2 else {
                self.stopCharacterAnimation(); self.renderMenuAnswer(); return
            }
            self.statusItem.button?.image = CharacterStatusIcon.image(
                style: self.selectedCharacter, active: self.animationStep % 2 == 0)
            self.statusItem.button?.title = "Q \(indicator.ordinal)"
            self.statusItem.button?.toolTip = "dot question • 보기 순서 \(indicator.ordinal) • 캐릭터 신호 • AI 답은 검토하세요"
            self.animationStep += 1
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        resetOutput(); disarmReturn()
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowWillClose(_ notification: Notification) {
        closingWindow = true
        // Closing settings does not erase a completed Wi-Fi answer.
        if usesPersistentWifi && (!busy || importing) { disarmReturn() }
        else { cancelWork() }
        window.orderOut(nil)
    }
    func applicationWillTerminate(_ notification: Notification) { NSWorkspace.shared.notificationCenter.removeObserver(self); disarmReturn(); animationTimer?.invalidate(); apiKey.stringValue = ""; apiClient.cancel(); client.cancel(); capture.cancel(); capture.cleanup(); hotKey = nil }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
