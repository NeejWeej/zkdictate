"""Optional transcript rewriting. A failed step keeps the text from before it."""
from __future__ import annotations
import os
import re
import select
import signal
import subprocess
import threading
import time

TIMEOUT = 5
MAX_OUTPUT = 1024 * 1024


class ProcessorError(Exception):
    """A short, content-free reason shown to the user."""


def _feed(pipe, data):
    try: pipe.write(data)
    except (BrokenPipeError, OSError): pass
    finally:
        try: pipe.close()
        except OSError: pass


def run_command(argv, text, timeout=TIMEOUT, limit=MAX_OUTPUT):
    """Run argv without a shell: text on stdin, bounded stdout back, stderr discarded."""
    try:
        process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        raise ProcessorError('could not start') from None
    try:
        threading.Thread(target=_feed, args=(process.stdin, text.encode()), daemon=True).start()
        deadline = time.monotonic() + timeout
        output = bytearray()
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0: raise ProcessorError('timed out')
            if not select.select([process.stdout], [], [], remaining)[0]: continue
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk: break
            output += chunk
            if len(output) > limit: raise ProcessorError('output too large')
        try: code = process.wait(max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired: raise ProcessorError('timed out') from None
        if code: raise ProcessorError(f'exited with status {code}')
        try: return output.decode()
        except UnicodeDecodeError: raise ProcessorError('output is not UTF-8') from None
    finally:
        if process.poll() is None:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait()
        process.stdout.close()


def external_command(config):
    path, args = config.get('path'), config.get('args', [])
    if not isinstance(path, str) or not path:
        raise ProcessorError('no command chosen')
    if not os.path.isabs(path) or not isinstance(args, list) or not all(isinstance(a, str) for a in args):
        raise ProcessorError('invalid command settings')
    def run(text):
        result = run_command([path, *args], text).strip()
        # An empty result would silently discard the dictation.
        if not result: raise ProcessorError('returned no text')
        return result
    return run


# How a symbol meets its neighbours: ATTACH joins the word before it (. ) ),
# OPEN joins the word after it ( ( $ ), JOIN joins both (- /), SPACED keeps a
# space on both sides (— +), LINE breaks the line, and QUOTE opens or closes by turn.
ATTACH, OPEN, JOIN, SPACED, LINE, QUOTE = 'attach', 'open', 'join', 'spaced', 'line', 'quote'

# Symbol, spacing, spoken forms. Forms match whole words in any case; a space
# also matches a hyphen, as Whisper sometimes writes "full-stop". Symbols that
# are also everyday words use their "... sign" name, so normal speech is kept.
SPOKEN_COMMANDS = [
    ('.', ATTACH, ['period', 'full stop']),
    (',', ATTACH, ['comma']),
    ('?', ATTACH, ['question mark']),
    ('!', ATTACH, ['exclamation point', 'exclamation mark']),
    (':', ATTACH, ['colon']),
    (';', ATTACH, ['semicolon', 'semi colon']),
    ('...', ATTACH, ['ellipsis', 'dot dot dot']),
    ('(', OPEN, ['open parenthesis', 'open parentheses', 'open paren', 'left parenthesis', 'left paren']),
    (')', ATTACH, ['close parenthesis', 'close parentheses', 'close paren', 'closed parenthesis',
                   'closed parentheses', 'closed paren', 'right parenthesis', 'right paren']),
    ('[', OPEN, ['open bracket', 'open square bracket', 'left bracket']),
    (']', ATTACH, ['close bracket', 'close square bracket', 'closed bracket', 'closed square bracket', 'right bracket']),
    ('{', OPEN, ['open brace', 'open curly brace', 'open curly bracket', 'left brace']),
    ('}', ATTACH, ['close brace', 'close curly brace', 'close curly bracket', 'closed brace',
                   'closed curly brace', 'closed curly bracket', 'right brace']),
    ('"', OPEN, ['open quote', 'begin quote', 'start quote']),
    ('"', ATTACH, ['close quote', 'closed quote', 'end quote', 'unquote']),
    ('"', QUOTE, ['quote']),
    ("'", QUOTE, ['single quote']),
    ('`', QUOTE, ['backtick', 'back tick', 'backquote', 'back quote']),
    ("'", JOIN, ['apostrophe']),
    ('-', JOIN, ['hyphen']),
    ('/', JOIN, ['slash', 'forward slash']),
    ('\\', JOIN, ['backslash', 'back slash']),
    ('@', JOIN, ['at sign', 'at symbol']),
    ('_', JOIN, ['underscore']),
    ('^', JOIN, ['caret']),
    ('$', OPEN, ['dollar sign']),
    ('#', OPEN, ['hash sign', 'pound sign', 'hashtag']),
    ('~', OPEN, ['tilde']),
    ('%', ATTACH, ['percent sign']),
    ('—', SPACED, ['dash']),
    ('&', SPACED, ['ampersand']),
    ('*', SPACED, ['asterisk']),
    ('+', SPACED, ['plus sign']),
    ('=', SPACED, ['equals sign', 'equal sign']),
    ('|', SPACED, ['vertical bar', 'pipe sign', 'pipe symbol']),
    ('<', SPACED, ['less than sign']),
    ('>', SPACED, ['greater than sign']),
    ('\n', LINE, ['new line', 'newline']),
    ('\n\n', LINE, ['new paragraph']),
    ('\t', LINE, ['tab key', 'tab character']),
]
_COMMANDS = {form: (symbol, spacing) for symbol, spacing, forms in SPOKEN_COMMANDS for form in forms}
_QUOTES = {symbol for symbol, spacing, _ in SPOKEN_COMMANDS if spacing == QUOTE}
# "literal <command>" keeps the command's words; Whisper may write "Literal, period".
_LITERAL = re.compile(r'literal[,.:;]?\s+', re.IGNORECASE)
_COMMAND = re.compile(r"(?<![\w'-])((?:" + _LITERAL.pattern + ')?(?:' + '|'.join(
    r'[\s-]+'.join(map(re.escape, form.split())) for form in sorted(_COMMANDS, key=len, reverse=True)
) + r"))(?![\w'-])", re.IGNORECASE)
# Whisper adds its own punctuation around each pause, so a spoken command is
# usually written "..., comma, ..." or "close parenthesis." That punctuation is
# dropped after every command and, as listed here, before it.
_PAUSE = ',.;:!?…'
_DROP_BEFORE = {ATTACH: _PAUSE, JOIN: _PAUSE, OPEN: ',', SPACED: ',', LINE: ',;:'}


def _command(spoken, quoted):
    symbol, spacing = _COMMANDS[' '.join(spoken.lower().replace('-', ' ').split())]
    if spacing == QUOTE: spacing = ATTACH if symbol in quoted else OPEN
    return symbol, spacing


def _keep_literals(parts):
    """Fold each "literal <command>" back into the text around it, minus "literal"."""
    kept = [parts[0]]
    for index in range(1, len(parts), 2):
        spoken, after = parts[index], parts[index + 1]
        prefix = _LITERAL.match(spoken)
        if not prefix:
            kept += [spoken, after]
            continue
        words = spoken[prefix.end():]
        if spoken[0].isupper(): words = words[0].upper() + words[1:]
        # A comma before "literal" is Whisper marking the pause.
        before = kept[-1].rstrip(' \t').removesuffix(',')
        kept[-1] = (before + ' ' if before else '') + words + after
    return kept


def spoken_commands(text):
    parts = _COMMAND.split(text)
    if len(parts) == 1: return text
    parts = _keep_literals(parts)
    out, glue, quoted = '', True, set()
    for index, part in enumerate(parts):
        if index % 2 == 0:
            if index: part = part.lstrip(_PAUSE + ' \t')
            if index < len(parts) - 1:
                part = part.rstrip(' \t').rstrip(_DROP_BEFORE[_command(parts[index + 1], quoted)[1]]).rstrip(' \t')
            if not part: continue
            end = out.rstrip()
            if end[-1:] in ('.', '?', '!') and not end.endswith('...') and part[0].isalpha():
                part = part[0].upper() + part[1:]
            out += part if glue else ' ' + part
            glue = False
            continue
        symbol, spacing = _command(part, quoted)
        if symbol in _QUOTES and spacing == OPEN: quoted.add(symbol)
        elif symbol in _QUOTES and spacing == ATTACH: quoted.discard(symbol)
        if spacing == ATTACH: out, glue = out.rstrip(' ') + symbol, False
        elif spacing == OPEN: out, glue = out + (symbol if glue else ' ' + symbol), True
        elif spacing == JOIN: out, glue = out.rstrip(' ') + symbol, True
        elif spacing == SPACED: out, glue = (out.rstrip(' ') + ' ' if out else '') + symbol + ' ', True
        else: out, glue = out.rstrip(' ') + symbol, True
    return out.strip(' ')


# Factories receive the request's settings for that step and return fn(text) -> str.
# Steps always run in this order, whatever order the request lists them in.
PROCESSORS = {
    'spoken_commands': ('Spoken punctuation', lambda _: spoken_commands),
    'external_command': ('External command', external_command),
}


def process(text, steps):
    """Apply enabled steps; return the text and short warnings for skipped steps."""
    if not text or steps is None: return text, []
    if not isinstance(steps, list) or not all(isinstance(s, dict) for s in steps):
        return text, ['Text processing skipped: invalid settings.']
    configs = {s.get('name'): s for s in steps}
    warnings = ['Unknown text processor skipped.' for name in configs if name not in PROCESSORS]
    for name, (title, factory) in PROCESSORS.items():
        if name not in configs: continue
        try:
            result = factory(configs[name])(text)
            if not isinstance(result, str): raise ProcessorError('returned no text')
            text = result
        except ProcessorError as exc:
            warnings.append(f'{title} skipped: {exc}.')
        except Exception:
            # Exception text could quote the transcript; report only the step.
            warnings.append(f'{title} skipped: failed.')
    return text, warnings
