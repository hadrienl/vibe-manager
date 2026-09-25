import SwiftUI

// Controls titled with a `LocalizedStringResource`, for the SDK CI builds with.
//
// Xcode 16.4 (the macOS 15 SDK) only takes a resource in `Text`; the initialisers below come with
// later SDKs, where they are `@_disfavoredOverload` — so these, which say the same thing through
// `Text`, are the ones chosen everywhere, and the code compiles with both.

extension Button where Label == Text {
  init(_ title: LocalizedStringResource, action: @escaping () -> Void) {
    self.init(action: action) { Text(title) }
  }

  init(
    _ title: LocalizedStringResource, role: ButtonRole?, action: @escaping () -> Void
  ) {
    self.init(role: role, action: action) { Text(title) }
  }
}

extension SwiftUI.Label where Title == Text, Icon == Image {
  init(_ title: LocalizedStringResource, systemImage: String) {
    self.init {
      Text(title)
    } icon: {
      Image(systemName: systemImage)
    }
  }
}

extension Toggle where Label == Text {
  init(_ title: LocalizedStringResource, isOn: Binding<Bool>) {
    self.init(isOn: isOn) { Text(title) }
  }
}

extension Picker where Label == Text {
  init(
    _ title: LocalizedStringResource, selection: Binding<SelectionValue>,
    @ViewBuilder content: () -> Content
  ) {
    self.init(selection: selection, content: content) { Text(title) }
  }
}

extension Section where Parent == Text, Footer == EmptyView, Content: View {
  init(_ title: LocalizedStringResource, @ViewBuilder content: () -> Content) {
    self.init(content: content) { Text(title) }
  }
}
