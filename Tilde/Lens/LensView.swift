import SwiftUI
import TildeKit

/// The outline around whatever "this" is while the key is held.
struct LensView: View {
    var referent: Referent
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.focus, lineWidth: 2)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.focus.opacity(0.06)))
                .shadow(color: Theme.focus.opacity(0.6), radius: 14)
                .padding(6)
            HStack(spacing: 6) {
                Image(systemName: "scope").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.focus)
                Text(referent.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.ink, in: .capsule)
            .padding(14)
        }
        .scaleEffect(appeared ? 1 : 1.015)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(Theme.quick) { appeared = true } }
    }
}
