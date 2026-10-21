"""Emulates WebKit content-rule matching for Undirect's ad-block lists.

Reads the same files the app bundles, so a URL that passes here is covered by
the shipped rules. Mirrors ContentBlocker: domain rules are
^[^:]+://+([^:/]+\\.)?DOMAIN[:/] ; URL rules are used as written; WebKit hands
rules a canonical URL (lowercase host, "/" for an empty path), done in canon().
"""
import re, os
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'Sources', 'Resources') + '/'

SHIELD = ["ipwho.is","ipwhois.app","ipwhois.io","ipapi.co","ipapi.com","ipinfo.io","ip-api.com","ipify.org","geojs.io",
          "ipgeolocation.io","ipdata.co","freeipapi.com","geoplugin.net","ip.sb","db-ip.com","extreme-ip-lookup.com",
          "ipregistry.co","ipbase.com","ipstack.com","ipapi.is","ipquery.io","iplocation.net","myip.com","seeip.org",
          "ident.me","icanhazip.com","i.posthog.com","eu.i.posthog.com","us.i.posthog.com","eu-assets.i.posthog.com",
          "us-assets.i.posthog.com","app.posthog.com"]

def parse_domains(path):
    out = []
    for line in open(path, 'rb').read().split(b'\n'):
        line = line.strip(b' \t\r')
        if line and line[:1] != b'#' and re.fullmatch(rb'[a-z0-9_.-]+', line) and b'.' in line:
            out.append(line.decode())
    return out

def parse_lines(path):
    return [l.strip() for l in open(path, encoding='utf8') if l.strip() and not l.startswith('#')]

def canon(url):
    m = re.match(r'^([a-zA-Z][a-zA-Z0-9+.-]*://+)([^/?#]*)(.*)$', url)
    if not m: return url
    scheme, auth, rest = m.groups()
    if not rest.startswith('/'): rest = '/' + rest
    return scheme.lower() + auth.lower() + rest

def domain_re(d):
    return re.compile(r'^[^:]+://+([^:/]+\.)?' + d.replace('.', r'\.') + r'[:/]', re.I)

def covers(entry, host):
    return host == entry or host.endswith('.' + entry)

class Rules:
    def __init__(self, level='strict', user_blocked=(), user_allowed=()):
        self.level = level
        self.user_blocked = list(user_blocked)
        self.user_allowed = list(user_allowed)
        base = [] if level == 'off' else parse_domains(R + f'blocklist-{level}.txt') + parse_domains(R + 'blocklist-extra.txt')
        # An "allowed" domain drops every entry covering it, in either direction.
        def keep(e): return not any(covers(e, a) or covers(a, e) for a in self.user_allowed)
        self.domains = [e for e in base if keep(e)]
        self.domain_rules = [domain_re(d) for d in self.domains] if len(self.domains) < 3000 else None
        self.domset = set(self.domains)
        res = [] if level == 'off' else parse_domains(R + 'blocklist-extra-resources.txt')
        self.resource_only = [domain_re(d) for d in res if not any(covers(d, a) or covers(a, d) for a in self.user_allowed)]
        self.urls = [] if level == 'off' else [re.compile(p, re.I) for p in parse_lines(R + 'blocklist-extra-urls.txt')]
        self.user_rules = [domain_re(d) for d in self.user_blocked]
        self.shield = [domain_re(d) for d in SHIELD if not any(covers(d, a) or covers(a, d) for a in self.user_allowed)]

    def verdict(self, url, rtype='script'):
        u = canon(url)
        m = re.match(r'^[^:]+://+([^:/]+)', u)
        host = (m.group(1) if m else '').lower()
        h = host
        while True:  # same result as the per-domain regex, without 160k regex runs
            if h in self.domset: return 'domain:' + h
            if '.' not in h: break
            h = h.split('.', 1)[1]
        for r in self.user_rules:
            if r.search(u): return 'user:' + r.pattern
        for r in self.urls:
            if r.search(u): return 'url:' + r.pattern
        if rtype in ('document', 'frame'):  # navigations and frames are never hit by resource-only rules
            return None
        for r in self.resource_only + self.shield:
            if r.search(u): return 'resource:' + r.pattern
        return None
