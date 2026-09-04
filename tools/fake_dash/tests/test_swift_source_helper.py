"""Tests for `tests.swift_source`, plus a meta-guard against the fixed-window
Swift-source assertion pattern coming back.

Background: several drift guards used to scope an assertion to a fixed
character slice of a Swift file::

    idx = src.index("func runConnectFlow")
    body = src[idx:idx + 1600]
    assert "seq.reset()" in body

That is a guess about the declaration's length, and it rots in two distinct
ways as the Swift file grows:

* a POSITIVE assertion turns into a false failure — the needle is still there,
  just past the window (this took CI red on `main` with `seq.reset()` sitting
  at offset 1594 of a 1600-char window);
* a NEGATIVE assertion goes silently blind — the forbidden construct can come
  back beyond the window and the guard still passes, which is worse, because
  the test now protects nothing while looking green.

`decl_body()` scopes to the real brace-balanced declaration instead, so the
assertion means what it reads like and doesn't depend on incidental length.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from tests.swift_source import decl_body, strip_comments


# ----------------------------------------------------------------------
# decl_body
# ----------------------------------------------------------------------

def test_decl_body_returns_balanced_declaration():
    src = "func a() {\n    let x = 1\n}\nfunc b() { let y = 2 }\n"
    body = decl_body(src, "func a")
    assert body.startswith("func a()")
    assert body.endswith("}")
    assert "let x = 1" in body
    assert "func b" not in body, "body leaked into the next declaration"


def test_decl_body_handles_nested_braces():
    src = "func a() {\n  if x {\n    while y { z() }\n  }\n  tail()\n}\nfunc b() {}\n"
    body = decl_body(src, "func a")
    assert "tail()" in body, "nested braces ended the body early"
    assert "func b" not in body


def test_decl_body_ignores_brace_in_string_literal():
    src = 'func a() {\n    log("}")\n    tail()\n}\nfunc b() {}\n'
    body = decl_body(src, "func a")
    assert "tail()" in body, "a brace inside a string literal ended the body"


def test_decl_body_ignores_escaped_quote_in_literal():
    src = 'func a() {\n    log("say \\"}\\" now")\n    tail()\n}\nfunc b() {}\n'
    body = decl_body(src, "func a")
    assert "tail()" in body


def test_decl_body_ignores_brace_in_comments():
    src = "func a() {\n    // }\n    /* } */\n    tail()\n}\nfunc b() {}\n"
    body = decl_body(src, "func a")
    assert "tail()" in body, "a brace inside a comment ended the body"


def test_decl_body_handles_nested_block_comments():
    # Swift allows nested /* /* */ */ — a naive scanner ends the comment early.
    src = "func a() {\n    /* outer /* inner } */ still comment } */\n    tail()\n}\nfunc b() {}\n"
    body = decl_body(src, "func a")
    assert "tail()" in body
    assert "func b" not in body


def test_decl_body_can_exclude_the_signature():
    src = "func a(x: Int) {\n    tail()\n}\n"
    body = decl_body(src, "func a", include_signature=False)
    assert body.startswith("{")
    assert "x: Int" not in body


def test_decl_body_raises_on_missing_anchor():
    with pytest.raises(AssertionError, match="anchor"):
        decl_body("func a() {}", "func nope")


def test_decl_body_raises_on_unbalanced_braces():
    with pytest.raises(AssertionError, match="unbalanced"):
        decl_body("func a() {\n  oops\n", "func a")


def test_decl_body_grows_with_the_declaration():
    """The regression that motivated this helper: inserting comment lines must
    not push a needle out of scope."""
    src = "func a() {\n" + "    // filler\n" * 500 + "    seq.reset()\n}\n"
    assert "seq.reset()" in decl_body(src, "func a")
    # ...whereas the old fixed-window approach would have missed it.
    idx = src.index("func a")
    assert "seq.reset()" not in src[idx:idx + 1600]


# ----------------------------------------------------------------------
# strip_comments
# ----------------------------------------------------------------------

def test_strip_comments_removes_both_flavours():
    out = strip_comments("keep1 // gone\n/* gone */ keep2\n")
    assert "keep1" in out and "keep2" in out
    assert "gone" not in out


def test_strip_comments_preserves_string_literals():
    out = strip_comments('let s = "// not a comment"\n')
    assert "// not a comment" in out


# ----------------------------------------------------------------------
# Meta-guard: don't reintroduce fixed-length source windows.
# ----------------------------------------------------------------------

# `src[idx:idx + 1600]`, `src[idx:idx+320]`, etc.
_FIXED_WINDOW = re.compile(r"\[\s*\w+\s*:\s*\w+\s*\+\s*\d+\s*\]")


def test_no_fixed_length_swift_source_windows_in_tests():
    """Swift drift guards must scope with `decl_body`, not a magic length.

    If this fails on a new test, replace the slice with
    `decl_body(src, "<anchor>")` — see this module's docstring for why the
    fixed window rots in both directions.
    """
    offenders = []
    for path in sorted(Path(__file__).parent.glob("test_*.py")):
        if path.name == Path(__file__).name:
            continue
        for lineno, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), start=1
        ):
            code = line.split("#", 1)[0]
            if "src" not in code and "branch" not in code and "body" not in code:
                continue
            if _FIXED_WINDOW.search(code):
                offenders.append(f"{path.name}:{lineno}: {line.strip()}")
    assert not offenders, (
        "fixed-length source window(s) reintroduced — use decl_body() instead:\n"
        + "\n".join(offenders)
    )
