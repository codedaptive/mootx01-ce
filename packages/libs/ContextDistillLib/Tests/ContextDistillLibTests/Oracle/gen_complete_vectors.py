"""Print synthetic complete-v6 native parity vectors; run with lab recipes on PYTHONPATH."""
import json
from tokensaver_composed_v6 import distill
from tokensaver_timestamp_prefixes import INTRO

rows = [{'kind': 'func', 'name': f'veryLongMethodName{i}',
         'signature': f'public func veryLongMethodName{i}(input: String) -> String',
         'module': 'ContextDistillLib'} for i in range(60)]
line = '- [[001-long-linked-entry-name]] - low - ' + 'Complete qualified description ' * 5 + '\n'
clocks = 'Title\n## Transcript\n' + ''.join(f'[00:{i:02}] Spoken segment.\n' for i in range(50))
index = '# Index\n\n' + ''.join(f'## `file{i}`\n\n{line}\n' for i in range(20))
times = ''.join(f'2026-09-08T10:{i:02} (Bob in a long named channel) — message {i}\n' for i in range(30))
cases = {
    'plain': 'Nora may arrive tomorrow, unless the train is cancelled.\r\n',
    'clocks': clocks,
    'large-clocks': '## Transcript\n' + ''.join(f'[{"9" * 30}:{i:02}] Spoken segment.\n' for i in range(50)),
    'unicode-clocks': clocks.translate(str.maketrans('0123456789', '٠١٢٣٤٥٦٧٨٩')),
    'tables': json.dumps([{'very_long_column_name': i, 'another_long_column_name': 'value'} for i in range(30)]),
    'references': ('An exact ordinary repeated line with a substantive qualification: ' + 'words ' * 20 + '\r\n') * 20,
    'visible': index,
    'blocks': 'Before\n' + json.dumps({'a': list(range(30)), 'b': {'nested': 'value'}}, indent=4) + '\nAfter\n',
    'declarations': json.dumps(rows),
    'timestamps': times,
    'composition': times + '\n' + json.dumps(rows, indent=2) + '\n' + index,
    'invalid-json': '{ "a":1, "a":2 }\n{ "float":1.0 }\n{ "zero":-0 }\n',
    'fences': '```json\n' + json.dumps(rows, indent=2) + '\n```\n',
    'timestamp-collision': INTRO + 'literal text',
    'unicode-repeats': (('e\u0301 ' + 'long line ' * 20 + '\n') + ('é ' + 'long line ' * 20 + '\n')) * 10,
}

def estimate(s):
    return (3 * len(s.encode()) + 16 * len(s.split()) + 12) // 24 if s.split() else 0

vectors = []
for name, source in cases.items():
    for counter, count in [('estimate', estimate), ('utf8', lambda s: len(s.encode()))]:
        vectors.append({'name': name, 'counter': counter, 'source': source, **distill(source, count)})
print(json.dumps({'version': 'complete-form-visible-v6', 'vectors': vectors}, ensure_ascii=False, indent=2))
