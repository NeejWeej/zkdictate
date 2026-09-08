#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$PATH:$HOME/.local/bin"
unset VIRTUAL_ENV
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "ZK Dictate requires macOS 14+ on Apple Silicon." >&2
  exit 1
fi
MACOS_VERSION="$(sw_vers -productVersion)"
if (( ${MACOS_VERSION%%.*} < 14 )); then
  echo "ZK Dictate requires macOS 14 or newer." >&2
  exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple's developer tools are needed to build ZK Dictate."
  xcode-select --install || true
  echo "Finish Apple's installer, then run Install.command again."
  exit 1
fi
if ! command -v uv >/dev/null 2>&1; then
  echo "Installing uv for your user account…"
  installer_file="$(mktemp -t zkdictate-uv)"
  trap 'rm -f "$installer_file"' EXIT
  curl --proto '=https' --tlsv1.2 -fLsS https://astral.sh/uv/install.sh -o "$installer_file"
  UV_INSTALL_DIR="$HOME/.local/bin" UV_NO_MODIFY_PATH=1 sh "$installer_file"
  rm -f "$installer_file"
  trap - EXIT
fi
printf '\n[1/3] Preparing Python and dependencies…\n'
uv sync --locked --python 3.12
printf '\n[2/3] Building ZK Dictate…\n'
uv run --frozen python scripts/build_app.py
printf '\n[3/3] Installing the app…\n'
uv run --frozen python scripts/install_app.py "$@"
