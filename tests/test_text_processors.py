import sys
import time
import unittest
from unittest.mock import patch
from zkdictate import text_processors
from zkdictate.text_processors import ProcessorError, process, run_command


def command(code, *args):
    return {'name': 'external_command', 'path': sys.executable, 'args': ['-c', code, *args]}


class TextProcessorTests(unittest.TestCase):
    def test_missing_or_empty_steps_leave_text_alone(self):
        self.assertEqual(process('Hello.', None), ('Hello.', []))
        self.assertEqual(process('Hello.', []), ('Hello.', []))
        self.assertEqual(process('', [command('raise SystemExit(1)')]), ('', []))

    def test_steps_run_in_registry_order_and_failures_fall_back(self):
        calls = []
        def step(label, fail=False):
            def factory(_):
                def run(text):
                    calls.append(label)
                    if fail: raise RuntimeError(text)
                    return f'{text}+{label}'
                return run
            return (label.title(), factory)
        registry = {'a': step('a'), 'b': step('b', fail=True), 'c': step('c')}
        with patch.dict(text_processors.PROCESSORS, registry, clear=True):
            text, warnings = process('secret words', [{'name': 'c'}, {'name': 'b'}, {'name': 'a'}, {'name': 'zzz'}])
        self.assertEqual(calls, ['a', 'b', 'c'])
        self.assertEqual(text, 'secret words+a+c')
        self.assertEqual(warnings, ['Unknown text processor skipped.', 'B skipped: failed.'])
        self.assertNotIn('secret', ' '.join(warnings))

    def test_invalid_settings_keep_text(self):
        self.assertEqual(process('Hi', 'external_command'), ('Hi', ['Text processing skipped: invalid settings.']))
        for config in ({}, {'path': ''}, {'path': 'relative/tool'}, {'path': '/bin/cat', 'args': 'x'}, {'path': '/bin/cat', 'args': [1]}):
            text, warnings = process('Hi', [{'name': 'external_command', **config}])
            self.assertEqual(text, 'Hi')
            self.assertEqual(len(warnings), 1)
            self.assertTrue(warnings[0].startswith('External command skipped:'))

    def test_external_command_success_uses_stdin_args_and_strips_output(self):
        code = 'import sys; print(sys.stdin.read().upper() + sys.argv[1])'
        self.assertEqual(process('héllo', [command(code, '!')]), ('HÉLLO!', []))

    def test_external_command_failures_keep_previous_text(self):
        cases = {
            'exited with status 3': 'import sys; sys.stdout.write("partial"); sys.exit(3)',
            'returned no text': 'import sys; sys.stdin.read()',
            'output is not UTF-8': 'import sys; sys.stdout.buffer.write(b"\\xff")',
        }
        for reason, code in cases.items():
            with self.subTest(reason):
                self.assertEqual(process('keep me', [command(code)]), ('keep me', [f'External command skipped: {reason}.']))
        missing = {'name': 'external_command', 'path': '/nonexistent/zkdictate-tool'}
        self.assertEqual(process('keep me', [missing]), ('keep me', ['External command skipped: could not start.']))

    def test_timeout_kills_command(self):
        started = time.monotonic()
        with self.assertRaisesRegex(ProcessorError, 'timed out'):
            run_command([sys.executable, '-c', 'import time; time.sleep(30)'], 'x', timeout=0.5)
        self.assertLess(time.monotonic() - started, 5)
        with patch.object(text_processors, 'TIMEOUT', 0.5):
            self.assertEqual(process('keep', [command('import time; time.sleep(30)')]), ('keep', ['External command skipped: timed out.']))

    def test_oversized_output_is_refused(self):
        with self.assertRaisesRegex(ProcessorError, 'output too large'):
            run_command([sys.executable, '-c', 'import sys; sys.stdout.write("x" * 5000)'], '', limit=4096)
        flood = 'import sys\nwhile True: sys.stdout.write("x" * 65536)'
        self.assertEqual(process('keep', [command(flood)]), ('keep', ['External command skipped: output too large.']))

    def test_command_ignoring_stdin_with_large_input(self):
        self.assertEqual(run_command([sys.executable, '-c', 'print("ok")'], 'x' * 1_000_000), 'ok\n')



