#!/usr/bin/env python3
"""Validate real signed packages and reject unsafe packages without launching them."""
from pathlib import Path
import os
import platform
import plistlib
import shutil
import stat
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parent.parent
sources = root / "Sources/GarminBar"
dist = Path(os.environ.get("PULSE_OUTPUT_DIR", root / "dist"))
archive = Path(os.environ.get("PULSE_UPDATE_ARCHIVE", dist / f"WristBeam-macOS-{platform.machine()}.zip"))

with tempfile.TemporaryDirectory(prefix="pulse-update-checks-") as temporary:
    stage = Path(temporary)
    target = stage / "Installed.app"
    shutil.copytree(dist / "WristBeam.app", target)
    for name, member in [("traversal", "WristBeam.app/../../escaped"), ("absolute", "/tmp/pulse-escaped")]:
        with zipfile.ZipFile(stage / (name + ".zip"), "w") as package:
            package.writestr(member, b"unsafe")
    with zipfile.ZipFile(stage / "symlink.zip", "w") as package:
        link = zipfile.ZipInfo("WristBeam.app/Contents/Resources/link")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        package.writestr(link, "../../../../escaped")
    for name in ["tampered", "identity", "minimum"]:
        folder = stage / name
        app = folder / "WristBeam.app"
        shutil.copytree(target, app)
        if name == "tampered":
            (app / "Contents/Resources/Localization/en.json").write_text("{}")
        else:
            info = app / "Contents/Info.plist"
            values = plistlib.loads(info.read_bytes())
            values["CFBundleIdentifier" if name == "identity" else "LSMinimumSystemVersion"] = "example.untrusted" if name == "identity" else "99.0"
            info.write_bytes(plistlib.dumps(values))
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(stage / (name + ".zip"))], check=True)
    legacy_app = stage / "legacy" / "Garmin Pulse.app"
    shutil.copytree(target, legacy_app)
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(legacy_app), str(stage / "legacy.zip")], check=True)
    with zipfile.ZipFile(archive) as original, zipfile.ZipFile(stage / "mixed-roots.zip", "w") as mixed:
        for item in original.infolist():
            mixed.writestr(item, original.read(item.filename))
        mixed.writestr("Garmin Pulse.app/Contents/unexpected", b"ambiguous")
    runner = stage / "Runner.swift"
    runner.write_text('''import Foundation
import AppKit
@main struct UpdateChecks {
 @MainActor static func main() async throws {
  let paths=CommandLine.arguments
  let root=URL(fileURLWithPath:paths[1]), archive=URL(fileURLWithPath:paths[2]), target=root.appendingPathComponent("Installed.app")
  let info=Bundle(url:target)!, version=info.object(forInfoDictionaryKey:"CFBundleShortVersionString") as! String
  #if arch(arm64)
  let architecture="arm64", wrong="x86_64"
  #else
  let architecture="x86_64", wrong="arm64"
  #endif
  let directory=root.appendingPathComponent("valid");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
  let prepared=try PulseUpdatePreparation.prepare(archive:archive,directory:directory,target:target,version:version,architecture:architecture)
  guard FileManager.default.fileExists(atPath:prepared.appendingPathComponent("Contents/MacOS/GarminPulse").path) else {fatalError("No validated stage")}
  print("PASS signed package extraction, version, architecture and staged copy")
  let legacyDirectory=root.appendingPathComponent("legacy-accepted")
  try FileManager.default.createDirectory(at:legacyDirectory,withIntermediateDirectories:true)
  _ = try PulseUpdatePreparation.prepare(archive:root.appendingPathComponent("legacy.zip"),directory:legacyDirectory,target:target,version:version,architecture:architecture)
  print("PASS legacy application archive retains verified identity")
  for name in ["mixed-roots","traversal","absolute","symlink","tampered","identity","minimum","version","architecture"] {
   let dir=root.appendingPathComponent("reject-"+name);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
   let input=["version","architecture"].contains(name) ? archive : root.appendingPathComponent(name+".zip")
   var rejected=false
   do {_ = try PulseUpdatePreparation.prepare(archive:input,directory:dir,target:target,version:name=="version" ? "99.0.0" : version,architecture:name=="architecture" ? wrong : architecture)} catch {rejected=true}
   guard rejected else {fatalError("Unsafe package accepted: "+name)}
   if ["traversal","absolute","symlink"].contains(name) {guard !FileManager.default.fileExists(atPath:dir.appendingPathComponent("Expanded").path) else {fatalError("Extracted before path/link validation")}}
   print("PASS rejected "+name)
  }
  guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("escaped").path) else {fatalError("Archive escaped extraction root")}
  print("PASS: 11 real-package update checks; nothing installed or launched")
 }
}
''')
    binary = stage / "checks"
    files = [sources / "App/SoftwareUpdater.swift", sources / "Models/SoftwareRelease.swift", sources / "Models/AppStorage.swift", sources / "Models/Localization.swift", sources / "Models/Metrics.swift", runner]
    subprocess.run(["swiftc", "-swift-version", "5", "-o", str(binary), *map(str, files)], check=True)
    subprocess.run([str(binary), str(stage), str(archive)], check=True)
