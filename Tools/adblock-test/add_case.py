#!/usr/bin/env python3
"""Turn a real-world report into a permanent regression test.

  python3 add_case.py block https://ads.example.net/pixel.gif [type]   # an ad got through
  python3 add_case.py allow https://cdn.example.com/player.js [type]   # a site broke

Appends to reported.txt (type defaults to script) and runs the suite. A new
"block" case that fails means the lists need a new entry; a new "allow" case
that fails means a rule is too broad. Fix the lists in Sources/Resources until
the run passes, then commit reported.txt with the fix.
"""
import os, subprocess, sys

here = os.path.dirname(os.path.abspath(__file__))
if len(sys.argv) < 3 or sys.argv[1] not in ('block', 'allow'):
    sys.exit(__doc__)
kind, url = sys.argv[1], sys.argv[2]
rtype = sys.argv[3] if len(sys.argv) > 3 else 'script'
line = f'{kind} {rtype} {url}\n'
path = os.path.join(here, 'reported.txt')
if line in open(path).read():
    print('already recorded')
else:
    open(path, 'a').write(line)
    print('recorded:', line.strip())
sys.exit(subprocess.call([sys.executable, os.path.join(here, 'run.py')], cwd=here))
