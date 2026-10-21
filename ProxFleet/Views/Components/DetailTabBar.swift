import SwiftUI

/// A section of a detail screen, shown in its bottom bar.
nonisolated protocol DetailTab: Hashable, CaseIterable, Identifiable, RawRepresentable where RawValue == String {
    var title: LocalizedStringKey { get }
    var systemImage: String { get }
}

nonisolated extension DetailTab {
    var id: String { rawValue }
}

/// Floating Liquid Glass bar for switching between the sections of a guest or node.
struct DetailTabBar<Tab: DetailTab>: View {
    @Binding var selection: Tab
    @Namespace private var namespace

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 0) {
                ForEach(Array(Tab.allCases)) { tab in
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { selection = tab }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 18, weight: .medium))
                                .frame(height: 22)
                            Text(tab.title)
                                .font(.caption2.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundStyle(selection == tab ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .background {
                            if selection == tab {
                                Capsule()
                                    .fill(.tint.opacity(0.16))
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tab.\(tab.rawValue)")
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }
            .padding(4)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(.horizontal, 20)
    }
}

