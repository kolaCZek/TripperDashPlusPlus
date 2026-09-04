"""Helpers for the Swift-source drift guards.

Many tests in this suite assert that some wiring is still present *inside a
particular Swift declaration* — e.g. "`runConnectFlow` must still call
`seq.reset()`". The historical way to scope such an assertion was a fixed
character window::

    idx = src.index("func runConnectFlow")
    body = src[idx:idx + 1600]          # <-- guesswork
    assert "seq.reset()" in body

That window is a guess about how long the declaration happens to be, and it
rots: add a few lines of comment to the function and the needle silently
falls outside the window, so the guard fails even though the code it guards
is perfectly correct. (That is exactly what happened to
`test_swift_connect_flow_resets_seq`, where `seq.reset()` drifted to offset
1594 of a 1600-char window, and to
`test_swift_upcoming_maneuver_classifies_arriving_against_departing`, where a
new doc comment pushed the needles past a 320-char window.)

`decl_body()` replaces the guess with the real thing: it returns the
brace-balanced body of the declaration, so the assertion means what it says —
"this token appears inside this declaration" — and stays true no matter how
the declaration grows.
"""

from __future__ import annotations

__all__ = ["decl_body", "strip_comments"]


def _find_decl(src: str, anchor: str) -> int:
    try:
        return src.index(anchor)
    except ValueError as exc:  # pragma: no cover - defensive
        raise AssertionError(
            f"anchor {anchor!r} not found in the Swift source — the "
            f"declaration was renamed or removed"
        ) from exc


def decl_body(src: str, anchor: str, *, include_signature: bool = True) -> str:
    """Return the brace-balanced body of the declaration at ``anchor``.

    ``anchor`` is any substring that starts the declaration, e.g.
    ``"func runConnectFlow"`` or ``"var upcomingManeuver"``. The returned text
    spans from the anchor (or from the opening brace when
    ``include_signature`` is False) through the matching closing brace.

    String literals, character escapes and both comment flavours are skipped
    while balancing, so a ``"}"`` inside a literal or a comment cannot end the
    body early. Swift's *nested* block comments are handled too.
    """
    idx = _find_decl(src, anchor)
    open_at = src.index("{", idx)

    depth = 0
    i = open_at
    n = len(src)
    while i < n:
        ch = src[i]

        # Line comment
        if ch == "/" and src.startswith("//", i):
            nl = src.find("\n", i)
            i = n if nl == -1 else nl + 1
            continue

        # Block comment (Swift allows nesting)
        if ch == "/" and src.startswith("/*", i):
            nest = 1
            i += 2
            while i < n and nest:
                if src.startswith("/*", i):
                    nest += 1
                    i += 2
                elif src.startswith("*/", i):
                    nest -= 1
                    i += 2
                else:
                    i += 1
            continue

        # String literal (handles \" escapes; good enough for our sources)
        if ch == '"':
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                i += 1
            continue

        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                start = idx if include_signature else open_at
                return src[start : i + 1]
        i += 1

    raise AssertionError(
        f"unbalanced braces after {anchor!r} — could not find the end of the "
        f"declaration"
    )


def strip_comments(text: str) -> str:
    """Drop `//` and `/* */` comments.

    Use when a guard must prove the *code* does something, so that a token
    merely mentioned in a doc comment cannot satisfy the assertion.
    """
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("//", i):
            nl = text.find("\n", i)
            i = n if nl == -1 else nl
            continue
        if text.startswith("/*", i):
            nest = 1
            i += 2
            while i < n and nest:
                if text.startswith("/*", i):
                    nest += 1
                    i += 2
                elif text.startswith("*/", i):
                    nest -= 1
                    i += 2
                else:
                    i += 1
            continue
        if text[i] == '"':
            out.append(text[i])
            i += 1
            while i < n:
                out.append(text[i])
                if text[i] == "\\":
                    i += 1
                    if i < n:
                        out.append(text[i])
                        i += 1
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        out.append(text[i])
        i += 1
    return "".join(out)
