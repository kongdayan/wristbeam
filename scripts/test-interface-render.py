#!/usr/bin/env python3
"""Render production SwiftUI views with synthetic preview data; never use an account."""
from pathlib import Path
import subprocess
import tempfile
import argparse
import sys

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
        model.autoSync = true; model.cloudSyncEnabled = true; model.autoUpload = true
        model.cloudSyncEnabled = false
        precondition(model.autoSync && !model.autoUpload && !model.cloud.networkEnabled)
        precondition(model.healthStatus == "仅本地" && model.seriesStatus == "仅本地")
        precondition(!model.uploads.automaticSyncEnabled && model.cloud.requestCount == 0)
        model.cloudSyncEnabled = true
        precondition(!model.autoUpload && !model.uploads.automaticSyncEnabled)
        model.cloudSyncEnabled = false
        print("PASS local mode preserves receiving and does not re-enable automatic uploads")
        // Seed only the isolated preview directory; no cloud login or network calls.
        let activityScope = "china:render-fixture"
        let activityStore = GarminActivityStore(root: AppPaths.directory("CloudActivities"), scope: activityScope)
        let activity = GarminActivity(id: "1001", name: "Synthetic morning run", type: "running",
            startTimeGMT: "2026-01-02 02:00:00", startTimeLocal: "2026-01-02 10:00:00",
            statistics: ["duration":1800,"distance":5000,"averageHR":135,"maxHR":152,"calories":320,"aerobicTrainingEffect":2.8,"averageSpeed":2.8,"elevationGain":40,"averageTemperature":20,"waterEstimated":450], fetchedAt:Date())
        var activityIndex = GarminActivityIndex(); activityIndex.activities = [activity]; activityIndex.refreshedAt = Date(); activityIndex.reachedEnd = true
        try activityStore.saveIndex(activityIndex)
        try activityStore.save(GarminActivityDetail(summary:activity, series:[
            GarminActivitySeries(key:"directHeartRate",unit:"bpm",factor:1,values:[100,110,120,nil,130,140,135,145]),
            GarminActivitySeries(key:"directAirTemperature",unit:"celcius",factor:1,values:[20,21,21,22,22,23,22,21]),
            GarminActivitySeries(key:"directElevation",unit:"m",factor:1,values:[100,102,104,105,107,106,108,110]),
            GarminActivitySeries(key:"sumDuration",unit:"s",factor:1,values:[0,60,120,180,240,300,360,420]),
            GarminActivitySeries(key:"directTimestamp",unit:"gmt",factor:0,values:(0..<8).map { 1_767_319_200_000.0 + Double($0) * 60_000 })],
            fetchedAt:Date(),chartPointLimit:1000,chartAvailable:true,
            heartRateZones:[.init(number:1,seconds:300,lowerBPM:90),.init(number:2,seconds:600,lowerBPM:110),.init(number:3,seconds:900,lowerBPM:130)],
            laps:[.init(index:1,statistics:["duration":600,"distance":1500,"averageHR":120]),.init(index:2,statistics:["duration":1200,"distance":3500,"averageHR":140])],unavailableSections:[]))
        AppPreferences.shared.set(GarminPrivateFile.digest(Data(activityScope.utf8)),forKey:"activities.scope.china")
        model.activities.attach(model.cloud)
        let workouts = try model.developerQuery("activities",arguments:[:]) as! [String:Any]
        precondition((workouts["activities"] as! [[String:Any]]).count == 1)
        let workout = try model.developerQuery("activity",arguments:["id":"1001"]) as! [String:Any]
        precondition(workout["detailCached"] as? Bool == true)
        let chart = try model.developerQuery("activity_series",arguments:["id":"1001","metric":"directHeartRate"]) as! [String:Any]
        precondition((chart["values"] as! [Any]).count == 8 && model.cloud.requestCount == 0)
        print("PASS AppModel activity MCP queries read only the selected offline cache")
        for format in [nil, GarminActivityFormat.tcx, .gpx, .original] {
            let panel = ActivityExportPanel.make(id:"1001",format:format)
            let expected = "WristBeam-activity-1001." + (format?.fileExtension ?? "json")
            precondition(panel.nameFieldStringValue == expected && !panel.isExtensionHidden)
        }
        print("PASS native export save panels preserve one JSON/TCX/GPX/ZIP extension")
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
                for page in [AppPage.overview,.activities,.watch,.account,.connectIQ,.sync,.settings,.appearance,.developer,.updates,.about] {
                    model.page = page
                    try render(SettingsRootView(model:model).frame(width:1020,height:768),name:"page-\(page.rawValue)-\(language)-\(theme)",dark:dark,output:output)
                }
                try render(MenuPopover(model:model),name:"menu-\(language)-\(theme)",dark:dark,output:output)
                model.page = .overview; model.detailMetric = .hrvNight
                try render(SettingsRootView(model:model).frame(width:1020,height:768),name:"hrv-\(language)-\(theme)",dark:dark,output:output)
                model.detailMetric = nil
                model.page = .activities; model.selectedActivityID = "1001"
                try render(SettingsRootView(model:model).frame(width:1020,height:768),name:"activity-detail-\(language)-\(theme)",dark:dark,output:output)
                model.selectedActivityID = nil
                if let detail = model.activities.detail("1001") {
                    try render(ActivityChartsSection(detail:detail).padding(24).frame(width:820),name:"activity-charts-\(language)-\(theme)",dark:dark,output:output)
                    try render(ActivityZonesSection(detail:detail).padding(24).frame(width:820),name:"activity-zones-\(language)-\(theme)",dark:dark,output:output)
                    try render(ActivityLapsSection(detail:detail).padding(24).frame(width:820),name:"activity-laps-\(language)-\(theme)",dark:dark,output:output)
                    try render(ActivityStatisticsSection(statistics:detail.summary.statistics,initiallyExpanded:true).padding(24).frame(width:820),name:"activity-statistics-\(language)-\(theme)",dark:dark,output:output)
                }
            }
        }
        precondition(model.cloud.requestCount == 0)
        print("PASS: production-view renders including cached activity detail and Connect IQ; Chinese/English, light/dark, compact/detailed, device battery, HRV, 100%/160% font; no cloud requests")
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
    command = ['swiftc', '-swift-version', '5', '-o', str(binary), *map(str, sources), str(runner)]
    subprocess.run([sys.executable, str(root / 'scripts/ci-metrics.py'), 'measure', '--name', 'interface-compile',
                    '--output', str(output / 'interface-compile-timing.json'), '--', *command], check=True, cwd=root)
    if args.compile_only:
        print('PASS: native views compiled; GPU rendering explicitly not executed')
    else:
        subprocess.run([sys.executable, str(root / 'scripts/ci-metrics.py'), 'measure', '--name', 'interface-render',
                        '--output', str(output / 'interface-render-timing.json'), '--', str(binary), str(output), '--preview'], check=True, cwd=root)
