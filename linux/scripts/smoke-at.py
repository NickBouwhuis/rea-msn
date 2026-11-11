#!/usr/bin/env python3
"""Finds widgets of running GTK apps by their text, through the accessibility
tree (AT-SPI), for linux/scripts/smoke-test.sh.

  smoke-at.py dump                     the tree: role, name, description, place
  smoke-at.py find TEXT [--exact] [--in WINDOW] [--role ROLE] [--nth N]
                                       "x y": the middle of the Nth (0-based)
                                       showing widget whose name or description
                                       has (or, with --exact, is) TEXT, in
                                       windows named like WINDOW
"""
import sys

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402


def children(node):
    try:
        return [node.get_child_at_index(i) for i in range(node.get_child_count())]
    except Exception:
        return []


def walk(node, window="", depth=0):
    """Yields (node, the name of its top-level window, depth)."""
    if node is None:
        return
    yield node, window, depth
    for child in children(node):
        # Depth 1 is an application's window (the desktop's children are the applications).
        yield from walk(child, text(child) if depth == 1 else window, depth + 1)


def text(node):
    try:
        return node.get_name() or ""
    except Exception:
        return ""


def describe(node):
    try:
        return node.get_description() or ""
    except Exception:
        return ""


def place(node):
    """x, y, width, height on the screen, if the widget is showing."""
    try:
        if not node.get_state_set().contains(Atspi.StateType.SHOWING):
            return None
        e = node.get_extents(Atspi.CoordType.SCREEN)
        return (e.x, e.y, e.width, e.height) if e.width > 0 and e.height > 0 else None
    except Exception:
        return None


def nodes():
    desktop = Atspi.get_desktop(0)
    for app in children(desktop):
        yield from walk(app, depth=1)


def main(args):
    if args[:1] == ["dump"]:
        for node, window, depth in nodes():
            try:
                role = node.get_role_name()
            except Exception:
                role = "?"
            print("  " * depth + f"{role} {text(node)!r} {describe(node)!r} {place(node)}")
        return 0
    if args[:1] == ["find"] and len(args) >= 2:
        wanted, within, role, nth = args[1], None, None, 0
        rest = [a for a in args[2:] if a != "--exact"]
        exact = "--exact" in args[2:]
        while rest:
            if rest[0] == "--in":
                within = rest[1]
            elif rest[0] == "--role":
                role = rest[1]
            elif rest[0] == "--nth":
                nth = int(rest[1])
            rest = rest[2:]
        found = []
        for node, window, depth in nodes():
            if depth < 3 or (within is not None and within not in window):
                continue
            names = (text(node), describe(node))
            if wanted not in names if exact else not any(wanted in name for name in names):
                continue
            try:
                if role is not None and node.get_role_name() != role:
                    continue
            except Exception:
                continue
            where = place(node)
            if where:
                found.append(where)
        if len(found) > nth:
            x, y, w, h = found[nth]
            print(x + w // 2, y + h // 2)
            return 0
        print(f"no showing widget with {wanted!r}", file=sys.stderr)
        return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
