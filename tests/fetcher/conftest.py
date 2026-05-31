"""
Pytest configuration shared across all fetcher tests.

Adds the project's fetcher/ directory to sys.path so tests can import
astrowidget_fetch directly: `from astrowidget_fetch import load_config`.
"""

import sys
from pathlib import Path

# fetcher/ lives at ~/Claude/astrowidget/fetcher/; this file is at
# ~/Claude/astrowidget/tests/fetcher/conftest.py. Walk up twice to find
# project root.
PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "fetcher"))
