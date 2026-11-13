import contextlib
import tempfile
import base64
import io
import importlib.metadata
import json
import os
import runpy
from pathlib import Path
import signal
import subprocess
import sys
import threading
import types
import unittest
from unittest.mock import Mock, patch
import numpy as np
from zkdictate.app_worker import decode_audio, engine, model_path, transcribe_parakeet


@contextlib.contextmanager
def parakeet_without_metal():
    """Use the real CPU-only merger, but no model weights or GPU in unit tests."""
    alignment = types.ModuleType('parakeet_mlx.alignment')
    path = importlib.metadata.distribution('parakeet-mlx').locate_file('parakeet_mlx/alignment.py')
    alignment.__dict__.update(runpy.run_path(str(path)))
    core = types.ModuleType('mlx.core')
    core.array, core.float32, core.pad = np.array, np.float32, np.pad
    mlx = types.ModuleType('mlx'); mlx.core = core
    audio = types.ModuleType('parakeet_mlx.audio')
    audio.get_logmel = Mock(side_effect=lambda chunk, _: chunk)
    parakeet = types.ModuleType('parakeet_mlx'); parakeet.audio = audio
    with patch.dict(sys.modules, {'mlx': mlx, 'mlx.core': core, 'parakeet_mlx': parakeet,
                                 'parakeet_mlx.audio': audio, 'parakeet_mlx.alignment': alignment}):
        yield audio.get_logmel


