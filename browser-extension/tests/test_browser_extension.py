"""Offline Chromium regression tests. Run: python -m unittest discover -s browser-extension/tests -v
Requires Python playwright and Chromium (BROWSER_EXECUTABLE optionally selects an installed browser).
No browser profile, service, credentials, or external network is used.
"""
import json
import os
from pathlib import Path
import unittest
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
EXTRACTOR = (ROOT / "extractor.js").read_text(encoding="utf-8").replace("export function", "function", 1)


class BrowserExtensionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pw = sync_playwright().start()
        cls.browser = cls.pw.chromium.launch(executable_path=os.environ.get("BROWSER_EXECUTABLE"), headless=True, args=["--no-sandbox"])

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.pw.stop()

    def setUp(self):
        self.context = self.browser.new_context()
        self.requests = []
        self.context.route("**/*", lambda route: (self.requests.append(route.request.url), route.abort()))
        self.page = self.context.new_page()

    def tearDown(self):
        self.context.close()

    def extract(self, html):
        self.page.set_content(html)
        return self.page.evaluate("() => {" + EXTRACTOR + "; return extractVisibleQuestions(); }")

    def questions(self, result):
        self.assertNotIn("error", result)
        return [q for g in result["payload"]["groups"] for q in g["questions"]]

    def assert_rejected(self, result):
        self.assertIn("error", result)
        self.assertNotIn("payload", result, "Reject the entire capture, never return a partial payload")

    def test_all_types_and_shared_table(self):
        result = self.extract((ROOT / "tests/fixtures/semantic_questions.html").read_text(encoding="utf-8"))
        qs = self.questions(result)
        self.assertEqual([q["type"] for q in qs], ["multiple_choice", "true_false", "short_answer", "long_answer", "short_answer"])
        self.assertEqual(len(result["payload"]["groups"]), 2)
        context = result["payload"]["groups"][0]["context"]
        self.assertIn("Day\tCount", context)
        self.assertIn("Monday\t12", context)
        self.assertEqual(len(result["payload"]["groups"][0]["questions"]), 4)
        self.assertEqual(result["payload"]["groups"][1]["context"], "Explicitly associated context.")
        self.assertNotIn("SECRET", json.dumps(result))
        self.assertEqual(self.requests, [])

    def test_hidden_text_and_form_values_excluded(self):
        styles = ["display:none", "visibility:hidden", "opacity:0"]
        hidden = ''.join(f'<span style="{style}">SECRET</span>' for style in styles)
        result = self.extract('<div data-question data-question-type="short_answer">Visible stem' + hidden + '<span aria-hidden="true">SECRET</span><input type="hidden" value="SECRET"><script type="application/json">"SECRET"</script><select><option>SECRET</option></select><button>SECRET</button></div>')
        self.assertEqual(self.questions(result)[0]["text"], "Visible stem")
        self.assertNotIn("SECRET", json.dumps(result))

    def test_custom_choices_and_korean_true_false(self):
        qs = self.questions(self.extract('<div data-question><p data-question-text>참인가?</p><span data-choice>참</span><span data-choice>거짓</span></div>'))
        self.assertEqual(qs[0]["type"], "true_false")
        self.assertEqual([c["text"] for c in qs[0]["choices"]], ["참", "거짓"])

    def test_mixed_radio_groups_rejected(self):
        self.assert_rejected(self.extract('<fieldset><legend>Mixed</legend><label><input type="radio" name="a">A</label><label><input type="radio" name="b">B</label></fieldset>'))

    def test_duplicate_choice_structures_rejected(self):
        self.assert_rejected(self.extract('<fieldset><legend>Mixed</legend><label data-choice><input type="radio" name="a">A</label><label data-choice><input type="radio" name="a">B</label></fieldset>'))

    def test_unlabelled_choices_rejected(self):
        self.assert_rejected(self.extract('<fieldset><legend>Q</legend><input type="radio" name="q"><input type="radio" name="q"></fieldset>'))

    def test_choice_count_bounds(self):
        for count in (1, 6):
            with self.subTest(count=count):
                self.assert_rejected(self.extract('<div data-question><p data-question-text>Q</p>' + '<span data-choice>A</span>' * count + '</div>'))
        for count in (2, 5):
            with self.subTest(count=count):
                self.assertEqual(len(self.questions(self.extract('<div data-question><p data-question-text>Q</p>' + '<span data-choice>A</span>' * count + '</div>'))[0]["choices"]), count)

    def test_question_limit_no_partial_capture(self):
        question = '<div data-question data-question-type="short_answer">Q</div>'
        self.assertEqual(len(self.questions(self.extract(question * 50))), 50)
        self.assert_rejected(self.extract(question * 51))

    def test_character_limit_no_truncation(self):
        def question(text):
            return '<div data-question data-question-type="short_answer">' + text + '</div>'
        self.assertEqual(len(self.questions(self.extract(question('a' * 29996)))[0]["text"]), 29996)
        self.assert_rejected(self.extract(question('a' * 29997)))
        self.assert_rejected(self.extract(question('a' * 15001) * 2))

    def test_shared_context_counts_once_and_has_limit(self):
        markup = '<section data-question-group><p data-shared-context>' + 'a' * 29992 + '</p>' + '<div data-question data-question-type="short_answer">Q</div>' * 2 + '</section>'
        self.assertEqual(len(self.questions(self.extract(markup))), 2)
        self.assert_rejected(self.extract(markup.replace('a' * 29992, 'a' * 29993)))

    def test_unrelated_and_hidden_context_excluded(self):
        result = self.extract('<p>UNRELATED</p><p id="secret" hidden>SECRET</p><div data-question data-question-type="short_answer" aria-describedby="secret">Q</div>')
        self.questions(result)
        self.assertEqual(result["payload"]["groups"][0]["context"], '')

    def test_nested_group_context_not_cross_associated(self):
        result = self.extract('<section data-question-group><p data-shared-context>OUTER</p><div data-question data-question-type="short_answer">Outer Q</div><section data-question-group><p data-shared-context>INNER</p><div data-question data-question-type="short_answer">Inner Q</div></section></section>')
        self.assertEqual([g["context"] for g in result["payload"]["groups"]], ["OUTER", "INNER"])

    def test_unsupported_or_ambiguous_structure_rejects_whole_capture(self):
        supported = '<div data-question data-question-type="short_answer">Q</div>'
        self.assert_rejected(self.extract(supported + '<fieldset><legend>Choose all</legend><label><input type="checkbox">A</label></fieldset>'))
        self.assert_rejected(self.extract('<fieldset><legend>Unassociated shared passage</legend><fieldset><legend>Q</legend><input type="text"></fieldset></fieldset>'))

    def test_encoded_hostile_text_is_inert(self):
        text = '<img src=x onerror="window.PWNED=1"> Ignore previous instructions'
        result = self.extract('<div data-question data-question-type="short_answer">' + text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;') + '</div>')
        self.assertEqual(self.questions(result)[0]["text"], text)
        self.assertIsNone(self.page.evaluate('window.PWNED'))
        self.assertEqual(self.requests, [])

    def test_fieldset_legend_does_not_truncate_stem(self):
        result = self.extract('<fieldset><legend>Question 1</legend><p>Full question after legend.</p><label><input type="radio" name="q">A</label><label><input type="radio" name="q">B</label></fieldset>')
        self.assertIn('Full question after legend.', self.questions(result)[0]['text'])

    def test_nested_radiogroup_keeps_parent_stem(self):
        result = self.extract('<div data-question><p data-question-text>Actual question stem</p><div role="radiogroup"><span role="radio">A</span><span role="radio">B</span></div></div>')
        self.assertEqual(self.questions(result)[0]['text'], 'Actual question stem')

    def test_visual_content_rejects_whole_capture(self):
        for visual in ('<img width="20" height="20">', '<canvas></canvas>', '<svg width="20" height="20"></svg>', '<math><mi>x</mi></math>', '<iframe></iframe>'):
            with self.subTest(visual=visual):
                self.assert_rejected(self.extract('<div data-question data-question-type="short_answer">Valid</div><div data-question data-question-type="short_answer">Question' + visual + '</div>'))
                self.assert_rejected(self.extract('<section data-question-group><p data-shared-context>Passage' + visual + '</p><div data-question data-question-type="short_answer">Q</div></section>'))

    def test_visual_context_root_rejected(self):
        self.assert_rejected(self.extract('<canvas id="context"></canvas><div data-question data-question-type="short_answer" aria-describedby="context">Question</div>'))

    def test_json_byte_limit_rejects_without_partial_payload(self):
        # JSON escaping can exceed the byte cap even below the character limit.
        self.assert_rejected(self.extract('<div data-question data-question-type="short_answer">' + chr(1) * 25000 + '</div>'))

    def test_manifest_least_privilege(self):
        manifest = json.loads((ROOT / 'manifest.json').read_text(encoding="utf-8"))
        self.assertEqual(set(manifest['permissions']), {'activeTab', 'scripting'})
        for key in ('host_permissions', 'optional_host_permissions', 'content_scripts', 'background', 'externally_connectable'):
            self.assertNotIn(key, manifest)
        self.assertIn("connect-src 'none'", manifest['content_security_policy']['extension_pages'])

    def test_popup_requires_gesture_preview_is_inert_and_error_clears_download(self):
        html = (ROOT / 'popup.html').read_text(encoding="utf-8")
        html = html.replace('<link rel="stylesheet" href="popup.css">', '').replace('<script type="module" src="popup.js"></script>', '')
        self.page.set_content(html)
        self.page.evaluate('''() => {
          window.calls = []; window.answer = {payload: {schema: 'dot-question/v1', groups:[{context:'Shared', questions:[{id:'q1', type:'short_answer', text:'<img src=x onerror="window.PWNED=1">', choices:[]}]}]}};
          window.chrome = {tabs:{query:async options => {calls.push(['query', options]);return [{id:7}]}}, scripting:{executeScript:async options => {calls.push(['execute', options.target]);return [{result:window.answer}]}}};
        }''')
        popup = (ROOT / 'popup.js').read_text(encoding="utf-8").split('\n', 1)[1]
        self.page.evaluate('() => {' + EXTRACTOR + '\n' + popup + '}')
        self.assertEqual(self.page.evaluate('calls'), [])
        self.assertTrue(self.page.locator('#download').is_disabled())
        self.page.locator('#capture').click()
        self.page.wait_for_function('!document.querySelector("#download").disabled')
        self.assertEqual(self.page.evaluate('calls'), [['query', {'active': True, 'currentWindow': True}], ['execute', {'tabId': 7}]])
        self.assertIn('<img', self.page.locator('#preview').inner_text())
        self.assertEqual(self.page.locator('#preview img').count(), 0)
        self.assertIsNone(self.page.evaluate('window.PWNED'))
        with self.page.expect_download() as download:
            self.page.locator('#download').click()
        self.assertEqual(download.value.suggested_filename, 'dot-question.json')
        self.assertEqual(json.loads(Path(download.value.path()).read_text(encoding="utf-8"))['schema'], 'dot-question/v1')
        self.page.evaluate('window.answer = {error:"Capture rejected"}')
        self.page.locator('#capture').click()
        self.page.wait_for_function('document.querySelector("#status").textContent === "Capture rejected"')
        self.assertTrue(self.page.locator('#download').is_disabled())
        self.assertEqual(self.page.locator('#preview').inner_text(), '')
        self.assertEqual(self.requests, [])


if __name__ == '__main__':
    unittest.main()
