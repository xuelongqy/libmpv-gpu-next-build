"""Reject invalid volume overrides before opening a window or audio device."""
import subprocess
import sys

for value in ("-1", "101", "junk", "50junk", "", "50"):
    result = subprocess.run([sys.argv[1], "--volume", value], capture_output=True,
                            text=True, timeout=10)
    expected = "a.play_seconds || !a.volume" if value == "50" else "volume >= 0"
    assert result.returncode == 1 and expected in result.stderr, (value, result)
print("VOLUME_ARGUMENT_CHECKS=PASS")
