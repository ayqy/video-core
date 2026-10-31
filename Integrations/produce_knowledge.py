#!/usr/bin/env python3
"""Produce one explicit knowledge document through normal Core/Host commands."""
import argparse
from pathlib import Path

from production_document import DocumentProduction


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('document', 'binary', 'home', 'output', 'voice'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--binary-sha256', required=True)
    parser.add_argument('--boundaries', type=Path)
    parser.add_argument('--executor', type=Path)
    parser.add_argument('--catalog', type=Path)
    parser.add_argument('stage', choices=('prepare', 'render', 'verify'))
    args = parser.parse_args()
    args.previous_inputs_sha256 = None
    production = DocumentProduction(args)
    getattr(production, args.stage)()


if __name__ == '__main__':
    main()
