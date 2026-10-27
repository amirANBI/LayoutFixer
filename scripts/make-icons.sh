#!/bin/sh
# Regenerates the icons in Resources/ from icon/make_icon.py. Works on any OS (the icons are PNG
# frames packed into .ico), so you can also run it from macOS or WSL:
#
#   ./scripts/make-icons.sh
#
# Needs Python 3 with Pillow: python3 -m pip install pillow arabic-reshaper python-bidi
set -e
cd "$(dirname "$0")/.."
python3 icon/make_icon.py .
