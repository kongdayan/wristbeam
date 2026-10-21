#!/usr/bin/env python3
"""Run the core XCTest methods with CLT-only Swift; no full Xcode required."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
sources = root / "Sources/GarminBar"
production = sorted((sources / "Protocol").glob("*.swift"))
production += [sources / "Developer/DeveloperConfiguration.swift", sources / "Developer/DeveloperProtocol.swift", sources / "Developer/DeveloperServer.swift", sources / "Developer/DeveloperSecrets.swift", sources / "Developer/DeveloperClients.swift", sources / "Developer/ActivityQueries.swift", sources / "Developer/DeveloperQueries.swift", sources / "Developer/HealthSummary.swift"]
production += [sources / "Models/ActivityMetricCatalog.swift", sources / "Models/ConnectIQLibrary.swift"]
production += [sources / "Models" / name for name in ("Metrics.swift", "MetricFreshness.swift", "HealthAccountScope.swift", "ChartSampling.swift", "HealthHistoryReader.swift", "AppStorage.swift", "LocalDataArchive.swift", "ConnectionPolicy.swift", "WorkflowPresentation.swift", "MetricTimeSeries.swift", "DisplaySettings.swift", "DashboardSharing.swift", "PulseWidgetSnapshot.swift", "WatchDiscovery.swift", "Localization.swift", "SoftwareRelease.swift")]
production += [sources / "Cloud" / name for name in (
    "GarminCloudModels.swift", "GarminFITFileClassifier.swift", "GarminHealthMetrics.swift", "GarminHRV.swift", "GarminDailySeries.swift",
    "GarminChinaCloud.swift", "GarminUploadQueue.swift", "GarminWeather.swift", "OpenMeteoWeather.swift", "GarminActivities.swift", "ActivityLibrary.swift",
    "ConnectIQModels.swift", "ConnectIQSettingsCloud.swift")]

with tempfile.TemporaryDirectory(prefix="garmin-pulse-tests-") as temporary:
    stage = Path(temporary)
    converted = []
    calls = []
    for test in sorted((root / "Tests/GarminBarTests").glob("*.swift")):
        original = test.read_text()
        body = re.sub(r"(?m)^import XCTest\s*$|^@testable import GarminBar\s*$", "", original)
        target = stage / test.name
        target.write_text("import Foundation\n" + body)
        converted.append(target)
        classes = list(re.finditer(r"final class (\w+): XCTestCase", body))
        for index, match in enumerate(classes):
            end = classes[index + 1].start() if index + 1 < len(classes) else len(body)
            for method in re.finditer(r"func (test\w+)\(\)([^\{]*)\{", body[match.end():end]):
                name, qualifiers = method.groups()
                prefix = ("try " if "throws" in qualifiers else "") + ("await " if "async" in qualifiers else "")
                label = match.group(1) + "." + name
                calls += [f"{prefix}{match.group(1)}().{name}()", f'print("PASS {label}")']
    runner = stage / "Runner.swift"
    runner.write_text("import Foundation\n@main struct CoreTestRunner {\n @MainActor static func main() async throws {\n"
                      + "\n".join("  " + line for line in calls)
                      + f'\n  print("PASS: {len(calls) // 2} core tests; CLT assertion harness, same XCTest methods")\n }}\n}}\n')
    binary = stage / "core-checks"
    subprocess.run(["swiftc", "-swift-version", "5", "-o", str(binary),
                    *map(str, production), str(root / "scripts/support/Assertions.swift"),
                    *map(str, converted), str(runner)], check=True, cwd=root)
    subprocess.run([str(binary)], check=True, cwd=root)
