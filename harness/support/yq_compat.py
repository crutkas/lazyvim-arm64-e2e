#!/usr/bin/env python3
"""Minimal yq-compatible YAML stream converter for Mason's file registry."""

from __future__ import annotations

import json
import sys

import yaml


def main() -> int:
    try:
        documents = yaml.safe_load_all(sys.stdin.buffer.read().decode("utf-8"))
        for document in documents:
            if document is not None:
                print(json.dumps(document, separators=(",", ":")))
    except Exception as error:
        print(f"yq compatibility converter failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
