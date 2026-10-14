import AppKit
import SwiftUI

// Compose unchanged native-view captures; no private account or UI automation.
@main struct FloatingShowcaseExport {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let inputs = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let outputs = URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        for chinese in [true,false] {
            let language = chinese ? "zh" : "en"
            let renderer = ImageRenderer(content:FloatingShowcase(inputs:inputs,chinese:chinese).environment(\.colorScheme,.light))
            renderer.scale = 1
            guard let image = renderer.cgImage, let bytes = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else { fatalError("Showcase rendering failed") }
            try bytes.write(to:outputs.appendingPathComponent("showcase-floating\(chinese ? "-zh" : "").png"))
            print("PASS floating showcase \(language): \(image.width)x\(image.height)")
            for scene in ["hero","themes","settings","menu"] {
                let renderer = ImageRenderer(content:WindowShowcase(inputs:inputs,assets:outputs,chinese:chinese,scene:scene).environment(\.colorScheme,.light))
                renderer.scale = 1
                guard let image = renderer.cgImage, let bytes = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else { fatalError("Window showcase failed") }
                try bytes.write(to:outputs.appendingPathComponent("showcase-\(scene)\(chinese ? "-zh" : "").png"))
                print("PASS \(scene) showcase \(language)")
            }

        }
    }
}
struct FloatingShowcase: View {
    let inputs: URL
    let chinese: Bool
    private func caption(_ zh:String,_ en:String) -> String { chinese ? zh : en }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Image(systemName:"waveform.path.ecg").font(.system(size:32)).foregroundStyle(Color(red:0.15,green:0.42,blue:0.34))
                Text(caption("腕映 · WristBeam","WristBeam")).font(.system(size:24,weight:.semibold))
                Spacer()
                Text(caption("浮窗 · 随时可见","Floating panel · always in view")).font(.system(size:14)).foregroundStyle(.secondary)
            }
            Text(caption("一眼读数，展开趋势。","A glance. A fuller picture.")).font(.system(size:43,weight:.semibold)).padding(.top,30)
            Text(caption("轻巧的当前值，或一天的起伏。按你的节奏切换。","Current readings or the rhythm of your day. Choose your view.")).font(.system(size:17)).foregroundStyle(.secondary).padding(.top,10)
            HStack(alignment:.top,spacing:90) {
                panel(detailed:false)
                panel(detailed:true)
            }.frame(maxWidth:.infinity).padding(.top,38)
            Spacer(minLength:12)
            HStack {
                Text(caption("原生界面 · 隔离演示数据","Native views · isolated demo data"))
                Spacer()
                Text(caption("紧凑 / 详细 · 明暗外观 · 字体缩放","Compact / Detailed · themes · adjustable type"))
            }.font(.system(size:12)).foregroundStyle(.secondary)
        }.padding(50).frame(width:1200,height:900)
            .background(LinearGradient(colors:[Color(red:0.92,green:0.96,blue:0.94),Color(red:0.97,green:0.97,blue:0.94),Color(red:0.88,green:0.94,blue:0.92)],startPoint:.topLeading,endPoint:.bottomTrailing))
    }
    private func panel(detailed:Bool) -> some View {
        let filename = "floating-\(chinese ? "zh" : "en")-\(detailed ? "dark" : "light")-\(detailed ? "detailed" : "compact")-100.png"
        return VStack(alignment:.leading,spacing:15) {
            Text(detailed ? caption("详细","Detailed") : caption("紧凑","Compact")).font(.system(size:16,weight:.medium)).foregroundStyle(.secondary)
            Image(nsImage:NSImage(contentsOf:inputs.appendingPathComponent(filename))!).resizable().aspectRatio(contentMode:.fit).frame(width:365)
                .shadow(color:.black.opacity(0.15),radius:25,x:0,y:18)
        }
    }
}

