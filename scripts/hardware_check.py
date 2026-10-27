import fcntl, json, os, pathlib, select, signal, subprocess, sys, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
ENGINE = pathlib.Path(os.environ.get('STUDIO_PAIR_ENGINE_PATH',str(ROOT / 'build/Studio Pair.app/Contents/MacOS/studio-pair-engine')))
JOURNAL = ROOT / 'work/hardware-check/journal.json'

def inspect():
    return json.loads(subprocess.check_output([str(ENGINE), 'inspect'], timeout=15))

def essential(snapshot):
    return {k:snapshot[k] for k in ('default_output','default_input','default_system_output','displays')}

def compare(before, after):
    for key in ('default_output','default_input','default_system_output'):
        assert before[key]==after[key], (key,before[key],after[key])
    assert len(before['displays']) == len(after['displays'])
    after_by_uid = {d['uid']: d for d in after['displays']}
    for a in before['displays']:
        b = after_by_uid[a['uid']]
        for key in ('id','uid','channels','rate','mute'):
            assert a[key]==b[key], (key,a[key],b[key])
        assert abs(a['volume']-b['volume'])<0.0002,(a['volume'],b['volume'])

if '--play-test-tone' not in sys.argv:
    raise SystemExit('This plays a quiet tone. Quit Studio Pair, lower volume, then pass --play-test-tone.')
app_lock = pathlib.Path.home() / 'Library/Application Support/StudioPair/app.lock'
if app_lock.exists():
    lock = app_lock.open('r+')
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: raise SystemExit('Quit Studio Pair before the hardware check.')
JOURNAL.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
before=inspect()
assert len(before['displays']) == 2
assert before['default_output'] in {d['id'] for d in before['displays']}
source=subprocess.Popen([str(ENGINE),'tone',str(before['default_output']),'45','stereo'],stdout=subprocess.PIPE,text=True)
source_line=source.stdout.readline().strip()
assert json.loads(source_line)['state']=='tone'
proof={'before':essential(before),'source':source_line,'runs':[]}
try:
    for label,sig,seconds in [('normal_stop',signal.SIGTERM,15),('forced_crash',signal.SIGKILL,15),('expiry',None,3),('continuous',signal.SIGTERM,0)]:
        worker=subprocess.Popen([str(ENGINE),'run',str(JOURNAL),str(seconds),'0','com.spotify.client',str(source.pid),'0'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
        lines=[]; deadline=time.monotonic()+12; active=False
        while time.monotonic()<deadline:
            if select.select([worker.stdout],[],[],0.3)[0]:
                line=worker.stdout.readline().strip()
                if not line: break
                lines.append(line)
                try: state=json.loads(line)
                except ValueError: continue
                if state.get('state')=='playing' and state.get('output_peak',0)>0 and state.get('callbacks',0)>100:
                    assert 0.054<state['input_peak']<0.066,state
                    assert 0.027<state['output_peak']<0.033,state
                    active=True;break
        assert active,lines
        assert source.poll() is None
        if seconds==0:
            time.sleep(5)
            assert worker.poll() is None, 'Continuous mode expired'
        if sig: worker.send_signal(sig)
        worker.wait(timeout=10)
        lines.extend(worker.stdout.read().splitlines())
        restore=subprocess.run([str(ENGINE),'restore',str(JOURNAL)],capture_output=True,text=True,timeout=15)
        assert restore.returncode==0,restore.stderr
        after=inspect();compare(before,after)
        assert source.poll() is None
        proof['runs'].append({'case':label,'worker_exit':worker.returncode,'events':lines,'restored':json.loads(JOURNAL.read_text())['restored'],'after':essential(after)})
        print(label,'PASS',flush=True)
finally:
    source.terminate();source.wait(timeout=5)
    subprocess.run([str(ENGINE),'restore',str(JOURNAL)],timeout=15)
    (ROOT/'work/hardware-proof.json').write_text(json.dumps(proof,indent=2))
