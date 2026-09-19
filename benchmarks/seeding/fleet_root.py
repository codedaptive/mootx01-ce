#!/usr/bin/env python3
"""Print the primary base folder for PORT from MOOTX01_BENCH_TARGET_MAP.

Usage: fleet_root.py [PORT]   PORT defaults to swift.

Exit 2 with a message on stderr when MOOTX01_BENCH_TARGET_MAP is unset,
the file is not readable, or the port's datasets do not agree on a single
primary base.  The Makefile FLEET_ROOT variable calls this script.
"""
import sys

from artifact_layout import primary_base_for_port

port = sys.argv[1] if len(sys.argv) > 1 else "swift"
print(primary_base_for_port(port))
