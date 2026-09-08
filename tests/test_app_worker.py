import base64
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import types
import unittest
from unittest.mock import Mock, patch
import numpy as np
from zkdictate.app_worker import decode_audio, engine

class AppWorkerTests(unittest.TestCase):
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
        with patch.dict(sys.modules,{'mlx':mlx,'mlx.core':core,'mlx_whisper':whisper}),patch('importlib.import_module',return_value=holder),patch.object(sys,'stdin',stdin),patch.object(sys,'stdout',stdout),patch.object(sys,'stderr',stderr):
            self.assertEqual(engine(),0)
        messages=[json.loads(line) for line in stdout.getvalue().splitlines()]
        self.assertEqual([m['event'] for m in messages],['loading','ready','transcript','transcript'])
        self.assertEqual(len(set(identities)),1)
        self.assertNotIn('library progress',stdout.getvalue())
        self.assertNotIn('spoken text',stderr.getvalue())

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