# Whisper output for each dictation, then the expected text.
SPOKEN = [
    ('Open parenthesis, foo, close parenthesis.', '(foo)'),
    ('Hello comma how are you question mark', 'Hello, how are you?'),
    ('Hello, comma, how are you? Question mark.', 'Hello, how are you?'),
    ('Is it ready question mark?', 'Is it ready?'),
    ('This is the end period. New paragraph. Next thing.', 'This is the end.\n\nNext thing.'),
    ('It works period it really works exclamation mark yes', 'It works. It really works! Yes'),
    ('Done full stop. Then we left, full-stop.', 'Done. Then we left.'),
    ('Wow, exclamation point.', 'Wow!'),
    ('Note colon, bring snacks semicolon, and drinks.', 'Note: bring snacks; and drinks.'),
    ('He said, quote, hello there, unquote.', 'He said "hello there"'),
    ('She said quote hi quote and left.', 'She said "hi" and left.'),
    ('Open quote, yes, close quote, she replied.', '"yes" she replied.'),
    ('The array open bracket zero close bracket.', 'The array [zero]'),
    ('Open brace, key colon value, close brace.', '{key: value}'),
    ('Call foo, open paren, x comma y, close paren, semicolon.', 'Call foo (x, y);'),
    ('A well hyphen known fact.', 'A well-known fact.'),
    ('Wait, dash, really? Exclamation point.', 'Wait — really!'),
    ('Well, ellipsis, I guess.', 'Well... I guess.'),
    ('Shopping list colon new line eggs new line milk.', 'Shopping list:\neggs\nmilk.'),
    ('Line one. New line. Line two.', 'Line one.\nLine two.'),
    ('Dear Sam, comma. New paragraph. Thanks for coming.', 'Dear Sam,\n\nThanks for coming.'),
    # Whisper often hears "closed" for "close".
    ('Open parenthesis, foo, closed parenthesis.', '(foo)'),
    ('Open bracket, a, closed bracket. Open brace b closed curly brace.', '[a] {b}'),
    ('Open quote, yes, closed quote.', '"yes"'),
    ('This is useful and slash or harmful.', 'This is useful and/or harmful.'),
    ('Tilde forward slash code.', '~/code.'),
    ('The path is C colon backslash users backslash matt.', 'The path is C:\\users\\matt.'),
    ('It costs dollar sign 5.', 'It costs $5.'),
    ('It costs, dollar sign, 5.', 'It costs $5.'),
    ('Salt ampersand pepper.', 'Salt & pepper.'),
    ('Email matt at sign example.com.', 'Email matt@example.com.'),
    ('Hash sign winning. Pound sign 1. Hashtag blessed.', '#winning. #1. #blessed.'),
    ('About 50 percent sign of people.', 'About 50% of people.'),
    ('2 asterisk 3 plus sign 4 equals sign 10.', '2 * 3 + 4 = 10.'),
    ('Use my underscore var.', 'Use my_var.'),
    ('Run, backtick, ls, backtick, now.', 'Run `ls` now.'),
    ('She said single quote hi single quote and left.', "She said 'hi' and left."),
    ('Rock apostrophe n apostrophe roll.', "Rock'n'roll."),
    ('cat file, vertical bar, grep x', 'cat file | grep x'),
    ('x less than sign y greater than sign z', 'x < y > z'),
    ('2 caret 8', '2^8'),
    ('Name colon, tab key, Bob.', 'Name:\tBob.'),
    # Quote styles open and close independently.
    ('Quote, a single quote b single quote, quote.', '"a \'b\'"'),
    # Spoken as a phrase, every command still converts.
    ('a slash and an open parenthesis and a closed parenthesis', 'a/and an (and a)'),
    # "literal" keeps the command's words, whatever Whisper does around it.
    ('It was a trial literal period.', 'It was a trial period.'),
    ('It was a trial, literal, period.', 'It was a trial period.'),
    ('Literal period, that is the word.', 'Period, that is the word.'),
    ('Say literal comma, then comma, done.', 'Say comma, then, done.'),
    ('Literally, a period.', 'Literally, a.'),
    ('PERIOD.', '.'),
    ('Question Mark', '?'),
    ('No commands here, just text.', 'No commands here, just text.'),
    ('Periodic, comma-separated, semicolonic quotes.', 'Periodic, comma-separated, semicolonic quotes.'),
    ('', ''),
]


class SpokenCommandTests(unittest.TestCase):
    def test_realistic_whisper_outputs(self):
        for spoken, expected in SPOKEN:
            with self.subTest(spoken):
                self.assertEqual(text_processors.spoken_commands(spoken), expected)

    def test_runs_before_external_command(self):
        upper = command('import sys; print(sys.stdin.read().upper())')
        self.assertEqual(process('hi comma there', [upper, {'name': 'spoken_commands'}]), ('HI, THERE', []))

    def test_every_table_entry_matches(self):
        for symbol, spacing, forms in text_processors.SPOKEN_COMMANDS:
            for form in forms:
                with self.subTest(form):
                    self.assertTrue(text_processors._COMMAND.fullmatch(form.upper()))
                    self.assertEqual(text_processors.spoken_commands(f'say literal {form} now'), f'say {form} now')


if __name__ == '__main__':
    unittest.main()
