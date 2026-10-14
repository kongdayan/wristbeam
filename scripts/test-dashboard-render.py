#!/usr/bin/env python3
"""Render the actual share canvas with synthetic data, without a watch/account/UI session."""
from pathlib import Path
import subprocess
import tempfile
import argparse

root = Path(__file__).resolve().parent.parent
sources = root / 'Sources/GarminBar'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', nargs='?', type=Path)
parser.add_argument('--compile-only', action='store_true', help='Compile native views without invoking the GPU renderer')
args = parser.parse_args()
output = args.output or Path(tempfile.mkdtemp(prefix='wristbeam-native-renders-'))
output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='wristbeam-render-test-') as temporary:
    stage = Path(temporary)
    files = [sources / 'Models' / name for name in ('Metrics.swift', 'AppStorage.swift', 'ConnectionPolicy.swift', 'MetricTimeSeries.swift', 'DisplaySettings.swift', 'DashboardSharing.swift', 'Localization.swift')]
    files += sorted((sources / 'Protocol').glob('*.swift'))
    files += [sources / 'Cloud' / name for name in ('GarminCloudModels.swift', 'GarminHealthMetrics.swift', 'GarminHRV.swift', 'GarminDailySeries.swift')]
    files.append(sources / 'UI/MetricIcon.swift')
    for filename, content in {
        'Theme.swift': (sources / 'UI/Theme.swift').read_text().split('struct MetricCard: View')[0],
        'HRVMiniChart.swift': (sources / 'UI/HRVViews.swift').read_text().split('struct HRVDetailView:')[0],
        'MiniChart.swift': (sources / 'UI/MetricCharts.swift').read_text().split('private enum ChartWindow:')[0],
        'Canvas.swift': 'import SwiftUI\n' + (sources / 'UI/DashboardSharingView.swift').read_text().split('private struct DashboardShareCanvas: View')[1].split('private struct NativeImageShareButton:')[0],
    }.items():
        if filename == 'Canvas.swift':
            content = content.replace('import SwiftUI\n {', 'import SwiftUI\nstruct DashboardShareCanvas: View {', 1)
        target = stage / filename
        target.write_text(content)
        files.append(target)
    runner = stage / 'Runner.swift'
    runner.write_text(r'''
import AppKit
import SwiftUI
@main struct RenderTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        L10n.language = .zhHans
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let day = Calendar.current.startOfDay(for: Date())
        let kinds = MetricKind.allCases
        let metrics = kinds.enumerated().map { index, kind in
            SharedMetric(kind: kind, value: String(42 + index), updatedAt: day.addingTimeInterval(43200), unavailable: false,
                         series: MetricDaySeries(kind: kind.timelineKind ?? kind, day: day, points: [
                            MetricSeriesPoint(timestamp: day.addingTimeInterval(3600), value: 20),
                            MetricSeriesPoint(timestamp: day.addingTimeInterval(7200), value: 50)
                         ], source: "", refreshedAt: day))
        }
        var heights: [String: Int] = [:]
        for (name, items, scalar, dark, english) in [
            ("all-light", metrics, false, false, false), ("all-dark", metrics, false, true, false),
            ("selected", Array(metrics.prefix(3)), false, false, false),
            ("selected-en", Array(metrics.prefix(3)), false, false, true),
            ("value", Array(metrics.prefix(1)), true, true, false)
        ] {
            L10n.language = english ? .en : .zhHans
            let renderer = ImageRenderer(content: DashboardShareCanvas(metrics: items, capturedAt: day, valueOnly: scalar, preview: true, dark: dark).environment(\.colorScheme, dark ? .dark : .light).environment(\.locale, L10n.locale))
            renderer.scale = 2
            guard let image = renderer.cgImage else { fatalError("Canvas failed: \(name)") }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG failed") }
            precondition(image.width >= 900 && image.height >= 400 && png.count > 5000)
            try png.write(to: output.appendingPathComponent(name + ".png"))
            heights[name] = image.height
            print("PASS \(name): \(items.count) metrics, \(image.width)x\(image.height), \(png.count) bytes")
        }
        precondition(heights["all-light"]! > heights["selected"]! * 3)
        precondition(heights["all-light"] == heights["all-dark"])
        print("PASS: complete dashboard, selected cards, single value; light/dark native rendering")
    }
}
''')
    files.append(runner)
    binary = stage / 'render-tests'
    subprocess.run(['swiftc', '-swift-version', '5', '-o', str(binary), *map(str, files)], check=True, cwd=root)
    if args.compile_only:
        print('PASS: native views compiled; GPU rendering explicitly not executed')
    else:
        subprocess.run([str(binary), str(output), '--preview'], check=True, cwd=root)
