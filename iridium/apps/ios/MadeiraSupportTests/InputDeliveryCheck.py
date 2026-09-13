#!/usr/bin/env python3
"""Check delivery logs continue after startup and report focus changes and errors."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[4]
source = (root / "testrepos/Madeira/build/win32u-unix/driver_ios.c").read_text()
body = source[source.index("static void winios_log_input("):source.index("void winios_drv_post_mouse(")]
code = r"""
#include <assert.h>
#include <stddef.h>
typedef void *HWND;
typedef int BOOL;
typedef unsigned NTSTATUS;
typedef struct { unsigned cbSize; HWND hwndActive, hwndFocus, hwndCapture; } GUITHREADINFO;
static HWND foreground = (HWND)1;
static int lines;
static HWND NtUserGetForegroundWindow(void) { return foreground; }
static BOOL NtUserGetGUIThreadInfo(int thread, GUITHREADINFO *info) { return 1; }
#define dprintf(...) (++lines)
""" + body + r"""
int main(void) {
    for (int i=0;i<255;i++) winios_log_input("mouse",1,0);
    assert(lines == 8);
    winios_log_input("mouse",1,0); assert(lines == 9);
    foreground = 0;
    winios_log_input("mouse",1,0); assert(lines == 10);
    winios_log_input("mouse",1,5); assert(lines == 11);
    winios_log_input("key",65,0); assert(lines == 12);
}
"""
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / "check.c").write_text(code)
    subprocess.run(["cc", str(path / "check.c"), "-o", str(path / "check")], check=True)
    subprocess.run([str(path / "check")], check=True)
print("Input delivery checks passed.")
