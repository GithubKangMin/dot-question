#!/usr/bin/env python3
"""Structural checks only. These do not compile or execute Swift."""
import pathlib, plistlib, unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
class SourceChecks(unittest.TestCase):
    def test_plist(self):
        p = plistlib.loads((ROOT / 'Info.plist').read_bytes())
        self.assertEqual(p['CFBundleExecutable'], 'DotQuestion')
        self.assertTrue(p['LSUIElement'])
        self.assertNotIn('NSAllowsArbitraryLoads', p['NSAppTransportSecurity'])
    def test_structure(self):
        for name in ['Package.swift', 'build.command', 'README_KO.md', 'Sources/DotQuestion/main.swift', 'Sources/DotQuestion/Services.swift', 'Sources/DotQuestion/HotKey.swift', 'Sources/QuestionCore/LocalEndpoint.swift', 'Tests/QuestionCoreTests/LocalEndpointTests.swift']:
            self.assertTrue((ROOT / name).is_file(), name)
    def test_privacy_guards_present(self):
        s = (ROOT / 'Sources/DotQuestion/Services.swift').read_text()
        for token in ['completionHandler(nil)', 'connectionProxyDictionary = [:]', 'remote_model == nil', 'remote_host == nil', 'api/tags', 'timeoutIntervalForResource = 180', 'removeItem(at: directory)']:
            self.assertIn(token, s)
        core = (ROOT / 'Sources/QuestionCore/LocalEndpoint.swift').read_text()
        for token in ['c.user == nil', 'c.password == nil', 'c.query == nil', 'c.fragment == nil', 'contains("cloud")']:
            self.assertIn(token, core)
    def test_api_guards_present(self):
        api = (ROOT / 'Sources/DotQuestion/OpenAIClient.swift').read_text()
        ui = (ROOT / 'Sources/DotQuestion/main.swift').read_text()
        self.assertIn('https://api.openai.com/v1/chat/completions', api)
        self.assertIn('"store": false', api)
        self.assertIn('NSSecureTextField', ui)
        self.assertIn('alert.runModal()', ui)
        self.assertNotIn('UserDefaults', api)
        self.assertNotIn('set(apiKey', ui)
    def test_grounding_contract(self):
        core = (ROOT / 'Sources/QuestionCore/StudyCore.swift').read_text()
        store = (ROOT / 'Sources/DotQuestion/DocumentStore.swift').read_text()
        for token in ['invalidCitation', 'invalidChoice', 'missingEvidence', 'promptTooLong', 'requiresSources', 'allowed[id]']:
            self.assertIn(token, core)
        for token in ['NSLock', 'PDFDocument(data: data)', 'options: .atomic', 'ensureWritable()', 'maximumFileBytes', 'maximumLibraryCharacters']:
            self.assertIn(token, store)
        self.assertNotIn('UserDefaults', store)
    def test_temporary_enter_and_output_guards(self):
        ui = (ROOT / 'Sources/DotQuestion/main.swift').read_text()
        hotkey = (ROOT / 'Sources/DotQuestion/HotKey.swift').read_text()
        for token in ['NSApp.modalWindow == nil', 'Timer(timeInterval: 10', 'forMode: .common', 'armedReturnKey?.unregister()', 'armedEscapeKey?.unregister()', 'result.confirmedChoice', 'result.automaticCopyText', 'StructuredAnswerParser.parse']:
            self.assertIn(token, ui)
        self.assertIn('received.id == owner.identifier', hotkey)
    def test_consent_cancellation_and_compact_settings(self):
        ui = (ROOT / 'Sources/DotQuestion/main.swift').read_text()
        for token in ['let consentGeneration = generation', 'generation == consentGeneration, !closingWindow',
                      'if apiConfirmationOpen { NSApp.abortModal() }', 'settingsPanel.isHidden = true']:
            self.assertIn(token, ui)
    def test_no_keyboard_hardware_features(self):
        ui = (ROOT / 'Sources/DotQuestion/main.swift').read_text()
        self.assertFalse((ROOT / 'Sources/DotQuestion/CapsLED.swift').exists())
        for token in ['capsLED', 'ledOptIn', 'probeLED', 'CoreHID', '--probe-led']:
            self.assertNotIn(token, ui)
    def test_answer_icon_contract(self):
        ui = (ROOT / 'Sources/DotQuestion/main.swift').read_text()
        core = (ROOT / 'Sources/QuestionCore/AnswerIndicator.swift').read_text()
        icon = (ROOT / 'Sources/DotQuestion/AnswerStatusIcon.swift').read_text()
        for token in ['AnswerStatusIcon.wifi', 'AnswerStatusIcon.battery', 'not actual battery/network', 'lastOptions = []', 'button.image = nil', 'renderMenuAnswer()']:
            self.assertIn(token, ui)
        for token in ['ordinal <= 5', 'ordinal * 10', '(2...10).contains', 'Set(options).count == options.count']:
            self.assertIn(token, core)
        self.assertEqual(icon.count('image.isTemplate = true'), 2)
        for token in ['CoreWLAN', 'IOPSCopyPowerSourcesInfo', 'Process(']:
            self.assertNotIn(token, icon)
        self.assertTrue((ROOT / 'Tests/QuestionCoreTests/AnswerIndicatorTests.swift').is_file())
    def test_character_modes_and_motion_guards(self):
        ui = (ROOT / 'Sources/DotQuestion/main.swift').read_text()
        icon = (ROOT / 'Sources/DotQuestion/CharacterStatusIcon.swift').read_text()
        for token in ['캐릭터 끄기', '고양이 · 꼬리 흔들기', '피카츄 · 전기 펄스',
                      'accessibilityDisplayShouldReduceMotion', 'guard !motionReduced',
                      'Timer(timeInterval: 0.5', 'self.animationCount * 2',
                      'CharacterStatusIcon.image', 'self.stopCharacterAnimation(); self.renderMenuAnswer()',
                      'view === question', 'animationStep = 0; animationCount = 0']:
            self.assertIn(token, ui)
        for start, end in [('private func captureRegion()', 'private func providerChanged()'),
                           ('private func sendQuestion()', 'private func sendPrepared('),
                           ('private func cancelWork()', 'private func copyAnswer()'),
                           ('func textDidChange(', 'private func outputModeChanged()'),
                           ('func applicationShouldTerminate(', 'func windowWillClose(')]:
            section = ui[ui.index(start):ui.index(end)]
            self.assertIn('resetOutput()', section, start)
        for start, end in [('private func outputModeChanged()', 'private func showChoice('),
                           ('private func armReturn()', 'private func disarmReturn()')]:
            self.assertIn('stopCharacterAnimation()', ui[ui.index(start):ui.index(end)])
        self.assertIn('case off = 0, cat, pikachu', icon)
        self.assertIn('tail.curve', icon)
        self.assertIn('if active', icon)
        for token in ['URLSession', 'URL(', 'NSImage(contentsOf', 'Process(', 'CoreWLAN']:
            self.assertNotIn(token, icon)
    def test_local_quick_flow_contract(self):
        ui = (ROOT / 'Sources/DotQuestion/main.swift').read_text()
        core = (ROOT / 'Sources/QuestionCore/RequestOrigin.swift').read_text()
        for token in ['"menuAnswer": true, "quickMode": false',
                      'if origin == .quick || cursorMode.state == .on',
                      'self.prepareQuestion(origin: origin)',
                      'if requestOrigin.shouldRevealWindow && !closingWindow',
                      'if origin != .quick { _ = CGRequestScreenCaptureAccess() }',
                      'menuMessage = message; menuStatus.title = message',
                      'previous.activate(options:', 'NSWorkspace.didActivateApplicationNotification',
                      'if quickMode.state != .on || RuntimeConfiguration.isSmokeTest']:
            self.assertIn(token, ui)
        self.assertEqual(ui.count('allowsAutomaticSend(usingAPI:'), 3)
        self.assertIn('self == .quick && !usingAPI', core)
        for key in ['quickMode', 'menuAnswer', 'menuStyle', 'characterStyle', 'reduceMotion']:
            self.assertIn('forKey: "' + key + '"', ui)
        finish = ui[ui.index('private func finish('):ui.index('@objc private func quickModeChanged')]
        self.assertIn('NSUserNotificationCenter.default.deliver(notification)', finish)
        self.assertIn('resetOutput()', finish)
        self.assertTrue((ROOT / 'Tests/QuestionCoreTests/RequestOriginTests.swift').is_file())
    def test_screenshot_evidence_uses_visible_views(self):
        ui = (ROOT / 'Sources/DotQuestion/main.swift').read_text()
        capture = ui[ui.index('private func saveSmokeScreenshots'):ui.index('private func buildWindow')]
        for token in ['macos-settings-window-app-view.png', 'macos-answer-window-app-view.png',
                      'macos-app-icon-preview.png', 'visible > samples * 9 / 10',
                      'ink > samples / 500', 'settingsPanel.isHidden = false',
                      'settingsPanel.isHidden = true', 'scroll.contentView.scroll(to: .zero)']:
            self.assertIn(token, capture)
        self.assertNotIn('try save(document,', capture)
        self.assertNotIn('try save(button,', capture)
        self.assertIn('앱 아이콘 렌더링 · 시스템 메뉴바 캡처 아님', ui)
    def test_no_bundled_binaries(self):
        for path in ROOT.rglob('*'):
            if any(part == 'dist' or part == '.build' or part.startswith('.build-') for part in path.relative_to(ROOT).parts):
                continue
            if path.is_file():
                self.assertNotIn(path.read_bytes()[:4], [b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\x7fELF'], str(path))
if __name__ == '__main__': unittest.main(verbosity=2)
