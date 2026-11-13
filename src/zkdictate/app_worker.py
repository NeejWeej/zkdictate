"""Private pipe-based transcription service. No recording or filesystem outputs."""
from __future__ import annotations
import argparse
import base64
import contextlib
import json
import os
from pathlib import Path
import tempfile
import signal
import subprocess
import sys
import threading

try:
    from . import text_processors
except ImportError:
    # The app runs this file as a script with -I, so load the copy beside it.
    import importlib.util
    _spec = importlib.util.spec_from_file_location('text_processors', Path(__file__).with_name('text_processors.py'))
    text_processors = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(text_processors)

MODELS = {
    'whisper': 'mlx-community/whisper-large-v3-turbo',
    'whisper-8bit': 'mlx-community/whisper-large-v3-turbo-8bit',
    'parakeet': 'mlx-community/parakeet-tdt-0.6b-v3',
}

# Pinned revisions; new installs must load the same artifacts.
MODEL_REVISIONS = {
    'whisper': 'a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb',
    'whisper-8bit': '62103fc276a35fdc76e318f314d8ff47987fba89',
    'parakeet': 'ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15',
}


@contextlib.contextmanager
def model_path(name):
    """Use cached weights offline; adapt the newer filename without modifying them."""
    from huggingface_hub import snapshot_download
    from huggingface_hub.errors import LocalEntryNotFoundError
    repo = MODELS[name]
    try:
        snapshot = Path(snapshot_download(repo_id=repo, revision=MODEL_REVISIONS[name], local_files_only=True))
        if not (snapshot / 'config.json').is_file() or not any(
            (snapshot / filename).is_file()
            for filename in (('model.safetensors',) if name == 'parakeet' else
                             ('model.safetensors', 'weights.safetensors', 'weights.npz'))
        ):
            raise LocalEntryNotFoundError('Incomplete cached model')
    except LocalEntryNotFoundError:
        snapshot = Path(snapshot_download(repo_id=repo, revision=MODEL_REVISIONS[name]))
    if name != 'parakeet' and (snapshot / 'model.safetensors').exists():
        # mlx-whisper 0.4.x expects weights.safetensors. Keep this view alive for
        # the whole session so ModelHolder reuses the same model on every request.
        with tempfile.TemporaryDirectory(prefix='zkdictate-model-') as directory:
            view = Path(directory)
            (view / 'config.json').symlink_to(snapshot / 'config.json')
            (view / 'weights.safetensors').symlink_to(snapshot / 'model.safetensors')
            yield str(view)
    else:
        yield str(snapshot)


MAX_FRAME = 64 * 1024 * 1024
MAX_AUDIO = 16000 * 4 * 600


def decode_audio(value):
    import numpy as np
    if not isinstance(value, str) or len(value) > MAX_FRAME:
        raise ValueError('Invalid audio payload')
    data = base64.b64decode(value, validate=True)
    if not data or len(data) > MAX_AUDIO or len(data) % 4:
        raise ValueError('Invalid audio length')
    audio = np.frombuffer(data, dtype='<f4').copy()
    if not np.isfinite(audio).all():
        raise ValueError('Invalid audio samples')
    return audio


def transcribe_parakeet(model, audio):
    """Decode recorded PCM in memory; bound encoder memory on long dictations.

    Mirrors parakeet-mlx's file transcription chunking without writing audio
    to disk or requiring ffmpeg. This runs only after the hotkey is released.
    """
    import mlx.core as mx
    from parakeet_mlx.audio import get_logmel
    from parakeet_mlx.alignment import (
        merge_longest_contiguous, merge_longest_common_subsequence,
        sentences_to_result, tokens_to_sentences,
    )
    config = model.preprocessor_config
    if config.sample_rate != 16000:
        raise ValueError('Parakeet requires a 16 kHz model')
    chunk_samples, overlap_samples = 16000 * 30, 16000 * 5
    tokens = []
    for start in range(0, len(audio), chunk_samples - overlap_samples):
        end = min(start + chunk_samples, len(audio))
        chunk = mx.array(audio[start:end], dtype=mx.float32)
        # Very short valid requests still need enough samples for the FFT.
        if len(chunk) < config.n_fft:
            chunk = mx.pad(chunk, [(0, config.n_fft - len(chunk))])
        result = model.generate(get_logmel(chunk, config))[0]
        if start == 0 and end == len(audio):
            return result.text
        for token in result.tokens:
            token.start += start / 16000
            token.end = token.start + token.duration
        try:
            tokens = merge_longest_contiguous(tokens, result.tokens, overlap_duration=5)
        except RuntimeError:
            tokens = merge_longest_common_subsequence(tokens, result.tokens, overlap_duration=5)
        if end == len(audio):
            break
    return sentences_to_result(tokens_to_sentences(tokens)).text


