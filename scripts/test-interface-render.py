#!/usr/bin/env python3
"""Render production SwiftUI views with synthetic preview data; never use an account."""
from pathlib import Path
import subprocess
import tempfile
import argparse

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', nargs='?', type=Path)
parser.add_argument('--compile-only', action='store_true', help='Compile native views without invoking the GPU renderer')
args = parser.parse_args()
output = args.output or Path(tempfile.mkdtemp(prefix='wristbeam-native-renders-'))
output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='wristbeam-interface-test-') as temporary:
    stage = Path(temporary)
    sources = sorted((root / 'Sources/GarminBar').rglob('*.swift'))
    sources = [p for p in sources if p.name != 'GarminPulseApp.swift']
    runner = stage / 'Runner.swift'
    runner.write_text(r'''
import AppKit
import SwiftUI
@main struct InterfaceRenderTests {
    @MainActor static func main() throws {
        precondition(PulseRuntime.isPreview)
        _ = NSApplication.shared
        let output = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let model = AppModel()
        model.enablePreview()
        model.receive(MetricSample(kind:.watchBattery,value:77,source:"fixture"))
        precondition(model.metrics[.watchBattery]?.value == 77)
        precondition(model.history[.watchBattery] == nil && model.series(for:.watchBattery) == nil)
        precondition(!model.availableMetricKinds.contains(.watchBattery))
        let status = try model.developerQuery("status",arguments:[:]) as! [String:Any]
        precondition((status["watchBattery"] as? [String:Any])?["percent"] as? Double == 77)
        let catalog = try model.developerQuery("catalog",arguments:[:]) as! [String:Any]
        let battery = (catalog["metrics"] as! [[String:Any]]).first { $0["id"] as? String == "watchBattery" }!
        precondition(battery["deviceStatus"] as? Bool == true && battery["timeline"] as? Bool == false)
        print("PASS device battery stays current without health history, selection or timeline")
        for english in [false,true] {
            model.language = english ? .en : .zhHans
            let language = english ? "en" : "zh"
            for dark in [false,true] {
                model.appearance = dark ? .dark : .light
                let theme = dark ? "dark" : "light"
                for detailed in [false,true] {
                    model.floatingDetailed = detailed
                    for scale in [1.0,1.6] {
                        model.fontScale = scale
                        model.floatingSize = .small
                        model.floatingMetrics = [.bodyBattery,.hrvNight,.heartRate]
                        let name = "floating-\(language)-\(theme)-\(detailed ? "detailed" : "compact")-\(Int(scale*100))"
                        try render(FloatingPulseView(model:model),name:name,dark:dark,output:output)
                    }
                }
                model.fontScale = 1.15
                for page in [AppPage.overview,.watch,.settings,.appearance,.developer,.updates,.about] {
                    model.page = page
                    try render(SettingsRootView(model:model).frame(width:1020,height:768),name:"page-\(page.rawValue)-\(language)-\(theme)",dark:dark,output:output)
                }
                try render(MenuPopover(model:model),name:"menu-\(language)-\(theme)",dark:dark,output:output)
                model.page = .overview; model.detailMetric = .hrvNight
                try render(SettingsRootView(model:model).frame(width:1020,height:768),name:"hrv-\(language)-\(theme)",dark:dark,output:output)
                model.detailMetric = nil
            }
        }
        print("PASS: 52 production-view renders; Chinese/English, light/dark, compact/detailed, device battery, HRV, 100%/160% font")
    }
    @MainActor static func render<V:View>(_ view:V,name:String,dark:Bool,output:URL) throws {
        let host = NSHostingView(rootView:view.environment(\.colorScheme,dark ? .dark : .light).environment(\.locale,L10n.locale))
        let size = host.fittingSize
        host.frame = NSRect(origin:.zero,size:size)
        let window = NSWindow(contentRect:host.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { fatalError("Render failed: \(name)") }
        host.cacheDisplay(in:host.bounds,to:bitmap)
        guard let data = bitmap.representation(using:.png,properties:[:]) else { fatalError("PNG failed") }
        precondition(bitmap.pixelsWide >= 300 && bitmap.pixelsHigh >= 225 && data.count > 5000)
        try data.write(to:output.appendingPathComponent(name + ".png"))
        print("PASS \(name): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
}
''')
    binary = stage / 'render-interface'
    subprocess.run(['swiftc', '-swift-version', '5', '-o', str(binary), *map(str, sources), str(runner)], check=True, cwd=root)
    if args.compile_only:
        print('PASS: native views compiled; GPU rendering explicitly not executed')
    else:
        subprocess.run([str(binary), str(output), '--preview'], check=True, cwd=root)
