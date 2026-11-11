#!/usr/bin/env python3
"""Finds widgets of running GTK apps by their text, through the accessibility
tree (AT-SPI), for linux/scripts/smoke-test.sh.

  smoke-at.py dump                     the tree: role, name, description, place
  smoke-at.py find TEXT [--exact] [--in WINDOW] [--role ROLE] [--nth N]
                                       "x y": where on the screen the middle is
                                       of the Nth (0-based) showing widget whose
                                       name or description has (or, with
                                       --exact, is) TEXT, in windows named like
                                       WINDOW
  smoke-at.py press TEXT [same options]
                                       presses that widget (or the button it is
                                       in) through its accessible action: for
                                       buttons and menu items, which a popover
                                       puts in a window of its own that can't
                                       be found on the screen
"""
import re
import subprocess
import sys

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402


def children(node):
    try:
        return [node.get_child_at_index(i) for i in range(node.get_child_count())]
    except Exception:
        return []


def walk(node, window=None, depth=0):
    """Yields (node, its top-level window's node, depth)."""
    if node is None:
        return
    yield node, window, depth
    for child in children(node):
        # An application (depth 1) has its windows as children.
        yield from walk(child, child if depth == 1 else window, depth + 1)


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
    """x, y, width, height within its window, if the widget is showing. GTK 4
    only tells where a widget is in its window, not on the screen."""
    try:
        if not node.get_state_set().contains(Atspi.StateType.SHOWING):
            return None
        e = node.get_extents(Atspi.CoordType.WINDOW)
        return (e.x, e.y, e.width, e.height) if e.width > 0 and e.height > 0 else None
    except Exception:
        return None


def origin(window):
    """Where `window` (an accessible) is on the screen: the X window with its
    title and size, asked from xdotool."""
    size = place(window)
    if size is None:
        return None
    try:
        ids = subprocess.run(["xdotool", "search", "--name", "^" + re.escape(text(window)) + "$"],
                             capture_output=True, text=True).stdout.split()
    except OSError:
        return None
    best = None
    for xid in ids:
        geometry = dict(line.split("=", 1) for line in subprocess.run(
            ["xdotool", "getwindowgeometry", "--shell", xid], capture_output=True, text=True).stdout.split() if "=" in line)
        try:
            x, y, w, h = (int(geometry[k]) for k in ("X", "Y", "WIDTH", "HEIGHT"))
        except (KeyError, ValueError):
            continue
        off = abs(w - size[2]) + abs(h - size[3])
        if best is None or off <= best[0]:
            best = (off, x, y)
    return best[1:] if best else None


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
            print("  " * depth + f"{role} {text(node)!r} {describe(node)!r} {place(node)}"
                  + (f" at {origin(node)}" if depth == 2 else ""))
        return 0
    if args[:1] in (["find"], ["press"]) and len(args) >= 2:
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
            if depth < 3 or (within is not None and within not in text(window)):
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
            if not where:
                continue
            if args[0] == "press":
                found.append(node)
            elif corner := origin(window):
                found.append((corner[0] + where[0] + where[2] // 2, corner[1] + where[1] + where[3] // 2))
        if len(found) > nth and args[0] == "press":
            node = found[nth]
            for _ in range(4):  # a button's label has no action of its own
                try:
                    if node.get_n_actions() > 0 and node.do_action(0):
                        return 0
                except Exception:
                    pass
                node = node.get_parent()
            print(f"{wanted!r} can't be pressed", file=sys.stderr)
            return 1
        if len(found) > nth:
            print(*found[nth])
            return 0
        print(f"no showing widget with {wanted!r}", file=sys.stderr)
        return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
