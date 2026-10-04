"""Native process counters for smoke evidence; no optional dependencies."""
import os
import subprocess


def read_usage(pid):
    """Return cumulative CPU seconds and resident bytes, or None after exit."""
    if os.name != "nt":
        result = subprocess.run(["ps", "-p", str(pid), "-o", "time=,rss="],
                                capture_output=True, text=True, timeout=2)
        if result.returncode or not result.stdout.strip():
            return None
        elapsed, rss = result.stdout.split()
        seconds = 0.0
        for component in elapsed.split(":"):
            seconds = seconds * 60 + float(component)
        return dict(cpu_seconds=seconds, resident_bytes=int(rss) * 1024)

    import ctypes as c
    from ctypes import wintypes as w

    class Memory(c.Structure):
        _fields_ = [("cb", w.DWORD), ("faults", w.DWORD)] + [
            (name, c.c_size_t) for name in ("peak_rss", "rss", "peak_paged", "paged",
                                           "peak_nonpaged", "nonpaged", "pagefile", "peak_pagefile")]

    kernel = c.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.restype = w.HANDLE
    kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
    kernel.CloseHandle.argtypes = [w.HANDLE]
    kernel.GetProcessTimes.argtypes = [w.HANDLE] + [c.POINTER(w.FILETIME)] * 4
    memory_api = c.WinDLL("psapi", use_last_error=True).GetProcessMemoryInfo
    memory_api.argtypes = [w.HANDLE, c.POINTER(Memory), w.DWORD]
    handle = kernel.OpenProcess(0x0400 | 0x0010, False, pid)
    if not handle:
        return None
    try:
        times = [w.FILETIME() for _ in range(4)]
        memory = Memory(cb=c.sizeof(Memory))
        if not kernel.GetProcessTimes(handle, *(c.byref(t) for t in times)) or not memory_api(handle, c.byref(memory), memory.cb):
            return None
        ticks = sum((t.dwHighDateTime << 32) | t.dwLowDateTime for t in times[2:])
        return dict(cpu_seconds=ticks / 1e7, resident_bytes=memory.rss)
    finally:
        kernel.CloseHandle(handle)
