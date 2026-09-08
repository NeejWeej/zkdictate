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

MODELS = {
    'whisper': 'mlx-community/whisper-large-v3-turbo',
    'whisper-8bit': 'mlx-community/whisper-large-v3-turbo-8bit',
}

# Revisions tested with both models; new installs must load the same artifacts.
MODEL_REVISIONS = {
    'whisper': 'a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb',
    'whisper-8bit': '62103fc276a35fdc76e318f314d8ff47987fba89',
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
            for filename in ('model.safetensors', 'weights.safetensors', 'weights.npz')
        ):
            raise LocalEntryNotFoundError('Incomplete cached model')
    except LocalEntryNotFoundError:
        snapshot = Path(snapshot_download(repo_id=repo, revision=MODEL_REVISIONS[name]))
    if (snapshot / 'model.safetensors').exists():
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
            import mlx_whisper
            module = importlib.import_module('mlx_whisper.transcribe')
            model_name = resources.enter_context(model_path(model_name))
            model = module.ModelHolder.get_model(model_name, mx.float16)
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
                    result = mlx_whisper.transcribe(audio, path_or_hf_repo=model_name)
                    emit({'event': 'transcript', 'id': request_id, 'text': result.get('text', '').strip()})
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
