"""Check the design contract and client compatibility, not a running API."""
from copy import deepcopy
import json
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator, FormatChecker, ValidationError
from openapi_spec_validator import validate

SPEC = json.loads(Path(__file__).with_name('sync-v1.openapi.json').read_text(encoding='utf-8'))
SCHEMAS = SPEC['components']['schemas']


def check(name, value):
    schema = {'$ref': f'#/components/schemas/{name}', 'components': SPEC['components']}
    Draft202012Validator(schema, format_checker=FormatChecker()).validate(value)


class ContractTests(unittest.TestCase):
    def test_openapi_structure(self):
        validate(SPEC)

    def test_all_schema_examples(self):
        checked = 0
        for name, schema in SCHEMAS.items():
            for example in schema.get('examples', []):
                with self.subTest(schema=name):
                    check(name, example)
                    checked += 1
        self.assertGreater(checked, 0)

    def test_all_media_examples(self):
        checked = 0

        def visit(node):
            nonlocal checked
            if isinstance(node, dict):
                if 'schema' in node and ('examples' in node or 'example' in node):
                    examples = [node['example']] if 'example' in node else [
                        x['value'] for x in node['examples'].values() if 'value' in x
                    ]
                    schema = dict(node['schema'], components=SPEC['components'])
                    for example in examples:
                        Draft202012Validator(schema, format_checker=FormatChecker()).validate(example)
                        checked += 1
                for child in node.values():
                    visit(child)
            elif isinstance(node, list):
                for child in node:
                    visit(child)

        visit(SPEC['paths'])
        self.assertGreater(checked, 0)

    def test_reserved_time_and_imported_ids_remain_compatible(self):
        event = deepcopy(SCHEMAS['Event']['examples'][0])
        event['id'] = 'whu-a1b2c3-example'
        event['title'] = ''
        event['notes'] = None
        check('Event', event)

    def test_invalid_deletion_has_no_implicit_create(self):
        mutation = deepcopy(SCHEMAS['Mutation']['examples'][1])
        mutation['base_revision'] = None
        with self.assertRaises(ValidationError):
            check('Mutation', mutation)

    def test_atomic_batch_is_bounded(self):
        batch = {
            'batch_id': '11111111-1111-4111-8111-111111111111',
            'device_id': '22222222-2222-4222-8222-222222222222',
            'dataset_id': '33333333-3333-4333-8333-333333333333',
            'sync_epoch': '44444444-4444-4444-8444-444444444444',
            'mutations': [deepcopy(SCHEMAS['Mutation']['examples'][0])],
        }
        check('BatchRequest', batch)
        batch['mutations'] = batch['mutations'] * 101
        with self.assertRaises(ValidationError):
            check('BatchRequest', batch)

    def test_local_version_cannot_replace_server_revision(self):
        check('Revision', '9007199254740993')
        for invalid in (4, 0, '0', '-1', '1.5'):
            with self.subTest(value=invalid), self.assertRaises(ValidationError):
                check('Revision', invalid)

    def test_timed_event_rejects_absent_instant(self):
        event = deepcopy(SCHEMAS['Event']['examples'][0])
        event['start_utc'] = None
        with self.assertRaises(ValidationError):
            check('Event', event)


if __name__ == '__main__':
    unittest.main(verbosity=2)
