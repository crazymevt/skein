#!/usr/bin/env python3
"""Write host/tests/fixtures/library/gitignore-cases.edn: the reference model for
skein.io's ignore rules and walk (M3.5, D-107). Each case is a tree of files, the
.gitignore files in it, a .git/info/exclude, and the files Git says aren't ignored:

    [[file ...] [[gitignore-path text] ...] exclude-text [visible-file ...]]

The trees and patterns are random, from names and globs that exercise Git's syntax:
negation, anchoring, a trailing / for directories, *, ?, [...] and **, comments, blank
lines and trailing spaces; plus hand-written cases. Git decides, in a fresh repository
(where nothing is tracked) with `git ls-files --others --exclude-standard`, case-sensitive
and without the user's global excludes.

    python3 host/tools/gitignore-cases.py

It's deterministic (a fixed seed), so the file changes only when this script or Git does.
"""

import os
import random
import subprocess
import tempfile

random.seed(107)

DIRS = ["a", "b", "src", "build", "lib", "doc", ".cache", "node_modules", "out"]
FILES = ["main.c", "main.o", "x.log", "README", "notes.txt", ".env", "foo", "Data.TXT",
         "b.md", "test.py", "data.json", "core", "a.out", "keep.log", "[x].txt"]


def random_tree():
    files = set()
    for _ in range(random.randint(3, 18)):
        depth = random.choice([0, 1, 1, 2, 2, 3])
        parts = [random.choice(DIRS) for _ in range(depth)] + [random.choice(FILES)]
        files.add("/".join(parts))
    # A path can't be both a file and a directory.
    dirs = {"/".join(f.split("/")[:i]) for f in files for i in range(1, f.count("/") + 1)}
    return sorted(f for f in files if f not in dirs)


GLOBS = ["*.log", "*.o", "*.[oc]", "?ain.c", "*", "f*", "[a-c]*", "[!a]*.txt", "*.TXT",
         "*.md", "core", "foo", "README", "\\[x].txt", "*.json", ".env", ".*", "x.lo?",
         "[!.]*", "*.[!c]"]
PATHS = ["a/b", "/a", "src/*.c", "**/foo", "a/**", "a/**/x.log", "**/build", "doc/*.md",
         "/src/lib", "lib/**/*.o", "**/node_modules/**", "build/*", "*/x.log", "a/*/core",
         "/README", "src/**/main.c", "**/*.log", "out/**/", "**"]


def random_pattern():
    r = random.random()
    if r < 0.05:
        return "# a comment"
    if r < 0.08:
        return ""
    body = random.choice(GLOBS + PATHS + DIRS + FILES)
    if random.random() < 0.15 and not body.startswith("/"):
        body = "/" + body
    if random.random() < 0.2 and not body.endswith("/"):
        body = body + "/"
    if random.random() < 0.25:
        body = "!" + body
    if random.random() < 0.05:
        body = body + "  "
    return body


def random_ignore():
    return "\n".join(random_pattern() for _ in range(random.randint(1, 5))) + "\n"


def random_case():
    files = random_tree()
    dirs = sorted({"/".join(f.split("/")[:i]) for f in files for i in range(1, f.count("/") + 1)})
    ignores = []
    for d in [""] + dirs:
        if random.random() < (0.8 if d == "" else 0.3):
            ignores.append(((d + "/" if d else "") + ".gitignore", random_ignore()))
    exclude = random_ignore() if random.random() < 0.3 else ""
    return files, ignores, exclude


HAND = [
    # A file in an ignored directory can't be re-included.
    (["c/z.txt", "c/y.txt", "top.log", "a/keep.log", "a/x.log"],
     [(".gitignore", "*.log\n!a/keep.log\nc/\n!c/z.txt\n")], ""),
    # Deeper .gitignore files win over higher ones; exclude loses to both.
    (["a/b/y.txt", "a/y.txt", "y.txt", "z.txt"],
     [(".gitignore", "*.txt\n"), ("a/.gitignore", "!y.txt\n"), ("a/b/.gitignore", "y.txt\n")],
     "!z.txt\n"),
    # \# and \! are literal, and an escaped trailing space stays (no file name ends with
    # one: Windows refuses them).
    (["#x", "!y", "sp"], [(".gitignore", "\\#x\n\\!y\nsp\\ \n")], ""),
    (["a/b/c/d.txt", "a/d.txt", "d.txt"], [(".gitignore", "a/**/d.txt\n")], ""),
    (["x/y/z", "y/z", "z"], [(".gitignore", "**/y/z\n")], ""),
    (["a/b", "a/c/b"], [(".gitignore", "/a/b\n")], ""),
    (["build/out.o", "src/build/x.c", "build.c"], [(".gitignore", "build/\n")], ""),
]


def git_visible(files, ignores, exclude):
    with tempfile.TemporaryDirectory() as root:
        subprocess.run(["git", "init", "-q", root], check=True)
        for f in files:
            p = os.path.join(root, *f.split("/"))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as out:
                out.write("x\n")
        for path, text in ignores:
            p = os.path.join(root, *path.split("/"))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as out:
                out.write(text)
        with open(os.path.join(root, ".git", "info", "exclude"), "w") as out:
            out.write(exclude)
        listed = subprocess.run(
            ["git", "-c", "core.excludesFile=", "-c", "core.ignorecase=false",
             "ls-files", "--others", "--exclude-standard", "-z"],
            cwd=root, check=True, capture_output=True).stdout.decode("utf-8")
        ignore_files = {path for path, _ in ignores}
        return sorted(p for p in listed.split("\0") if p and p not in ignore_files)


def edn_string(s):
    out = ['"']
    for ch in s:
        if ch == '"':
            out.append('\\"')
        elif ch == '\\':
            out.append('\\\\')
        elif ch == '\n':
            out.append('\\n')
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def edn_strings(xs):
    return "[" + " ".join(edn_string(x) for x in xs) + "]"


def main():
    cases = list(HAND)
    while len(cases) < 400:
        cases.append(random_case())
    root = os.path.join(os.path.dirname(__file__), "..", "tests", "fixtures", "library")
    with open(os.path.join(root, "gitignore-cases.edn"), "w", encoding="utf-8") as f:
        f.write(";; Written by host/tools/gitignore-cases.py from Git: "
                "[files [[gitignore text] ...] exclude visible-files].\n[\n")
        for files, ignores, exclude in cases:
            visible = git_visible(files, ignores, exclude)
            f.write(" [" + edn_strings(files) + " ["
                    + " ".join("[" + edn_string(p) + " " + edn_string(t) + "]" for p, t in ignores)
                    + "] " + edn_string(exclude) + " " + edn_strings(visible) + "]\n")
        f.write("]\n")
    print(len(cases), "cases")


if __name__ == "__main__":
    main()
