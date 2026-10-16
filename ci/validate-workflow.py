"""Local YAML and policy checks; requires PyYAML, not a GitHub service-side validation."""
from pathlib import Path
import re
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
        self.assertEqual(push['paths'], ['dot-question-mac/**', 'dot-question-windows/**', 'ci/**', '.github/workflows/build-test.yml'])
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

    def test_no_secrets_or_global_xcode_switch(self):
        text = WORKFLOW.read_text()
        self.assertNotIn('secrets.', text)
        self.assertNotIn('sudo ', text)
        self.assertNotIn('xcode-select --switch', text)

if __name__ == '__main__':
    unittest.main(verbosity=2)
