"""Add synced projects that `repo manifest -r` leaves out of the pinned manifest.

`repo manifest -r` omits projects in the `notdefault` group even when the platform filter
(manifest.platform=auto -> platform-windows) synced them, e.g. prebuilts/clang/host/windows-x86.
Without them `fetch.ps1 -Pinned` would not reproduce the tree. For every project of the source
manifest that is checked out under ROOT but missing from PIN, this appends it with the exact
commit of its worktree.

usage: python -I complete-pin.py ROOT PIN
"""
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def main(root: Path, pin_file: Path) -> int:
    source = ET.parse(root / ".repo" / "manifests" / "default.xml").getroot()
    default_rev = source.find("default").get("revision")
    pin_tree = ET.parse(pin_file)
    pin = pin_tree.getroot()
    pinned = {p.get("name") for p in pin.iter("project")}

    added = []
    for p in source.iter("project"):
        name = p.get("name")
        path = p.get("path") or name
        if name in pinned or not (root / path / ".git").exists():
            continue
        rev = subprocess.run(
            ["git", "-C", str(root / path), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        el = ET.SubElement(pin, "project", {
            "name": name,
            "path": path,
            "revision": rev,
            "upstream": p.get("revision", default_rev),
            "dest-branch": p.get("revision", default_rev),
        })
        for attr in ("groups", "clone-depth", "remote"):
            if p.get(attr):
                el.set(attr, p.get(attr))
        el.tail = "\n"
        added.append(path)

    if added:
        ET.indent(pin_tree, space="  ")
        pin_tree.write(pin_file, encoding="UTF-8", xml_declaration=True)
    print(f"complete-pin: added {len(added)} project(s): {', '.join(added) or '-'}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(Path(sys.argv[1]), Path(sys.argv[2])))
