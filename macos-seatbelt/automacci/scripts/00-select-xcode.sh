#!/bin/bash
if [ ! -d /Applications/Xcode.app ]; then
    echo "Xcode.app not installed; skipping (install it and re-run this script)"
    exit 1
fi
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer/
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch || true