class AppWorkerTests(unittest.TestCase):
    def test_parakeet_long_audio_merges_overlap_without_repeating_tail(self):
        mel = self.enterContext(parakeet_without_metal())
        from parakeet_mlx.alignment import AlignedToken, sentences_to_result, tokens_to_sentences
        model = Mock()
        model.preprocessor_config = types.SimpleNamespace(sample_rate=16000, n_fft=512)
        def result(words):
            return [sentences_to_result(tokens_to_sentences([
                AlignedToken(i, word, start, .25) for i, word, start in words
            ]))]
        model.generate.side_effect = [
            result([(1, 'Hello', 1), (2, ' brave', 27), (3, ' new', 28), (4, ' world', 29)]),
            result([(2, ' brave', 2), (3, ' new', 3), (4, ' world', 4), (5, ' today.', 24)]),
        ]
        text = transcribe_parakeet(model, np.zeros(16000 * 55, dtype='<f4'))
        self.assertEqual(text, 'Hello brave new world today.')
        self.assertEqual([len(call.args[0]) for call in mel.call_args_list], [16000 * 30] * 2)

    def test_parakeet_short_audio_is_padded_and_silence_stays_empty(self):
        mel = self.enterContext(parakeet_without_metal())
        model = Mock()
        model.preprocessor_config = types.SimpleNamespace(sample_rate=16000, n_fft=512)
        model.generate.return_value = [types.SimpleNamespace(text='')]
        self.assertEqual(transcribe_parakeet(model, np.zeros(1, dtype='<f4')), '')
        self.assertEqual(len(mel.call_args.args[0]), 512)

    def test_parakeet_cache_preserves_original_weights_filename(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / 'config.json').write_text('{}')
            (folder / 'model.safetensors').write_bytes(b'weights')
            with patch('huggingface_hub.snapshot_download', return_value=directory) as download:
                with model_path('parakeet') as path:
                    self.assertEqual(path, directory)
                    self.assertTrue((Path(path) / 'model.safetensors').is_file())
                download.assert_called_once_with(repo_id='mlx-community/parakeet-tdt-0.6b-v3', revision='ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15', local_files_only=True)

    def test_parakeet_worker_reuses_model_and_applies_processors(self):
        core = types.ModuleType('mlx.core'); core.eval = Mock()
        mlx = types.ModuleType('mlx'); mlx.core = core
        parakeet = types.ModuleType('parakeet_mlx'); parakeet.from_pretrained = Mock()
        audio = base64.b64encode(np.zeros(320, dtype='<f4')).decode()
        data = ''.join(json.dumps({'command': 'transcribe', 'id': str(i), 'audio': audio,
                                 'processors': [{'name': 'spoken_commands'}]}) + '\n'
                       for i in range(2)).encode()
        stdout = io.StringIO()
        def decode(model, samples):
            self.assertIs(model, parakeet.from_pretrained.return_value)
            np.testing.assert_array_equal(samples, np.zeros(320, dtype='<f4'))
            print('library progress')
            return ' hello comma world '
        with patch('zkdictate.app_worker.model_path', return_value=contextlib.nullcontext('/cached/parakeet')), patch.dict(sys.modules, {'mlx': mlx, 'mlx.core': core, 'parakeet_mlx': parakeet}), patch('zkdictate.app_worker.transcribe_parakeet', side_effect=decode) as transcribe, patch.object(sys, 'stdin', types.SimpleNamespace(buffer=io.BytesIO(data))), patch.object(sys, 'stdout', stdout), patch.object(sys, 'stderr', io.StringIO()):
            self.assertEqual(engine('parakeet'), 0)
        messages = [json.loads(line) for line in stdout.getvalue().splitlines()]
        self.assertEqual([m['event'] for m in messages], ['loading', 'ready', 'transcript', 'transcript'])
        self.assertEqual([m['text'] for m in messages[2:]], ['hello, world'] * 2)
        self.assertEqual([m['id'] for m in messages[2:]], ['0', '1'])
        parakeet.from_pretrained.assert_called_once_with('/cached/parakeet')
        self.assertEqual(transcribe.call_count, 2)

    def test_cached_quantized_model_adapts_filename_without_network(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / 'config.json').write_text('{}')
            (folder / 'model.safetensors').write_bytes(b'weights')
            with patch('huggingface_hub.snapshot_download', return_value=directory) as download:
                with model_path('whisper-8bit') as path:
                    view = Path(path)
                    self.assertEqual((view / 'weights.safetensors').read_bytes(), b'weights')
                    self.assertTrue((view / 'weights.safetensors').is_symlink())
                    self.assertTrue((view / 'config.json').exists())
                self.assertFalse(view.exists())
                download.assert_called_once_with(repo_id='mlx-community/whisper-large-v3-turbo-8bit', revision='62103fc276a35fdc76e318f314d8ff47987fba89', local_files_only=True)
            self.assertFalse((folder / 'weights.safetensors').exists())

    def test_uncached_model_downloads_then_uses_local_path(self):
        from huggingface_hub.errors import LocalEntryNotFoundError
        with tempfile.TemporaryDirectory() as directory:
            with patch('huggingface_hub.snapshot_download', side_effect=[LocalEntryNotFoundError('missing'), directory]) as download:
                with model_path('whisper') as path:
                    self.assertEqual(path, directory)
                self.assertEqual(download.call_count, 2)
                self.assertEqual(download.call_args.kwargs, {'repo_id': 'mlx-community/whisper-large-v3-turbo', 'revision': 'a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb'})

    def test_incomplete_cache_resumes_download(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'config.json').write_text('{}')
            with patch('huggingface_hub.snapshot_download', return_value=directory) as download:
                with model_path('whisper'):
                    pass
                self.assertEqual(download.call_count, 2)
                self.assertEqual(download.call_args.kwargs, {'repo_id': 'mlx-community/whisper-large-v3-turbo', 'revision': 'a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb'})

    def test_audio_validation(self):
        audio=np.zeros(320,dtype='<f4')
        np.testing.assert_array_equal(decode_audio(base64.b64encode(audio).decode()),audio)
        for value in (None,'!',base64.b64encode(b'a').decode(),base64.b64encode(np.array([np.nan],dtype='<f4')).decode()):
            with self.assertRaises((ValueError,TypeError)): decode_audio(value)

    def test_load_and_repeated_transcriptions_share_thread_and_private_protocol(self):
        identities=[]
        core=types.ModuleType('mlx.core');core.float16='float16'
        core.eval=lambda _:identities.append(threading.get_ident())
        mlx=types.ModuleType('mlx');mlx.core=core
        whisper=types.ModuleType('mlx_whisper')
        def transcribe(*_,**__):
            identities.append(threading.get_ident());print('library progress')
            return {'text':'spoken text'}
        whisper.transcribe=transcribe
        holder=Mock();holder.ModelHolder.get_model.return_value.parameters.return_value=[]
        audio=base64.b64encode(np.zeros(320,dtype='<f4')).decode()
        data=''.join(json.dumps({'command':'transcribe','id':str(i),'audio':audio})+'\n' for i in range(2)).encode()
        stdin=types.SimpleNamespace(buffer=io.BytesIO(data));stdout=io.StringIO();stderr=io.StringIO()
        with patch('zkdictate.app_worker.model_path', return_value=contextlib.nullcontext('/cached/model')),patch.dict(sys.modules,{'mlx':mlx,'mlx.core':core,'mlx_whisper':whisper}),patch('importlib.import_module',return_value=holder),patch.object(sys,'stdin',stdin),patch.object(sys,'stdout',stdout),patch.object(sys,'stderr',stderr):
            self.assertEqual(engine(),0)
        messages=[json.loads(line) for line in stdout.getvalue().splitlines()]
        self.assertEqual([m['event'] for m in messages],['loading','ready','transcript','transcript'])
        self.assertEqual([(m['text'],m['warnings']) for m in messages[2:]],[('spoken text',[])]*2)
        holder.ModelHolder.get_model.assert_called_once_with('/cached/model', 'float16')
        self.assertEqual(len(set(identities)),1)
        self.assertNotIn('library progress',stdout.getvalue())
        self.assertNotIn('spoken text',stderr.getvalue())

    def test_request_processors_rewrite_transcript_or_warn(self):
        core=types.ModuleType('mlx.core');core.float16='float16';core.eval=lambda _:None
        mlx=types.ModuleType('mlx');mlx.core=core
        whisper=types.ModuleType('mlx_whisper');whisper.transcribe=lambda *_,**__:{'text':' spoken text '}
        holder=Mock();holder.ModelHolder.get_model.return_value.parameters.return_value=[]
        audio=base64.b64encode(np.zeros(320,dtype='<f4')).decode()
        upper={'name':'external_command','path':sys.executable,'args':['-c','import sys;print(sys.stdin.read().upper())']}
        broken={'name':'external_command','path':sys.executable,'args':['-c','raise SystemExit(2)']}
        data=''.join(json.dumps({'command':'transcribe','id':str(i),'audio':audio,'processors':steps})+'\n' for i,steps in enumerate([[upper],[broken]])).encode()
        stdin=types.SimpleNamespace(buffer=io.BytesIO(data));stdout=io.StringIO()
        with patch('zkdictate.app_worker.model_path', return_value=contextlib.nullcontext('/cached/model')),patch.dict(sys.modules,{'mlx':mlx,'mlx.core':core,'mlx_whisper':whisper}),patch('importlib.import_module',return_value=holder),patch.object(sys,'stdin',stdin),patch.object(sys,'stdout',stdout):
            self.assertEqual(engine(),0)
        messages=[json.loads(line) for line in stdout.getvalue().splitlines()][2:]
        self.assertEqual([(m['text'],m['warnings']) for m in messages],[('SPOKEN TEXT',[]),('spoken text',['External command skipped: exited with status 2.'])])

    def test_bundled_script_loads_processors_beside_it(self):
        source=Path(__file__).resolve().parents[1]/'src/zkdictate'
        with tempfile.TemporaryDirectory() as directory:
            for name in ('app_worker.py','text_processors.py'): (Path(directory)/name).write_bytes((source/name).read_bytes())
            subprocess.run([sys.executable,'-I',str(Path(directory)/'app_worker.py'),'--help'],cwd='/',check=True,capture_output=True)

    def test_guardian_kills_stuck_engine_on_eof_and_termination(self):
        # This dummy engine ignores SIGTERM; guardian must escalate and reap it.
        dummy="import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print(os.getpid(),flush=True); time.sleep(60)"
        for terminate in (False,True):
            code='from zkdictate.app_worker import supervise; import os,sys; sys.exit(supervise(os.getppid(), [sys.executable,"-c",sys.argv[1]]))'
            guardian=subprocess.Popen([sys.executable,'-c',code,dummy],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                child_pid=int(guardian.stdout.readline())
                if terminate: guardian.terminate()
                else: guardian.stdin.close()
                guardian.wait(timeout=5)
                with self.assertRaises(ProcessLookupError): os.kill(child_pid,0)
            finally:
                if guardian.poll() is None: guardian.kill();guardian.wait()
                if guardian.stdin and not guardian.stdin.closed: guardian.stdin.close()
                guardian.stdout.close();guardian.stderr.close()
