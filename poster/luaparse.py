"""Minimal parser for WoW SavedVariables (Lua table literals) -> Python objects."""
import re

_num = re.compile(r'-?(0[xX][0-9a-fA-F]+|\d+\.?\d*([eE][-+]?\d+)?|\.\d+([eE][-+]?\d+)?)')
_ident = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
_ESC = {'n': '\n', 't': '\t', 'r': '\r', '\\': '\\', '"': '"', "'": "'", '\n': '\n', 'a': '\a', 'b': '\b', 'f': '\f', 'v': '\v'}


class Parser:
    def __init__(self, s):
        self.s, self.i, self.n = s, 0, len(s)

    def ws(self):
        s = self.s
        while self.i < self.n:
            c = s[self.i]
            if c in ' \t\r\n;':
                self.i += 1
            elif s.startswith('--', self.i):
                if s.startswith('--[[', self.i):
                    j = s.find(']]', self.i)
                    self.i = self.n if j < 0 else j + 2
                else:
                    j = s.find('\n', self.i)
                    self.i = self.n if j < 0 else j + 1
            else:
                break

    def string(self):
        q = self.s[self.i]
        self.i += 1
        out = []
        s = self.s
        while True:
            c = s[self.i]
            if c == q:
                self.i += 1
                return ''.join(out)
            if c == '\\':
                d = s[self.i + 1]
                if d.isdigit():
                    m = re.match(r'\d{1,3}', s[self.i + 1:])
                    out.append(chr(int(m.group())))
                    self.i += 1 + len(m.group())
                    continue
                out.append(_ESC.get(d, d))
                self.i += 2
                continue
            out.append(c)
            self.i += 1

    def value(self):
        self.ws()
        s = self.s
        c = s[self.i]
        if c == '{':
            return self.table()
        if c in '"\'':
            return self.string()
        if s.startswith('true', self.i):
            self.i += 4
            return True
        if s.startswith('false', self.i):
            self.i += 5
            return False
        if s.startswith('nil', self.i):
            self.i += 3
            return None
        m = _num.match(s, self.i)
        if m:
            self.i = m.end()
            t = m.group()
            if t.lower().startswith(('0x', '-0x')):
                return int(t, 16)
            f = float(t)
            return int(f) if f.is_integer() and '.' not in t and 'e' not in t.lower() else f
        raise ValueError(f'unexpected {s[self.i:self.i+40]!r} at {self.i}')

    def table(self):
        self.i += 1
        d, arr, auto = {}, True, 1
        while True:
            self.ws()
            if self.s[self.i] == '}':
                self.i += 1
                break
            if self.s[self.i] == '[':
                self.i += 1
                k = self.value()
                self.ws()
                assert self.s[self.i] == ']'
                self.i += 1
                self.ws()
                assert self.s[self.i] == '='
                self.i += 1
                v = self.value()
            else:
                m = _ident.match(self.s, self.i)
                save = self.i
                if m and self.s[m.end():].lstrip(' \t').startswith('=') and not self.s[m.end():].lstrip(' \t').startswith('=='):
                    k = m.group()
                    self.i = m.end()
                    self.ws()
                    self.i += 1
                    v = self.value()
                else:
                    self.i = save
                    k = auto
                    auto += 1
                    v = self.value()
            d[k] = v
            self.ws()
            if self.s[self.i] == ',':
                self.i += 1
        return d


def parse_file(path):
    s = open(path, encoding='utf-8', errors='replace').read()
    p = Parser(s)
    out = {}
    while True:
        p.ws()
        if p.i >= p.n:
            break
        m = _ident.match(s, p.i)
        if not m:
            raise ValueError(f'bad top-level at {p.i}: {s[p.i:p.i+40]!r}')
        p.i = m.end()
        p.ws()
        assert s[p.i] == '='
        p.i += 1
        out[m.group()] = p.value()
    return out
