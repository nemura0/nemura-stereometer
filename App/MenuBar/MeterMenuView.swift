import AppKit
import NMRCoreC
import SwiftUI

/// The menu-bar popover (docs/PROMPT.md §5): the source, the mode with thumbnails drawn by the
/// meter's renderer, the preset, the background opacity and click-through, and Settings.
struct MeterMenuView: View {
  static let width: CGFloat = 316
  static let padding: CGFloat = 16
  static let columns = 3
  static let columnSpacing: CGFloat = 8
  /// A mode tile's width, in points.
  static let tileSide = Double(
    (width - 2 * padding - CGFloat(columns - 1) * columnSpacing) / CGFloat(columns))
  /// Drawn at least as large as the tile, so it is never scaled up.
  static let thumbnailSide = Int(tileSide.rounded(.up))

  @Bindable var model: MeterMenuModel
  let thumbnails: ModeThumbnails
  let scale: Double
  let showSettings: (() -> Void)?
  let quit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      section("Source") { source }
      section("Mode") { modes }
      section("Preset") { presets }
      section("Background") { opacity }
      clickThrough
      Divider()
      footer
    }
    .padding(Self.padding)
    .frame(width: Self.width)
    .tint(Palette.iris)
    .environment(\.colorScheme, .dark)
    .onAppear(perform: refreshThumbnails)
    .onChange(of: model.store.values) { refreshThumbnails() }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(String(cString: nmr_product_name())).font(.headline)
      Spacer()
      Text(String(cString: nmr_version())).font(.caption).foregroundStyle(.tertiary)
    }
  }

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      content()
    }
  }

  private var source: some View {
    HStack(spacing: 8) {
      Circle().fill(statusColor).frame(width: 7, height: 7)
      Text("System Output")
      Spacer()
      Text(model.sourceStatus).font(.caption).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  private var statusColor: Color {
    switch model.capture.phase {
    case .starting: .gray
    case .failed: .orange
    case .capturing: model.capture.signal == .silenceWhilePlaying ? .orange : .green
    }
  }

  private var modes: some View {
    LazyVGrid(
      columns: Array(
        repeating: GridItem(.flexible(), spacing: Self.columnSpacing, alignment: .top),
        count: Self.columns),
      spacing: 10
    )
    {
      ForEach(MeterMode.allCases, id: \.self) { mode in
        ModeTile(
          image: thumbnails.images[mode], label: model.modeLabel(mode),
          selected: model.mode == mode
        ) { model.mode = mode }
      }
    }
  }

  private var presets: some View {
    Menu {
      ForEach(model.presets, id: \.name) { preset in
        Button(preset.name) { model.choosePreset(preset) }
      }
      if !model.userPresets.isEmpty {
        Divider()
        ForEach(model.userPresets, id: \.name) { preset in
          Button(preset.name) { model.choosePreset(preset) }
        }
      }
    } label: {
      Text(model.presetTitle)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityLabel("Preset")
    .accessibilityValue(model.presetTitle)
  }

  private var opacity: some View {
    HStack(spacing: 10) {
      Slider(value: $model.opacity, in: 0...100) { Text("Background opacity") }
        .labelsHidden()
        .accessibilityValue("\(Int(model.opacity.rounded())) %")
      Text("\(Int(model.opacity.rounded())) %")
        .font(.callout.monospacedDigit())
        .frame(width: 44, alignment: .trailing)
        .accessibilityHidden(true)
    }
  }

  private var clickThrough: some View {
    Toggle(isOn: $model.clickThrough) {
      HStack {
        Text("Click-through")
        Spacer()
        Text(model.clickThroughShortcut ?? "").font(.caption).foregroundStyle(.tertiary)
      }
    }
    .toggleStyle(.switch)
    .controlSize(.small)
    // Without its shortcut nothing could turn it off again from the meter itself.
    .disabled(model.clickThroughShortcut == nil && !model.clickThrough)
  }

  private var footer: some View {
    HStack {
      if let showSettings {
        Button("Settings…", action: showSettings).keyboardShortcut(",", modifiers: .command)
      }
      Spacer()
      Button("Quit", action: quit).keyboardShortcut("q", modifiers: .command)
    }
  }

  private func refreshThumbnails() {
    thumbnails.refresh(for: model.store.values, side: Self.thumbnailSide, scale: scale)
  }
}

/// One mode: its thumbnail over its name; the chosen one is outlined in iris.
private struct ModeTile: View {
  let image: CGImage?
  let label: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 4) {
        ZStack {
          RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.07))
          if let image {
            Image(decorative: image, scale: 1).resizable().interpolation(.high)
              .aspectRatio(1, contentMode: .fit)
          }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(
          RoundedRectangle(cornerRadius: 7)
            .strokeBorder(
              selected ? Palette.iris : Color.white.opacity(0.08),
              lineWidth: selected ? 2 : 1))
        Text(label).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
          .foregroundStyle(selected ? .primary : .secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}
