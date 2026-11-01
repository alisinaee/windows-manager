import SwiftUI
import WMCore

/// View / Edit switch: a glass capsule whose knob slides between the two segments.
/// Accessibility sees a plain segmented picker.
struct StudioModePicker: View {
    @ObservedObject var model: ProfileStudioModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let modes: [(mode: ProfileStudioMode, title: String)] = [(.view, "View"), (.edit, "Edit")]

    private var selection: Binding<ProfileStudioMode> {
        Binding(get: { model.mode },
                set: { newMode in model.requestMode(newMode) })
    }

    var body: some View {
        let segment: CGFloat = 58
        ZStack(alignment: .leading) {
            Capsule().fill(Palette.accentStrong)
                .frame(width: segment, height: 22)
                .offset(x: model.mode == .edit ? segment : 0)
                .animation(reduceMotion ? nil : Motion.spring, value: model.mode)
            HStack(spacing: 0) {
                ForEach(Self.modes, id: \.mode) { item in
                    let selected = model.mode == item.mode
                    Button { selection.wrappedValue = item.mode } label: {
                        Text(item.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                            .frame(width: segment, height: 22)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(2)
        .frame(width: segment * 2 + 4)
        .glassEffect(.regular, in: Capsule())
        .accessibilityRepresentation {
            Picker("Mode", selection: selection) {
                Text("View").tag(ProfileStudioMode.view)
                Text("Edit").tag(ProfileStudioMode.edit)
            }
            .pickerStyle(.segmented)
        }
        .accessibilityLabel("Mode")
        .help("Switch between viewing and editing the profile")
    }
}
