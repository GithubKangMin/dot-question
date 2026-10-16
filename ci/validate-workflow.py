"""Local YAML and policy checks; requires PyYAML, not a GitHub service-side validation."""
from pathlib import Path
import json
import os
import re
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/build-test.yml'

class WorkflowChecks(unittest.TestCase):
    def setUp(self):
        self.data = yaml.safe_load(WORKFLOW.read_text())

    def test_bounded_push_and_manual(self):
        self.assertEqual(set(self.data['on']), {'push', 'workflow_dispatch'})
        push = self.data['on']['push']
        self.assertEqual(push['branches'], ['main'])
        self.assertEqual(push['paths'], ['dot-question-mac/**', 'dot-question-windows/**', 'browser-extension/**', 'ci/**', '.github/workflows/build-test.yml'])
        inputs = self.data['on']['workflow_dispatch']['inputs']['platform']
        self.assertEqual(inputs['default'], 'macos')
        self.assertEqual(inputs['options'], ['macos', 'windows', 'both'])

    def test_read_only_and_cancellation(self):
        self.assertEqual(self.data['permissions'], {'contents': 'read'})
        self.assertIs(self.data['concurrency']['cancel-in-progress'], True)

    def test_two_bounded_standard_runners(self):
        jobs = self.data['jobs']
        self.assertEqual(set(jobs), {'macos', 'windows'})
        self.assertEqual(jobs['macos']['runs-on'], 'macos-15')
        self.assertEqual(jobs['windows']['runs-on'], 'windows-2022')
        for job in jobs.values():
            self.assertLessEqual(job['timeout-minutes'], 20)
            self.assertIn('inputs.platform', job['if'])
            self.assertTrue(job['if'].startswith("github.event_name == 'push' || "))

    def test_pinned_actions_and_short_artifacts(self):
        for job in self.data['jobs'].values():
            for step in job['steps']:
                if 'uses' not in step:
                    continue
                self.assertRegex(step['uses'], r'^actions/[a-z-]+@[0-9a-f]{40}$')
                if step['uses'].startswith('actions/upload-artifact@'):
                    self.assertEqual(step['with']['retention-days'], 1)
                    self.assertEqual(step['with']['if-no-files-found'], 'error')
                if step['uses'].startswith('actions/checkout@'):
                    self.assertIs(step['with']['persist-credentials'], False)

    def test_real_recording_safety_and_no_fixtures(self):
        script = (ROOT / 'ci/record-mac-live.sh').read_text()
        self.assertLess(script.index('run_capture --probe'), script.index('curl --fail --location'))
        for forbidden in ['tccutil', 'TCC.db', 'sudo ', 'osascript', 'launchctl']:
            self.assertNotIn(forbidden, script)
        self.assertIn('OLLAMA_NO_CLOUD=1', script)
        self.assertIn('https://ollama.com/download/Ollama-darwin.zip', script)
        runtime = (ROOT / 'dot-question-mac/Sources/DotQuestion/RuntimeConfiguration.swift').read_text()
        self.assertIn('environment["GITHUB_ACTIONS"] == "true"', runtime)
        self.assertIn('isSmokeTest || isLiveTest', runtime)
        ui = (ROOT / 'dot-question-mac/Sources/DotQuestion/main.swift').read_text()
        self.assertIn('model.stringValue = "qwen2.5:7b"', ui)

    def test_numeric_probe_flag_is_explicit_push_only(self):
        step = next(step for step in self.data['jobs']['macos']['steps']
                    if step.get('run') == 'bash ../ci/record-mac-live.sh')
        self.assertEqual(step['name'], 'Record actual desktop OCR probes or full local-model answers')
        self.assertEqual(step['env']['DOT_OCR_PROBE_ONLY'],
                         "${{ github.event_name == 'push' && contains(github.event.head_commit.message, '[numeric-ocr-only]') && '1' || '0' }}")

    def test_numeric_probe_branch_precedes_all_model_operations(self):
        script = (ROOT / 'ci/record-mac-live.sh').read_text()
        start = script.index('if [[ "${DOT_OCR_PROBE_ONLY:-0}" == "1" ]]; then')
        end = script.index('# Inspect the actual standard runner', start)
        branch = script[start:end]
        self.assertLess(script.index('run_capture --probe "$OUT/probe"'), start)
        self.assertIn('run_capture --probe-numeric "$OUT/numeric-probe"', branch)
        self.assertIn('  exit 0\nfi', branch)
        self.assertLess(end, script.index('https://ollama.com/download/Ollama-darwin.zip'))
        self.assertLess(end, script.index('"$OLLAMA" serve'))
        self.assertLess(end, script.index('"$OLLAMA" pull qwen2.5:7b'))
        self.assertLess(end, script.index('/api/generate'))
        self.assertIn('run_capture --record "$OUT/real-model"', script[end:])

    def test_numeric_probe_flag_exits_in_shell_but_default_continues(self):
        # Execute the actual flag branch with synthetic policy-test evidence.
        # This verifies shell control flow only, never claims a real OCR pass.
        script = (ROOT / 'ci/record-mac-live.sh').read_text()
        start = script.index('if [[ "${DOT_OCR_PROBE_ONLY:-0}" == "1" ]]; then')
        end = script.index('# Inspect the actual standard runner', start)
        branch = script[start:end]
        shell = ('set -euo pipefail\n'
                 'run_capture() { printf "CAPTURE %s\\n" "$1"; }\n'
                 + branch + '\nprintf "REACHED_MODEL_DOWNLOAD\\n"\n')
        with tempfile.TemporaryDirectory(prefix='dot-ocr-policy-') as tmp:
            numeric = Path(tmp) / 'numeric-probe'
            numeric.mkdir()
            (numeric / 'live-result.json').write_text(json.dumps({
                'parsedChoiceLabels': ['1','2','3','4','5'],
                'parsedChoiceTexts': ['3','4','5','6','7'],
                'questionOCR': '\n'.join(f'{i}. {i+2}' for i in range(1, 6)),
                'windowVisible': False, 'persistentWifi': True, 'wifiFilledBars': 0,
            }))
            for flag in ('1', '0', None):
                with self.subTest(flag=flag):
                    env = dict(os.environ, OUT=tmp)
                    env.pop('DOT_OCR_PROBE_ONLY', None)
                    if flag is not None:
                        env['DOT_OCR_PROBE_ONLY'] = flag
                    result = subprocess.run(['bash', '-c', shell], env=env,
                                            text=True, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    if flag == '1':
                        self.assertIn('CAPTURE --probe-numeric', result.stdout)
                        self.assertNotIn('REACHED_MODEL_DOWNLOAD', result.stdout)
                    else:
                        self.assertNotIn('CAPTURE --probe-numeric', result.stdout)
                        self.assertIn('REACHED_MODEL_DOWNLOAD', result.stdout)

    def test_numeric_probe_keeps_word_video_and_strict_ocr_assertions(self):
        harness = (ROOT / 'ci/mac-desktop-harness.swift').read_text()
        sequence = harness.split('static let sequence = [', 1)[1].split('\n}\n', 1)[0]
        self.assertIn('["1. Three", "2. Four", "3. Five", "4. Six", "5. Seven"]', sequence)
        self.assertNotIn('["1. 3", "2. 4", "3. 5", "4. 6", "5. 7"]', sequence)
        self.assertIn('try await pause(probeOnly ? 3 : 10)', harness)
        self.assertIn('numericProbeOnly ? [QuestionFixture.numericArithmetic]', harness)
        self.assertIn('result["parsedChoiceLabels"] as? [String] == ["1", "2", "3", "4", "5"]', harness)
        self.assertIn('result["parsedChoiceTexts"] as? [String] == ["3", "4", "5", "6", "7"]', harness)
        self.assertIn('normalizedNumericOptions && result["wifiFilledBars"] as? Int == 0', harness)
        self.assertEqual(harness.count('try await stream.startCapture()'), 1)
        self.assertEqual(harness.count('try await stream.stopCapture()'), 1)

    def test_lipo_input_precedes_verify_arch_list(self):
        steps = self.data['jobs']['macos']['steps']
        package = next(step['run'] for step in steps if step.get('name', '').startswith('Package'))
        self.assertIn("lipo 'dist/dot question.app/Contents/MacOS/DotQuestion' -verify_arch arm64", package)

    def test_no_secrets_or_global_xcode_switch(self):
        text = WORKFLOW.read_text()
        self.assertNotIn('secrets.', text)
        self.assertNotIn('sudo ', text)
        self.assertNotIn('xcode-select --switch', text)

if __name__ == '__main__':
    unittest.main(verbosity=2)
