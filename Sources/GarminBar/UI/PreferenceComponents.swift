import SwiftUI

/// Native-sized grouped rows, independently implemented for WristBeam settings.
struct PreferenceBlock<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment:.leading,spacing:9) {
            Text(L10n.text(title)).font(PulseTheme.font(size:12,weight:.semibold)).padding(.leading,3)
            VStack(alignment:.leading,spacing:0,content:content)
                .frame(maxWidth:.infinity,alignment:.leading)
                .background(PulseTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius:11))
                .overlay(RoundedRectangle(cornerRadius:11).strokeBorder(.primary.opacity(0.07)).allowsHitTesting(false))
        }
    }
}
struct PreferenceLine<Control: View>: View {
    let title: String
    var note = ""
    @ViewBuilder var control: () -> Control
    var body: some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:20) { label.frame(minWidth:180,maxWidth:.infinity,alignment:.leading); control().frame(maxWidth:250,alignment:.trailing) }
            VStack(alignment:.leading,spacing:12) { label; control() }
        }
        .controlSize(.regular).font(PulseTheme.font(size:12))
        .padding(.horizontal,15).padding(.vertical,13)
        .frame(minHeight:50)
        .overlay(alignment:.bottom) { Rectangle().fill(.primary.opacity(0.06)).frame(height:0.5).padding(.horizontal,15).allowsHitTesting(false) }
    }
    private var label: some View {
        VStack(alignment:.leading,spacing:4) {
            Text(L10n.text(title)).font(PulseTheme.font(size:13))
            if !note.isEmpty { Text(L10n.text(note)).font(PulseTheme.font(size:11)).foregroundStyle(PulseTheme.secondary).fixedSize(horizontal:false,vertical:true) }
        }
    }
}
