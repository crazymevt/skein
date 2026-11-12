#!/usr/bin/env python3
"""Write host/tests/fixtures/library/regex-cases.edn: the reference model for Skein's
regex engine (M3.3, D-105). Each case is a pattern in Java's syntax, a string, and the
first match Python's re finds there, as [whole group1 ...] (nil for a group that didn't
take part), or nil for no match.

The patterns are random, from the part of the syntax Java and Python agree on, plus hand
written ones for named groups, back references, lookahead, flags, quoting and escapes.
Python runs them in ASCII mode, which Java's defaults are (\\d \\w \\s and (?i) are ASCII).
The strings avoid \\r, which Java's . doesn't match and Python's does.

    python3 host/tools/regex-cases.py

It's deterministic (a fixed seed), so the file changes only when this script does.
"""

import random
import re
import os

random.seed(105)

ALPHABET = "abcA1 _\n"


def atom(depth):
    r = random.random()
    if depth < 3 and r < 0.18:
        inner = alternation(depth + 1)
        kind = random.choice(["(", "(", "(?:", "(?=", "(?!"])
        return kind + inner + ")"
    choices = ["a", "b", "c", "A", "1", " ", ".", "[ab]", "[^a]", "[a-c]", "[\\d_]",
               "\\d", "\\w", "\\s", "\\W", "\\D", "\\S", "\\.", "[ ]"]
    return random.choice(choices)


def quantified(depth):
    a = atom(depth)
    if a.startswith("(?=") or a.startswith("(?!"):
        return a
    r = random.random()
    if r < 0.55:
        return a
    q = random.choice(["*", "+", "?", "{2}", "{1,2}", "{0,3}", "{2,}"])
    if random.random() < 0.3:
        q += "?"
    return a + q


def concatenation(depth):
    return "".join(quantified(depth) for _ in range(random.randint(1, 4)))


def alternation(depth):
    branches = [concatenation(depth) for _ in range(random.choice([1, 1, 1, 2, 3]))]
    return "|".join(branches)


def random_pattern():
    p = alternation(0)
    r = random.random()
    if r < 0.1:
        p = "^" + p
    elif r < 0.2:
        p = p + "$"
    elif r < 0.25:
        p = "\\b" + p
    if random.random() < 0.1:
        p = "(?i)" + p
    return p


def random_string():
    return "".join(random.choice(ALPHABET) for _ in range(random.randint(0, 9)))


HAND = [
    ("(?<year>\\d{4})-(?<month>\\d\\d)", "on 2026-11-12."),
    ("(?<w>\\w+) \\k<w>", "say hello hello there"),
    ("(a)(b)?c\\1", "aca abca"),
    ("(\\w)\\1", "abccd"),
    ("(?i)(ab)\\1", "abAB"),
    ("a(?=b)", "ac ab"),
    ("a(?!b)", "ab ac"),
    ("(?=(\\w+))\\w", "xyz"),
    ("(?m)^b", "a\nb"),
    ("(?m)a$", "a\nb"),
    ("^b", "a\nb"),
    ("a$", "a\n"),
    ("(?s)a.b", "a\nb"),
    ("a.b", "a\nb"),
    ("(?x) a b  # spaces and a comment\n c", "abc"),
    ("(?i:a)b", "Ab AB"),
    ("\\x41\\u0042\\t", "AB\t"),
    ("[\\x41-\\x43]+", "xxABCDx"),
    ("[a\\-z]+", "a-z-b"),
    ("[]a]+", "]a]b"),
    ("[^]a]+", "]ab]"),
    ("\\$\\^\\(\\)\\[\\]\\{\\}\\|\\\\", "$^()[]{}|\\"),
    ("a{3}", "aaaa"),
    ("a{2,3}?", "aaaa"),
    ("(a|ab)(c|bcd)(d*)", "abcd"),
    ("(a+)+b", "aaab"),
    ("(a*)*", "b"),
    ("(a*)+", "b"),
    ("(a|)*b", "aab"),
    ("\\bfoo\\b", "a foo b"),
    ("\\Bo\\B", "foo"),
    ("\\Aab", "ab ab"),
    ("ab\\z", "ab ab"),
    ("x*", "aaa"),
    ("", "abc"),
    ("é+", "aééb"),
    ("[é-ë]+", "aèêb"),
    (".", "😀x"),
    ("\\w+", "héllo"),
]


# Java's syntax that Python lacks, with Java's results written out: \Q...\E quotes, and a
# quantifier after it applies to its last character (Java removes the quoting first);
# flags in the middle of a pattern.
JAVA_ONLY = [
    ("\\Qa.b*\\E+", "xa.b**", ["a.b**"]),
    ("\\Q(a|b)\\E", "(a|b)", ["(a|b)"]),
    ("a(?i)b", "aB AB", ["aB"]),
    ("a(?i)b(?-i)c", "abC aBc", ["aBc"]),
]


def to_python(p):
    # Java's (?<name>...) and \k<name> are Python's (?P<name>...) and (?P=name).
    p = re.sub(r"\(\?<([A-Za-z][A-Za-z0-9]*)>", r"(?P<\1>", p)
    p = re.sub(r"\\k<([A-Za-z][A-Za-z0-9]*)>", r"(?P=\1)", p)
    # Java's \z is Python's \Z.
    p = p.replace("\\z", "\\Z")
    return p


def edn_string(s):
    out = ['"']
    for ch in s:
        if ch == '"':
            out.append('\\"')
        elif ch == '\\':
            out.append('\\\\')
        elif ch == '\n':
            out.append('\\n')
        elif ch == '\t':
            out.append('\\t')
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def edn_value(v):
    if v is None:
        return "nil"
    if isinstance(v, str):
        return edn_string(v)
    return "[" + " ".join(edn_value(x) for x in v) + "]"


def expected(p, s):
    m = re.search(to_python(p), s, re.ASCII)
    if m is None:
        return None
    return [m.group(0)] + list(m.groups())


def main():
    cases = list(JAVA_ONLY)
    for p, s in HAND:
        cases.append((p, s, expected(p, s)))
    seen = set()
    while len(cases) < 2500:
        p = random_pattern()
        try:
            re.compile(to_python(p), re.ASCII)
        except re.error:
            continue
        for _ in range(4):
            s = random_string()
            if (p, s) in seen:
                continue
            seen.add((p, s))
            cases.append((p, s, expected(p, s)))
    root = os.path.join(os.path.dirname(__file__), "..", "tests", "fixtures", "library")
    with open(os.path.join(root, "regex-cases.edn"), "w", encoding="utf-8") as f:
        f.write(";; Written by host/tools/regex-cases.py from Python's re: [pattern string match].\n")
        f.write("[\n")
        for p, s, e in cases:
            f.write(" [" + edn_string(p) + " " + edn_string(s) + " " + edn_value(e) + "]\n")
        f.write("]\n")
    print(len(cases), "cases")


if __name__ == "__main__":
    main()
