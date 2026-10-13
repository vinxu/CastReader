import pathlib, subprocess, sys, time
folder = pathlib.Path(sys.argv[1])
log = folder / 'test.log'
captured = False
while not (folder / 'summary.json').exists():
    if log.exists() and time.time() - log.stat().st_mtime > 18 and not captured:
        for line in subprocess.check_output(['ps', '-axo', 'pid,command'], text=True).splitlines():
            if 'EC127445-7281-4C64-9417-8642E44F4039/data/Containers/Bundle/' in line and '.app/CastReader ' in line:
                pid = line.strip().split()[0]
                output = folder / 'stalled-process-sample.txt'
                result = subprocess.run(['/usr/bin/sample', pid, '3', '-file', str(output)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if result.returncode == 0:
                    print('Captured main-thread sample: ' + str(output), flush=True)
                    captured = True
    time.sleep(3)
print('Watch complete', flush=True)
