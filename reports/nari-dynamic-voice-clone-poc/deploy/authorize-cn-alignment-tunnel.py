from pathlib import Path
import os

path = Path('/root/.ssh/authorized_keys')
original = path.read_text()
lines = original.splitlines(keepends=True)
selected = [index for index, line in enumerate(lines)
            if line.rstrip().endswith(' root@VM-0-5-ubuntu')
            and 'permitopen="127.0.0.1:18890"' in line]
assert len(selected) == 1
index = selected[0]
if 'permitopen="127.0.0.1:18891"' not in lines[index]:
    backup = path.with_name('authorized_keys.cn-alignment-pre-20260908')
    if backup.exists():
        assert backup.read_text() == original
    else:
        backup.write_text(original)
        os.chmod(backup, 0o600)
    lines[index] = lines[index].replace('permitopen="127.0.0.1:18890"',
                                       'permitopen="127.0.0.1:18890",permitopen="127.0.0.1:18891"', 1)
    temporary = path.with_name('authorized_keys.cn-alignment.next')
    temporary.write_text(''.join(lines))
    os.chmod(temporary, 0o600)
    temporary.replace(path)
print('Authorized only the additional loopback alignment port for the existing China tunnel key')