struct WindowShowcase: View {
    let inputs:URL
    let assets:URL
    let chinese:Bool
    let scene:String
    private var language:String { chinese ? "zh" : "en" }
    private var title:String {
        if scene == "menu" { return chinese ? "抬眼看状态，点击看更多。" : "A glance above. More with a click." }
        if scene == "settings" { return chinese ? "顺手的设置，自己的节奏。" : "Your preferences. Your rhythm." }
        if scene == "themes" { return chinese ? "从清晨，看到夜晚。" : "For every part of your day." }
        return chinese ? "腕上健康，桌面可见。" : "Your wrist, in view."
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(chinese ? "腕映 · WristBeam" : "WristBeam").font(.system(size:23,weight:.semibold)).foregroundStyle(Color(red:0.15,green:0.42,blue:0.34))
            Text(title).font(.system(size:43,weight:.semibold))
            Text(scene == "settings" ? (chinese ? "外观、连接、开发者集成与更新，分组管理。" : "Appearance, connections, developer access and updates, grouped together.") : (chinese ? "健康看板 · 菜单栏 · 浮窗" : "Dashboard · menu bar · floating panel")).font(.system(size:17)).foregroundStyle(.secondary)
            Spacer(minLength:15)
            if scene == "menu" {
                VStack(spacing: 24) {
                    Image(nsImage:NSImage(contentsOf:assets.appendingPathComponent("raw-menu-bar.png"))!).resizable().aspectRatio(contentMode:.fit).frame(width:330).padding(12).background(Color(red:0.13,green:0.15,blue:0.16)).clipShape(RoundedRectangle(cornerRadius:12))
                    native("menu-\(language)-dark.png",width:390)
                }.frame(maxWidth:.infinity)
            } else if scene == "settings" {
                native("page-appearance-\(language)-light.png",width:920).frame(maxWidth:.infinity)
            } else if scene == "themes" {
                ZStack {
                    native("page-overview-\(language)-light.png",width:750).rotationEffect(.degrees(-3)).offset(x:-170,y:-65)
                    native("page-overview-\(language)-dark.png",width:750).rotationEffect(.degrees(3)).offset(x:170,y:85)
                }.frame(height:730)
            } else {
                HStack(alignment:.top,spacing:30) {
                    native("page-overview-\(language)-light.png",width:780)
                    VStack(spacing:18) {
                        Image(nsImage:NSImage(contentsOf:assets.appendingPathComponent("raw-menu-bar.png"))!).resizable().aspectRatio(contentMode:.fit).padding(9).background(Color(red:0.13,green:0.15,blue:0.16)).clipShape(RoundedRectangle(cornerRadius:9))
                        Image(nsImage:NSImage(contentsOf:assets.appendingPathComponent(chinese ? "raw-menu-popup-zh.png" : "raw-menu-popup.png"))!).resizable().aspectRatio(contentMode:.fit).clipShape(RoundedRectangle(cornerRadius:15))
                    }.frame(width:280).shadow(color:.black.opacity(0.15),radius:20,x:0,y:16)
                }.frame(maxWidth:.infinity)
            }
            Spacer(minLength:20)
            HStack {
                Text("Apple Silicon + Intel · macOS 13+")
                Spacer()
                Text(chinese ? "原生界面 · 隔离演示数据" : "Native views · isolated demo data")
            }.font(.system(size:12)).foregroundStyle(.secondary)
        }.padding(50).frame(width:1200,height:scene == "hero" ? 900 : 1040)
            .background(LinearGradient(colors:[Color(red:0.92,green:0.96,blue:0.94),Color(red:0.97,green:0.97,blue:0.94),Color(red:0.88,green:0.94,blue:0.92)],startPoint:.topLeading,endPoint:.bottomTrailing))
    }
    private func native(_ filename:String,width:CGFloat) -> some View {
        Image(nsImage:NSImage(contentsOf:inputs.appendingPathComponent(filename))!).resizable().aspectRatio(contentMode:.fit).frame(width:width)
            .clipShape(RoundedRectangle(cornerRadius:14)).overlay(RoundedRectangle(cornerRadius:14).strokeBorder(.white.opacity(0.6)))
            .shadow(color:.black.opacity(0.15),radius:23,x:0,y:18)
    }
}
