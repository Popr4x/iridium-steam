#!/usr/bin/env python3
"""Exercise the production iOS message-wait loop with a missed input wake."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[4]
source = (root / 'testrepos/Madeira/build/win32u-unix/message_ios.c').read_text()
start = source.index('    {\n        if (type == WaitAll)', source.index('static DWORD wait_message('))
end = source.index('    if (HIWORD(ret))', start)
code = r'''
#include <assert.h>
#include <stddef.h>
typedef unsigned DWORD;
typedef struct { long long QuadPart; } LARGE_INTEGER;
#define WaitAll 1
#define WAIT_TIMEOUT 258
#define MWMO_ALERTABLE 2
#define QS_ALLINPUT 0
static long long now;
static int calls, input_ready, handle_ready;
static LARGE_INTEGER *get_nt_timeout(LARGE_INTEGER *t, unsigned ms) { t->QuadPart = -(long long)ms; return t; }
static void NtQuerySystemTime(LARGE_INTEGER *t) { t->QuadPart = now; }
static DWORD NtWaitForMultipleObjects(DWORD count, void *handles, int type, int alert, LARGE_INTEGER *t) {
    calls++;
    if (handle_ready) return 0;
    assert(t); now = t->QuadPart; return WAIT_TIMEOUT;
}
static int process_driver_events(int events, int wake, int changed) { return input_ready && now >= 16; }
static DWORD run(int type, long long deadline) {
    DWORD count = 2, flags = 0, ret;
    void *handles = NULL;
    unsigned wake_mask = 0, changed_mask = 0;
    LARGE_INTEGER limit = {deadline}, *abs = deadline < 0 ? NULL : &limit;
''' + source[start:end] + r'''
    return ret;
}
int main(void) {
    input_ready = 1;
    assert(run(0, -1) == 1 && now == 16 && calls == 1);
    now = calls = input_ready = 0;
    assert(run(0, 40) == WAIT_TIMEOUT && now == 40 && calls == 3);
    now = calls = 0;
    assert(run(0, 0) == WAIT_TIMEOUT && now == 0 && calls == 1);
    now = calls = 0; handle_ready = 1;
    assert(run(0, 40) == 0 && calls == 1);
    now = calls = 0; handle_ready = 0; input_ready = 1;
    assert(run(WaitAll, 40) == WAIT_TIMEOUT && now == 40 && calls == 1);
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / 'check.c').write_text(code)
    subprocess.run(['cc', str(path / 'check.c'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
print('Input wait checks passed: missed wake, deadlines, handles, WaitAll.')
