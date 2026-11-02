#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if ! xcode-select -p >/dev/null 2>&1; then
	echo "installing xcode command line tools, rerun this script when it finishes"
	xcode-select --install
	exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
	/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
	eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
fi

brew bundle --file Brewfile
nvim --headless -u NONE -l bootstrap.lua