def engine(model_name="whisper-8bit"):
    wire = sys.stdout
    def emit(value):
        wire.write(json.dumps(value) + '\n'); wire.flush()
    # Third-party progress output must never corrupt the JSON protocol.
    with contextlib.redirect_stdout(sys.stderr), contextlib.ExitStack() as resources:
        try:
            emit({'event': 'loading'})
            import importlib
            import mlx.core as mx
            path = resources.enter_context(model_path(model_name))
            if model_name == 'parakeet':
                from parakeet_mlx import from_pretrained
                model = from_pretrained(path)
                transcribe = lambda audio: transcribe_parakeet(model, audio)
            else:
                import mlx_whisper
                module = importlib.import_module('mlx_whisper.transcribe')
                model = module.ModelHolder.get_model(path, mx.float16)
                transcribe = lambda audio: mlx_whisper.transcribe(audio, path_or_hf_repo=path).get('text', '')
            mx.eval(model.parameters())
            emit({'event': 'ready'})
            while True:
                line = sys.stdin.buffer.readline(MAX_FRAME + 1)
                if not line:
                    return 0
                if len(line) > MAX_FRAME or not line.endswith(b'\n'):
                    raise ValueError('Request exceeded size limit')
                request = json.loads(line)
                if not isinstance(request, dict) or request.get('command') != 'transcribe':
                    raise ValueError('Unknown request')
                request_id = request.get('id')
                if not isinstance(request_id, str) or len(request_id) > 64:
                    raise ValueError('Invalid request identifier')
                try:
                    audio = decode_audio(request.get('audio'))
                    text, warnings = text_processors.process(transcribe(audio).strip(), request.get('processors'))
                    emit({'event': 'transcript', 'id': request_id, 'text': text, 'warnings': warnings})
                except Exception as exc:
                    emit({'event': 'error', 'id': request_id, 'message': str(exc)[:1000]})
        except Exception as exc:
            emit({'event': 'error', 'message': str(exc)[:1000]})
            return 1


def supervise(parent_pid, worker_command=None, model="whisper-8bit"):
    if parent_pid <= 0 or os.getppid() != parent_pid:
        return 1
    stopped = threading.Event()
    def stop(*_): stopped.set()
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP): signal.signal(sig, stop)
    child = subprocess.Popen(worker_command or [sys.executable, '-I', __file__, '--engine', '--model', model], stdin=subprocess.PIPE, start_new_session=True)
    def relay():
        try:
            while not stopped.is_set():
                data = os.read(0, 65536)
                if not data: break
                child.stdin.write(data); child.stdin.flush()
        except (BrokenPipeError, OSError): pass
        finally: stopped.set()
    threading.Thread(target=relay, daemon=True).start()
    try:
        while not stopped.wait(.2):
            code = child.poll()
            if code is not None: return 128 - code if code < 0 else code
            if os.getppid() != parent_pid: break
    finally:
        if child.poll() is None:
            try: os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError: pass
            try: child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                try: os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                child.wait(timeout=2)
    return 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--engine', action='store_true')
    parser.add_argument('--parent-pid', type=int)
    parser.add_argument('--model', choices=MODELS, default='whisper-8bit')
    args = parser.parse_args()
    raise SystemExit(engine(args.model) if args.engine else supervise(args.parent_pid or 0, model=args.model))
