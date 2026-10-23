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
        // A command-line render harness does not receive normal app launch/activation.
        // On macOS 14 an inactive window consumes the first click for activation.
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        let output = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let model = AppModel()
        model.enablePreview()
        verifyDisclosureHitTargets()
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
        model.page = .activities
        model.detailMetric = .heartRate
        model.openSettings(.appearance)
        precondition(model.page == .activities && model.detailMetric == .heartRate && model.settingsPage == .appearance)
        model.openSettings(.account)
        precondition(model.page == .account && model.detailMetric == nil && model.settingsPage == .appearance)
        precondition(AppPage.navigationPages.allSatisfy { !$0.isSettings })
        print("PASS preferences routing preserves main content and device links return to the main window")
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
        // Exercise the actual NSScrollView through list/detail reconstruction, not just model fields.
        let browsingScope = "china:workflow-fixture"
        let browsingStore = GarminActivityStore(root: AppPaths.directory("CloudActivities"), scope: browsingScope)
        var browsingIndex = GarminActivityIndex()
        browsingIndex.activities = [activity] + (1002...1060).map { id in
            GarminActivity(id: String(id), name: "Synthetic run \(id)", type: "running",
                startTimeLocal: "2026-01-02 10:00:00", statistics: ["duration":1800], fetchedAt: Date())
        }
        try browsingStore.saveIndex(browsingIndex)
        if let detail = model.activities.detail("1001") { try browsingStore.save(detail) }
        AppPreferences.shared.set(GarminPrivateFile.digest(Data(browsingScope.utf8)),forKey:"activities.scope.china")
        model.activities.reconcile()
        model.page = .activities; model.detailMetric = nil; model.selectedActivityID = nil
        model.activityBrowsing = ActivityBrowsingState(search:"Synthetic",page:1)
        let navigationHost = NSHostingView(rootView: SettingsRootView(model:model).frame(width:1020,height:768))
        navigationHost.frame = NSRect(x:0,y:0,width:1020,height:768)
        let navigationWindow = NSWindow(contentRect:navigationHost.frame,styleMask:.borderless,backing:.buffered,defer:false)
        navigationWindow.contentView = navigationHost
        func settle() { navigationHost.layoutSubtreeIfNeeded(); RunLoop.main.run(until:Date().addingTimeInterval(0.1)) }
        func descendants(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func scrollViews(_ view:NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        func contentScroll() -> NSScrollView {
            if let view = descendants(navigationHost).compactMap({ $0 as? ScrollPositionKeeper.Probe }).first(where: { $0.key == model.mainScrollKey && !$0.stopped })?.scroll { return view }
            return scrollViews(navigationHost).max { $0.frame.width < $1.frame.width }!
        }
        func trace(_ message:String) { FileHandle.standardOutput.write(Data((message + "\n").utf8)) }
        func readyForRoute(scrollable:Bool = false) {
            let deadline = Date().addingTimeInterval(8)
            var stable = 0, lastHeight:CGFloat = -1
            while Date() < deadline {
                settle()
                guard let probe = descendants(navigationHost).compactMap({ $0 as? ScrollPositionKeeper.Probe }).first(where: { $0.key == model.mainScrollKey && !$0.stopped }), probe.ready,
                      let view = probe.scroll else { continue }
                let height = view.documentView?.bounds.height ?? 0
                stable = abs(height-lastHeight) < 1 ? stable+1 : 0; lastHeight = height
                if stable >= 2 && (!scrollable || height-view.contentView.bounds.height > 100) { return }
            }
            let view = contentScroll()
            trace("Layout timeout route=\(model.mainScrollKey) document=\(view.documentView?.bounds.height ?? -1) viewport=\(view.contentView.bounds.height)")
            preconditionFailure("Native route did not finish scroll layout")
        }
        func moveDown() -> CGFloat {
            readyForRoute(scrollable:true)
            let view = contentScroll()
            view.contentView.scroll(to:NSPoint(x:0,y:500)); view.reflectScrolledClipView(view.contentView); settle()
            let y = view.contentView.bounds.origin.y
            trace("Scroll fixture route=\(model.mainScrollKey) y=\(y) document=\(view.documentView?.bounds.height ?? -1) viewport=\(view.contentView.bounds.height)")
            precondition(y > 100,"Fixture must scroll before checking restoration")
            return y
        }
        let listY = moveDown()
        let selected = model.activityBrowsing.visible(model.activities.index.activities)[4].id
        model.selectActivity(selected); readyForRoute()
        precondition(contentScroll().contentView.bounds.origin.y < 2,"New activity detail starts at top")
        model.goBack(); readyForRoute(scrollable:true)
        precondition(model.activityBrowsing.search == "Synthetic" && model.activityBrowsing.page == 1)
        trace("Returned list y=\(contentScroll().contentView.bounds.origin.y), expected=\(listY)")
        precondition(abs(contentScroll().contentView.bounds.origin.y-listY) < 3,"Return restores actual list scroll offset")
        model.openSettings(.appearance); settle()
        precondition(abs(contentScroll().contentView.bounds.origin.y-listY) < 3,"Preferences preserve list position")
        model.page = .overview
        let dashboardY = moveDown()
        model.openMetric(.heartRate); readyForRoute()
        precondition(contentScroll().contentView.bounds.origin.y < 2,"New metric detail starts at top")
        model.goBack(); readyForRoute(scrollable:true)
        trace("Returned dashboard y=\(contentScroll().contentView.bounds.origin.y), expected=\(dashboardY)")
        precondition(abs(contentScroll().contentView.bounds.origin.y-dashboardY) < 3,"Return restores dashboard offset")
        let modalSheet = NSWindow(contentRect:NSRect(x:0,y:0,width:240,height:120),styleMask:.titled,backing:.buffered,defer:false)
        modalSheet.isReleasedWhenClosed = false
        precondition(NavigationWindowPolicy.allowsNavigation(key:navigationWindow,main:navigationWindow,preferences:nil,modal:nil))
        navigationWindow.beginSheet(modalSheet); settle()
        precondition(modalSheet.sheetParent === navigationWindow,"Fixture must attach a real AppKit sheet")
        precondition(!NavigationWindowPolicy.allowsNavigation(key:modalSheet,main:nil,preferences:nil,modal:nil),"Key sheet alone blocks navigation")
        precondition(!NavigationWindowPolicy.allowsNavigation(key:nil,main:navigationWindow,preferences:nil,modal:nil),"Sheet owner blocks navigation during focus changes")
        precondition(!NavigationWindowPolicy.allowsNavigation(key:nil,main:nil,preferences:navigationWindow,modal:nil),"Preferences sheet also blocks navigation")
        navigationWindow.endSheet(modalSheet); modalSheet.orderOut(nil); settle()
        precondition(NavigationWindowPolicy.allowsNavigation(key:navigationWindow,main:navigationWindow,preferences:nil,modal:nil))
        precondition(!NavigationWindowPolicy.allowsNavigation(key:navigationWindow,main:navigationWindow,preferences:nil,modal:modalSheet))
        print("PASS native sheet-parent, owner-window and application-modal keyboard navigation gates")
        navigationWindow.contentView = nil
        model.selectedActivityID = selected
        model.activityBrowsing = ActivityBrowsingState(search:"Synthetic",page:1)
        AppPreferences.shared.set(GarminPrivateFile.digest(Data("china:empty-workflow-fixture".utf8)),forKey:"activities.scope.china")
        model.activities.reconcile()
        precondition(model.selectedActivityID == nil && model.activityBrowsing == ActivityBrowsingState(),"Changing account clears list/detail context")
        precondition(!model.scrollPositions.offsets.keys.contains { $0.hasPrefix("activity.") || $0 == "page.activities" })
        AppPreferences.shared.set(GarminPrivateFile.digest(Data(browsingScope.utf8)),forKey:"activities.scope.china")
        model.activities.reconcile()
        model.scrollPositions.offsets = [:]; model.activityBrowsing = ActivityBrowsingState()
        print("PASS native list/detail and dashboard/detail scroll restoration, search/page retention and independent preferences")
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
                model.fontScale = 1.6
                for step in WatchSetupStep.allCases {
                    model.bluetooth.isScanning = step == .choose
                    model.bluetooth.isConnecting = step == .confirm
                    model.bluetooth.isConnected = step == .sync
                    model.bluetooth.canSyncFiles = step == .sync
                    try render(PairingGuide(model:model).padding(24).frame(width:640),name:"pairing-\(step.rawValue)-\(language)-\(theme)",dark:dark,output:output)
                }
                model.bluetooth.isScanning = false; model.bluetooth.isConnecting = false
                model.bluetooth.isConnected = false; model.bluetooth.canSyncFiles = false
                model.fontScale = 1.15
                for page in [AppPage.overview,.activities,.watch,.account,.connectIQ,.sync,.settings,.appearance,.metricSelection,.refresh,.developer,.updates,.about] {
                    model.openSettings(page)
                    if page.isSettings {
                        try render(PreferencesRootView(model:model).frame(width:1020,height:768),name:"page-\(page.rawValue)-\(language)-\(theme)",dark:dark,output:output)
                    } else {
                        try render(SettingsRootView(model:model).frame(width:1020,height:768),name:"page-\(page.rawValue)-\(language)-\(theme)",dark:dark,output:output)
                    }
                }
                try render(SyncPage(model:model,initiallyExpanded:true).padding(24).frame(width:760).background(PulseTheme.background),name:"sync-expanded-\(language)-\(theme)",dark:dark,output:output)
                model.openSettings(.overview)
                model.dashboardGrouped = false
                try render(SettingsRootView(model:model).frame(width:1020,height:768),name:"dashboard-flat-\(language)-\(theme)",dark:dark,output:output)
                model.dashboardGrouped = true
                model.fontScale = 1.6
                try render(SettingsRootView(model:model).frame(width:880,height:640),name:"dashboard-narrow-\(language)-\(theme)",dark:dark,output:output)
                for page in [AppPage.settings,.appearance,.metricSelection,.developer,.updates] {
                    model.settingsPage = page
                    try render(PreferencesRootView(model:model).frame(width:820,height:600),name:"preferences-narrow-\(page.rawValue)-\(language)-\(theme)",dark:dark,output:output)
                }
                try render(SyncPage(model:model,initiallyExpanded:true).padding(24).frame(width:600).background(PulseTheme.background),name:"sync-expanded-narrow-\(language)-\(theme)",dark:dark,output:output)
                model.fontScale = 1.15
                model.activityBrowsing.search = "no-such-fixture"
                model.page = .activities
                try render(SettingsRootView(model:model).frame(width:1020,height:768),name:"activities-no-results-\(language)-\(theme)",dark:dark,output:output)
                model.activityBrowsing.search = ""
                model.lastLocalSavedAt = Date()
                precondition(model.workflow.transferTitle == "已保存到本机")
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
    @MainActor static func verifyDisclosureHitTargets() {
        let fixture = DisclosureInteractionState()
        let host = NSHostingView(rootView: DisclosureInteractionFixture(state: fixture))
        host.frame = NSRect(x:0,y:0,width:600,height:400)
        let window = NSWindow(contentRect:host.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let activationDeadline = Date().addingTimeInterval(5)
        while (!NSApp.isActive || !window.isKeyWindow) && Date() < activationDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        precondition(NSApp.isActive && window.isKeyWindow, "Interaction fixture must be active before clicks")
        func settle() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until:Date().addingTimeInterval(0.1)) }
        func click(_ x:CGFloat,_ yFromTop:CGFloat) {
            settle()
            let local = NSPoint(x:x,y:host.isFlipped ? yFromTop : host.bounds.height - yFromTop)
            let point = host.convert(local,to:nil)
            for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                let event = NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                    windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:type == .leftMouseDown ? 1 : 0)!
                NSApp.postEvent(event,atStart:false)
            }
            while let event = NSApp.nextEvent(matching:.any,until:Date().addingTimeInterval(0.1),inMode:.default,dequeue:true) { NSApp.sendEvent(event) }
            settle()
        }
        settle()
        click(480,24)
        precondition(fixture.expanded,"Disclosure whitespace must expand the section")
        click(480,85)
        precondition(fixture.contentClicks == 1 && fixture.expanded,"Content buttons must act without collapsing the section")
        click(578,24)
        precondition(!fixture.expanded,"Chevron must collapse the section")
        click(480,82)
        precondition(fixture.selected && !fixture.expanded,"Checkbox cell whitespace must toggle without opening the disclosure")
        click(65,24)
        precondition(fixture.expanded,"Label must expand the section")
        fixture.disabled = true; settle(); click(480,24)
        precondition(fixture.expanded,"Disabled disclosure must not toggle")
        window.orderOut(nil)
        print("PASS native mouse events: disclosure label, whitespace, chevron, independent content, selection cell and disabled state")
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
@MainActor final class DisclosureInteractionState: ObservableObject {
    @Published var expanded = false
    @Published var disabled = false
    @Published var selected = false
    var contentClicks = 0
}
struct DisclosureInteractionFixture: View {
    @ObservedObject var state: DisclosureInteractionState
    var body: some View {
        VStack(spacing:12) {
        PulseDisclosure("Sync settings",isExpanded:$state.expanded) {
            Button { state.contentClicks += 1 } label: {
                Text("Content action").frame(maxWidth:.infinity,minHeight:44)
            }.buttonStyle(PulseRowButtonStyle())
        }
        Toggle("Selection",isOn:$state.selected).labelsHidden().toggleStyle(PulseSelectionToggleStyle())
        }.disabled(state.disabled).frame(width:600,height:400,alignment:.topLeading)
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
