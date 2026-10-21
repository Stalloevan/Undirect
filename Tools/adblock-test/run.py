#!/usr/bin/env python3
"""Ad-block regression test. Exit status 1 if any expectation fails."""
import sys, random, re
from harness import *
from corpus import *

failures = 0
def fail(msg):
    global failures
    failures += 1
    print('  FAIL', msg)

# 1. Every list entry must become a valid, matching rule (catches bad characters).
for level in ('standard', 'strict'):
    name = {'standard': 'light', 'strict': 'strict'}[level]
    rules = Rules(name)
    print(f'[{level}] {len(rules.domains)} domains')
    for u in SHOULD_BLOCK:
        if not rules.verdict(u): fail(f'not blocked: {u}')
    for u in SHOULD_ALLOW:
        v = rules.verdict(u)
        if v: fail(f'wrongly blocked: {u} ({v})')

# 2. Random sample of list entries: the exact rule regex must match host, subdomain and port forms,
#    and must not match look-alikes.
rules = Rules('strict')
rng = random.Random(7)
for d in rng.sample(rules.domains, 3000):
    rx = domain_re(d)
    for u in (f'https://{d}/', f'https://a.b.{d}/x?y=1', f'http://{d}:8080/p', f'wss://cdn.{d}/s'):
        if not rx.search(canon(u)): fail(f'rule for {d} misses {u}')
    for u in (f'https://not{d}/', f'https://{d}.example.org/', f'https://example.org/{d}/'):
        if rx.search(canon(u)): fail(f'rule for {d} wrongly hits {u}')
print('[rules] sampled 3000 entries x 7 URL shapes')

# 3. Off level blocks nothing from the lists.
off = Rules('off')
for u in SHOULD_BLOCK[:10]:
    if off.verdict(u): fail(f'off level blocked {u}')

# 4. User blocklist and allow-list behave as the app does.
mine = Rules('strict', user_blocked=['my-tracker.example', 'ads.mysite.org'])
for u in ('https://my-tracker.example/p.js', 'https://cdn.my-tracker.example/p.js', 'https://ads.mysite.org/a'):
    if not mine.verdict(u): fail(f'user-blocked not blocked: {u}')
for u in ('https://mysite.org/', 'https://www.mysite.org/a', 'https://xmy-tracker.example/'):
    if mine.verdict(u): fail(f'user rule over-blocks: {u}')
allow = Rules('strict', user_allowed=['doubleclick.net'])
if allow.verdict('https://securepubads.g.doubleclick.net/tag/js/gpt.js'): fail('allowing doubleclick.net still blocks its subdomain')
if not allow.verdict('https://www.googletagmanager.com/gtm.js'): fail('allowing one domain unblocked others')
sub = Rules('strict', user_allowed=['pagead2.googlesyndication.com'])
if sub.verdict('https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js'): fail('allowed subdomain still blocked via its parent entry')
both = Rules('strict', user_blocked=['doubleclick.net'], user_allowed=['doubleclick.net'])
if not both.verdict('https://doubleclick.net/'): fail('user block should win over a list removal')
print('[user lists] ok' if not failures else '[user lists] see failures')

# 5. The v3.39 additions.
rules = Rules('strict')
for h in REQUESTED_FULL:
    for t in ('script', 'document'):
        if not rules.verdict(f'https://{h}/x', t): fail(f'{h} not blocked as {t}')
for h in REQUESTED_RESOURCE_ONLY:
    for t in ('script', 'raw', 'image'):
        if not rules.verdict(f'https://{h}/x', t): fail(f'{h} not blocked as {t}')
    for t in ('document', 'frame'):
        if rules.verdict(f'https://{h}/x', t): fail(f'{h} wrongly blocked as {t} (would strand the page)')
for h in REQUESTED_LEFT_ALONE:
    for t in ('script', 'document'):
        v = rules.verdict(f'https://{h}/x', t)
        if v: fail(f'{h} should load as {t} but is blocked ({v})')
for u in PATH_BLOCKED:
    if not rules.verdict(u, 'script'): fail(f'tracking path not blocked: {u}')
for u, t in PATH_ALLOWED:
    if rules.verdict(u, t): fail(f'wrongly blocked: {u} ({t})')
# Level Off blocks none of it; a user "allow" lifts a resource-only entry too.
off = Rules('off')
if off.verdict('https://criteo.com/x') or off.verdict('https://s.youtube.com/x'): fail('level Off should not block built-in extras')
if Rules('strict', user_allowed=['s.youtube.com']).verdict('https://s.youtube.com/api/stats', 'raw'): fail('allowing s.youtube.com did not lift it')
print(f'[v3.39] {len(REQUESTED_FULL)} full, {len(REQUESTED_RESOURCE_ONLY)} resource-only, {len(REQUESTED_LEFT_ALONE)} left alone')

print('PASS' if not failures else f'{failures} FAILURE(S)')
sys.exit(1 if failures else 0)
