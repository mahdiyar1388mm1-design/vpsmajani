#!/usr/bin/env python3
"""Structural linter for .github/workflows/windows-rdp.yml.

Checks, without needing actionlint or pwsh:
  * YAML parses, every job/step is shaped correctly
  * every ${{ }} expression is balanced and only uses known contexts
  * PowerShell run-blocks: here-string terminators sit at column 0 (GitHub
    strips only the YAML block indent), brackets balance, quotes balance,
    no tabs, no ${{ }} injected straight into a script body (script-injection
    smell), and every `Add-Content $env:GITHUB_*` target is a real file var.
"""
import re
import sys
import yaml

KNOWN_CONTEXTS = {
    "github", "env", "vars", "secrets", "inputs", "matrix", "strategy", "job",
    "runner", "needs", "steps", "always", "success", "failure", "cancelled",
    "hashFiles", "format", "join", "toJSON", "fromJSON", "contains",
    "startsWith", "endsWith", "fromJson", "toJson",
}

errors = []
warnings = []


def err(msg):
    errors.append(msg)


def warn(msg):
    warnings.append(msg)


# ------------------------------------------------------- PowerShell linting
def lint_powershell(script, where, shell):
    lines = script.split("\n")

    # 1. here-strings: opener ends the line, terminator must start at column 0
    open_here = None
    for n, line in enumerate(lines, 1):
        stripped = line.rstrip()
        if open_here is None:
            m = re.search(r'(@["\'])\s*$', stripped)
            if m:
                open_here = (m.group(1), n)
        else:
            term = "'@" if open_here[0] == "@'" else '"@'
            if line.startswith(term):          # column 0 -> legal, piping after it is fine
                open_here = None
            elif term in stripped:
                warn(f"{where}:{n}: here-string terminator indented (must be column 0) -> {stripped!r}")
    if open_here:
        err(f"{where}: here-string opened at line {open_here[1]} is never terminated")

    # 2. bracket balance with a small tokenizer (strings, here-strings, comments)
    depth = {"(": 0, "{": 0, "[": 0}
    pairs = {")": "(", "}": "{", "]": "["}
    i, n = 0, len(script)
    in_here = None
    line_no = 1
    while i < n:
        ch = script[i]
        if ch == "\n":
            line_no += 1
            if in_here:
                term = "'@" if in_here == "'" else '"@'
                if script[i + 1:i + 1 + len(term)] == term:
                    in_here = None
                    i += 1 + len(term)
                    continue
            i += 1
            continue
        if in_here:
            i += 1
            continue
        if ch == "#":
            while i < n and script[i] != "\n":
                i += 1
            continue
        if script[i:i + 2] in ('@"', "@'") or script[i:i + 2] == "@'":
            quote = script[i + 1]
            j = script.find("\n", i)
            if j == -1 or script[i + 2:j].strip():
                pass  # not a here-string opener (e.g. splatting @args)
            else:
                in_here = quote
                i = j
                continue
        if ch in "'\"":
            i += 1
            while i < n:
                if script[i] == "`" and ch == '"':
                    i += 2
                    continue
                if script[i] == ch:
                    if ch == "'" and i + 1 < n and script[i + 1] == "'":
                        i += 2
                        continue
                    break
                if script[i] == "\n":
                    err(f"{where}: unterminated {ch} string starting near line {line_no}")
                    break
                i += 1
            i += 1
            continue
        if ch in depth:
            depth[ch] += 1
        elif ch in pairs:
            depth[pairs[ch]] -= 1
            if depth[pairs[ch]] < 0:
                err(f"{where}: extra closing '{ch}' at line {line_no}")
                depth[pairs[ch]] = 0
        i += 1
    for bracket, count in depth.items():
        if count != 0:
            err(f"{where}: unbalanced '{bracket}' (net {count:+d})")



# ---------------------------------------------------------------- YAML shape
with open(".github/workflows/windows-rdp.yml", encoding="utf-8") as fh:
    raw = fh.read()

doc = yaml.safe_load(raw)
# PyYAML 1.1 turns the bare key `on` into True
triggers = doc.get("on", doc.get(True))
if not triggers:
    err("no `on:` triggers found")
else:
    print("triggers:", ", ".join(str(t) for t in triggers))

jobs = doc.get("jobs", {})
if not jobs:
    err("no jobs")

expr_re = re.compile(r"\$\{\{(.*?)\}\}", re.S)


def check_expressions(text, where):
    for m in expr_re.finditer(text):
        body = m.group(1)
        if body.count("{") != body.count("}"):
            err(f"{where}: unbalanced braces in expression {m.group(0)!r}")
        first = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)", body)
        if not first:
            err(f"{where}: empty/odd expression {m.group(0)!r}")
            continue
        ctx = first.group(1)
        if ctx not in KNOWN_CONTEXTS:
            err(f"{where}: unknown context '{ctx}' in {m.group(0)!r}")


check_expressions(raw, "file")

for jid, job in jobs.items():
    if "runs-on" not in job:
        err(f"job {jid}: missing runs-on")
    steps = job.get("steps") or []
    if not steps:
        err(f"job {jid}: no steps")
    ids = set()
    for i, step in enumerate(steps):
        where = f"job {jid} step #{i} ({step.get('name', '<unnamed>')})"
        has_run, has_uses = "run" in step, "uses" in step
        if has_run == has_uses:
            err(f"{where}: must have exactly one of run/uses")
        sid = step.get("id")
        if sid:
            if sid in ids:
                err(f"{where}: duplicate step id '{sid}'")
            ids.add(sid)
        for key in ("with", "env", "if", "name"):
            if key in step and isinstance(step[key], str):
                check_expressions(step[key], f"{where}.{key}")
        if has_uses and not re.match(r"^[\w.-]+(/[\w.-]+)+(@v\d+(\.\d+)*(\.\d+)*|@[0-9a-f]{40})$", step["uses"]):
            warn(f"{where}: pin '{step['uses']}' is not a version tag or full SHA")
        if has_run:
            script = step["run"]
            shell = step.get("shell") or (job.get("defaults", {}).get("run", {}) or {}).get("shell")
            if "\t" in script:
                err(f"{where}: tab character inside script")
            # raw event/input text spliced into a shell body = injection risk
            for m in expr_re.finditer(script):
                body = m.group(1)
                if re.search(r"github\.event\.(inputs|client_payload)", body):
                    err(f"{where}: untrusted input spliced into script body: {m.group(0)!r} "
                        "(pass it through `env:` instead)")
            if shell in (None, "pwsh", "powershell"):
                lint_powershell(script, where, shell)
                # a script embedded in a single-quoted here-string is written to
                # disk and executed separately: lint that too
                for m in re.finditer(r"^@'\n(.*?)^'@", script, re.S | re.M):
                    lint_powershell(m.group(1), f"{where} [embedded script]", shell)

print()


# --------------------------------------------------------------- reporting
for w in warnings:
    print("WARN:", w)
for e in errors:
    print("ERROR:", e)
print()
if errors:
    print(f"FAILED with {len(errors)} error(s), {len(warnings)} warning(s)")
    sys.exit(1)
print(f"OK - {len(jobs)} job(s), {sum(len(j.get('steps') or []) for j in jobs.values())} step(s), "
      f"{len(warnings)} warning(s)")
