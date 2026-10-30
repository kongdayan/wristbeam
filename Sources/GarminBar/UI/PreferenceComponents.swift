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
        PreferenceRowLayout {
            label
            control().accessibilityLabel(L10n.text(title))
        }
        .controlSize(.regular).font(PulseTheme.font(size:12)).tint(PulseTheme.mint)
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


/// Keep switches aligned when descriptions wrap; stack only when the actual
/// available width cannot hold a readable label and the control.
private struct PreferenceRowLayout: Layout {
    private let gap: CGFloat = 20
    private func geometry(width: CGFloat, subviews: Subviews) -> (control: CGSize, label: CGSize, stacked: Bool) {
        let control = subviews[1].sizeThatFits(ProposedViewSize(width: min(250 * min(1.3, PulseTheme.textScale), width), height: nil))
        let stacked = width - control.width - gap < 180 * min(1.3, PulseTheme.textScale)
        let label = subviews[0].sizeThatFits(ProposedViewSize(width: stacked ? width : width - control.width - gap, height: nil))
        return (control, label, stacked)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 500
        let sizes = geometry(width: width, subviews: subviews)
        return CGSize(width: width, height: sizes.stacked ? sizes.label.height + 12 + sizes.control.height : max(sizes.label.height, sizes.control.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = geometry(width: bounds.width, subviews: subviews)
        let labelWidth = sizes.stacked ? bounds.width : bounds.width - sizes.control.width - gap
        subviews[0].place(at: CGPoint(x: bounds.minX, y: sizes.stacked ? bounds.minY : bounds.midY - sizes.label.height / 2), proposal: ProposedViewSize(width: labelWidth, height: sizes.label.height))
        subviews[1].place(at: CGPoint(x: sizes.stacked ? bounds.minX : bounds.maxX - sizes.control.width, y: sizes.stacked ? bounds.maxY - sizes.control.height : bounds.midY - sizes.control.height / 2), proposal: ProposedViewSize(sizes.control))
    }
}
