#!/usr/bin/env python3
"""Refresh generated installation/signing details while retaining hand-edited changes."""
import json
from pathlib import Path
import sys

begin = "<!-- kiosk-build:begin -->"
end = "<!-- kiosk-build:end -->"
existing_path, generated_path, output_path = map(Path, sys.argv[1:])
body = json.loads(existing_path.read_text())["body"] or ""
generated = generated_path.read_text().strip()
if body.count(begin) != 1 or body.count(end) != 1 or body.index(begin) >= body.index(end):
    sys.exit("The draft's generated-note markers are missing or changed. Restore them before rerunning so edited notes can be preserved.")
start = body.index(begin)
finish = body.index(end) + len(end)
output_path.write_text(body[:start] + generated + body[finish:])
