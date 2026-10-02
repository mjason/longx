#!/usr/bin/env python3
"""Reject all notarization results except an explicit Accepted response."""
import json
from pathlib import Path
import sys


def check(path):
    result = json.loads(Path(path).read_text())
    if result.get('status') != 'Accepted':
        raise RuntimeError(f"Apple notarization failed: {result.get('status', 'missing status')}; submission {result.get('id', 'unknown')}")
    print(f"Apple notarization accepted: {result.get('id', 'unknown')}")


if __name__ == '__main__':
    check(sys.argv[1])
