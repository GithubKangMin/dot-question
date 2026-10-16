"""Bounded browser JSON and typed answer contract. No network calls."""
import copy
import json
import unittest
from unittest.mock import patch
import core


def fixture(kind='multiple_choice'):
    choices = [{'label': 'B', 'text': 'First'}, {'label': 'A', 'text': 'Second'}] if kind == 'multiple_choice' else []
    return {'schema': 'dot-question/v1', 'groups': [{'id': 'g1', 'context': 'Shared passage\n1. Not an option\n2. A table row', 'questions': [
        {'id': 'q1', 'type': kind, 'text': 'Prompt?', 'choices': choices}]}]}


def parse(value):
    return core.parse_question_import(json.dumps(value, ensure_ascii=False).encode())


def answer(choice=None, uncertain=None):
    return {'selected_choice': choice, 'answer': 'Answer only', 'explanation': 'Reason here', 'citations': [], 'uncertainty': uncertain}


class ImportTests(unittest.TestCase):
    def test_all_types_context_and_display_order(self):
        for kind in ('multiple_choice', 'short_answer', 'long_answer', 'true_false'):
            q = parse(fixture(kind))[0]
            payload = json.loads(core.build_messages(q.display_text, [], imported=q)[1]['content'])
            self.assertEqual(payload['shared_context'], q.context)
            self.assertEqual(payload['question'], 'Prompt?')
            self.assertEqual(payload['question_type'], kind)
            if kind == 'multiple_choice':
                result = core.validate_answer(answer('A'), q.options, [], kind)
                self.assertEqual(result.signal_index, 2)
            elif kind != 'true_false':
                self.assertEqual(payload['choices'], [])
                result = core.validate_answer(answer(), q.options, [], kind)
                self.assertEqual(result.clipboard_text, 'Answer only')
                self.assertIsNone(result.signal_index)

    def test_multiple_questions_keep_same_group_context(self):
        value = fixture()
        other = copy.deepcopy(value['groups'][0]['questions'][0]); other['id'] = 'q2'
        value['groups'][0]['questions'].append(other)
        questions = parse(value)
        self.assertEqual(len(questions), 2)
        self.assertEqual(questions[0].context, questions[1].context)
        self.assertEqual(questions[0].group_id, questions[1].group_id)

    def test_true_false_mapping_independent_of_visible_order(self):
        value = fixture('true_false')
        value['groups'][0]['questions'][0]['choices'] = [{'label': '1', 'text': '거짓'}, {'label': '2', 'text': '참'}]
        q = parse(value)[0]
        payload = json.loads(core.build_messages(q.display_text, [], imported=q)[1]['content'])
        self.assertEqual(payload['visible_choices'][0]['text'], '거짓')
        for choice, signal in [('false', 0), ('true', 5)]:
            self.assertEqual(core.validate_answer(answer(choice), q.options, [], q.type).signal_index, signal)
        self.assertIsNone(core.validate_answer(answer('false', 'Uncertain'), q.options, [], q.type).clipboard_text)
        with self.assertRaises(core.ValidationError):
            core.validate_answer(answer('1'), q.options, [], q.type)

    def test_rejects_malformed_truncated_duplicate_keys(self):
        for raw in (b'{', b'{"schema":"dot-question/v1","schema":"dot-question/v1","groups":[]}', b'[]', b'\xff', b'null', b' ' * (core.MAX_IMPORT_BYTES + 1)):
            with self.subTest(raw=raw[:60]), self.assertRaises(core.ValidationError):
                core.parse_question_import(raw)

    def test_rejects_invalid_schema_and_limits(self):
        mutations = [
            lambda v: v.update(extra=True),
            lambda v: v.update(schema='other'),
            lambda v: v['groups'][0].pop('id'),
            lambda v: v['groups'].append(copy.deepcopy(v['groups'][0])),
            lambda v: v['groups'][0]['questions'].append(copy.deepcopy(v['groups'][0]['questions'][0])),
            lambda v: v['groups'][0].update(context='x' * 30001),
            lambda v: v['groups'][0]['questions'][0].update(type='unknown'),
            lambda v: v['groups'][0]['questions'][0].update(choices=[]),
            lambda v: v['groups'][0]['questions'][0]['choices'].append({'label': 'A', 'text': 'duplicate'}),
            lambda v: v['groups'][0]['questions'][0].update(choices=[{'label': str(i), 'text': 'x'} for i in range(6)]),
            lambda v: v['groups'][0].update(questions=[dict(id=str(i), type='short_answer', text='x', choices=[]) for i in range(51)]),
            lambda v: v['groups'][0]['questions'][0].update(text='\ud800'),
        ]
        for mutate in mutations:
            value = fixture(); mutate(value)
            with self.subTest(mutation=mutate), self.assertRaises((core.ValidationError, UnicodeError)):
                parse(value)

    def test_modified_imported_text_rejected(self):
        q = parse(fixture())[0]
        with self.assertRaises(core.ValidationError):
            core.build_messages('Changed', [], imported=q)

    def test_ollama_typed_request_and_response(self):
        q = parse(fixture('true_false'))[0]
        def http(url, payload=None, **kwargs):
            if url.endswith('/api/tags'):
                return {'models': [{'name': core.DEFAULT_OLLAMA_MODEL, 'size': 100, 'digest': 'fixture', 'details': {'format': 'gguf'}}]}
            data = json.loads(payload['messages'][1]['content'])
            self.assertEqual(data['question_type'], 'true_false')
            return {'done': True, 'message': {'content': json.dumps(answer('false'))}}
        with patch.object(core, '_request_json', side_effect=http):
            result = core.OllamaClient().answer(core.DEFAULT_OLLAMA_MODEL, q.display_text, [], imported=q)
        self.assertEqual(result.signal_index, 0)
        self.assertEqual(result.question_type, 'true_false')

    def test_oversized_context_rejected_before_network_without_truncation(self):
        value = fixture('short_answer'); value['groups'][0]['context'] = 'x' * 15000
        q = parse(value)[0]
        with patch.object(core, '_request_json') as network, self.assertRaises(core.ValidationError):
            core.OllamaClient().answer(core.DEFAULT_OLLAMA_MODEL, q.display_text, [], imported=q)
        network.assert_not_called()

    def test_escaped_surrogate_and_unknown_question_fields_rejected(self):
        raw = json.dumps(fixture()).replace('Prompt?', r'\ud800').encode()
        with self.assertRaises(core.ValidationError): core.parse_question_import(raw)
        value = fixture(); value['groups'][0]['questions'][0]['answer'] = 'hidden answer'
        with self.assertRaises(core.ValidationError): parse(value)
