#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library -typecheck \
  Sources/GarminBar/Models/PulseWidgetSnapshot.swift WidgetExtension/GarminPulseWidget.swift
printf '%s\n' 'WidgetKit source typecheck passed. This does not sign or register a desktop widget.'
