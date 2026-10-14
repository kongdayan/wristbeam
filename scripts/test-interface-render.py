#!/usr/bin/env python3
"""Render production SwiftUI views with synthetic preview data; never use an account."""
from pathlib import Path
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parent.parent
output = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(tempfile.mkdtemp(prefix='wristbeam-interface-renders-'))
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
                        model.floatingMetrics = [.bodyBattery,.hrvNight,.watchBattery]
                        let name = "floating-\(language)-\(theme)-\(detailed ? "detailed" : "compact")-\(Int(scale*100))"
                        try render(FloatingPulseView(model:model),name:name,dark:dark,output:output)
                    }
                }
                model.fontScale = 1.15
                for page in [AppPage.overview,.settings,.appearance,.developer,.updates,.about] {
                    model.page = page
                    try render(SettingsRootView(model:model).frame(width:1020,height:768),name:"page-\(page.rawValue)-\(language)-\(theme)",dark:dark,output:output)
                }
            }
        }
        print("PASS: 40 production-view renders; Chinese/English, light/dark, compact/detailed, 100%/160% font")
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
    subprocess.run([str(binary), str(output), '--preview'], check=True, cwd=root)
