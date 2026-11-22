import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window's content (docs/PROMPT.md §5): a sidebar with the schema's groups and the
/// presets; each group's controls are generated from the shared schema. Every change applies to
/// the meter at once, so the meter is the preview.
struct SettingsView: View {
  static let presetsID = "presets"

  @Bindable var model: SettingsModel
  @State private var selection: String? = nil

  var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        Section {
          ForEach(model.groups) { group in
            Label(group.label, systemImage: Self.symbol(for: group.key)).tag(group.id)
          }
        }
        Section {
          Label("Presets", systemImage: "square.stack.3d.up").tag(Self.presetsID)
        }
      }
      .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
    } detail: {
      if selection == Self.presetsID {
        PresetsPane(model: model)
      } else if let group = model.groups.first(where: { $0.id == selection }) ?? model.groups.first
      {
        GroupPane(model: model, group: group)
      }
    }
    .tint(Palette.iris)
    .onAppear {
      if selection == nil { selection = model.groups.first?.id }
    }
  }

  static func symbol(for group: String) -> String {
    switch group {
    case "display": "scope"
    case "points": "circle.grid.3x3"
    case "response": "timer"
    case "level": "slider.vertical.3"
    case "color": "paintpalette"
    case "meters": "chart.bar.xaxis"
    case "window": "macwindow"
    case "performance": "gauge.with.dots.needle.67percent"
    default: "gearshape"
    }
  }
}

/// One group's settings as a form, with a button restoring the group's defaults.
private struct GroupPane: View {
  @Bindable var model: SettingsModel
  let group: SettingsGroup

  var body: some View {
    Form {
      Section {
        ForEach(group.keys, id: \.self) { key in
          if let spec = Schema.spec(key) {
            SettingRow(model: model, key: key, spec: spec)
              .disabled(!SettingsModel.applies(key, in: model.store.values))
          }
        }
      }
      Section {
        HStack {
          Spacer()
          Button("Restore Defaults") { model.reset(group) }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(group.label)
  }
}

/// The control for one setting, chosen by its type in the schema.
private struct SettingRow: View {
  @Bindable var model: SettingsModel
  let key: SettingKey
  let spec: SettingSpec
  @State private var importing = false
  @State private var problem: String?

  var body: some View {
    switch spec.type {
    case .bool:
      Toggle(spec.label, isOn: flag)
    case .int, .float:
      number
    case .choice:
      if spec.choices.count <= 3 {
        choicePicker.pickerStyle(.segmented)
      } else {
        choicePicker.pickerStyle(.menu)
      }
    case .color:
      ColorPicker(spec.label, selection: color, supportsOpacity: false)
    case .text:
      colormap
    }
  }

  private var values: SettingValues { model.store.values }

  private var choicePicker: some View {
    Picker(spec.label, selection: choice) {
      ForEach(spec.choices, id: \.key) { Text($0.label).tag($0.key) }
    }
  }

  private var flag: Binding<Bool> {
    Binding(
      get: { values.flag(key) },
      set: { on in model.store.update { $0.set(key, to: on ? 1 : 0) } })
  }

  private var choice: Binding<String> {
    Binding(
      get: { values.choice(key) },
      set: { picked in model.store.update { $0.set(key, choice: picked) } })
  }

  private var position: Binding<Double> {
    Binding(
      get: { SettingsModel.position(of: values.number(key), in: spec) },
      set: { p in model.store.update { $0.set(key, to: SettingsModel.value(at: p, in: spec)) } })
  }

  private var number: some View {
    VStack(alignment: .leading, spacing: 6) {
      LabeledContent(spec.label) {
        HStack(spacing: 10) {
          Slider(value: position, in: 0...1) { Text(spec.label) }
            .labelsHidden()
            .frame(minWidth: 160)
            .accessibilityValue(SettingsModel.format(values.number(key), for: spec))
          Text(SettingsModel.format(values.number(key), for: spec))
            .font(.callout.monospacedDigit())
            .frame(width: 70, alignment: .trailing)
            .accessibilityHidden(true)
        }
      }
      if !spec.stops.isEmpty {
        HStack(spacing: 6) {
          Spacer()
          ForEach(spec.stops, id: \.label) { stop in
            let isCurrent = values.number(key) == stop.value
            Button(stop.label) { model.store.update { $0.set(key, to: stop.value) } }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .tint(isCurrent ? Palette.iris : nil)
              .accessibilityLabel("\(spec.label): \(stop.label)")
              .accessibilityAddTraits(isCurrent ? .isSelected : [])
          }
        }
      }
    }
  }

  private var color: Binding<Color> {
    Binding(
      get: {
        let rgba = values.color(key)
        return Color(
          .sRGB, red: Double((rgba >> 24) & 0xFF) / 255, green: Double((rgba >> 16) & 0xFF) / 255,
          blue: Double((rgba >> 8) & 0xFF) / 255)
      },
      set: { picked in
        guard let srgb = NSColor(picked).usingColorSpace(.sRGB) else { return }
        let byte = { (c: CGFloat) in UInt32((min(max(c, 0), 1) * 255).rounded()) }
        let alpha = values.color(key) & 0xFF  // the opacity is a setting of its own
        let rgba =
          byte(srgb.redComponent) << 24 | byte(srgb.greenComponent) << 16
          | byte(srgb.blueComponent) << 8 | alpha
        model.store.update { $0.set(key, to: Double(rgba)) }
      })
  }

  private var colormap: some View {
    LabeledContent(spec.label) {
      HStack {
        Picker(spec.label, selection: colormapKey) {
          ForEach(model.colormaps, id: \.key) { Text($0.label).tag($0.key) }
        }
        .labelsHidden()
        .fixedSize()
        Button("Import .map…") { importing = true }
          .controlSize(.small)
      }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [Self.mapType]) { result in
      switch result {
      case .success(let url): Task { await importMap(url) }
      case .failure(let error): problem = error.localizedDescription
      }
    }
    .alert(
      "The colormap was not imported", isPresented: Binding(
        get: { problem != nil }, set: { if !$0 { problem = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(problem ?? "")
    }
  }

  private var colormapKey: Binding<String> {
    Binding(
      get: { values.text(key) },
      set: { picked in model.store.update { $0.set(key, text: picked) } })
  }

  static let mapType = UTType(filenameExtension: "map") ?? .data

  private func importMap(_ url: URL) async {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    do {
      let imported = try await model.importColormap(from: url)
      model.store.update { $0.set(key, text: imported.key) }
    } catch {
      switch error {
      case .unreadable: problem = "The file could not be read."
      case .notAColormap: problem = "The file holds no colormap stops."
      case .notWritten(let error):
        problem = "The colormap folder could not be written: \(error.reason)."
      }
    }
  }
}

/// The factory and user presets: apply, save the current look, import, export, delete.
private struct PresetsPane: View {
  @Bindable var model: SettingsModel
  @State private var naming = false
  @State private var name = ""
  @State private var importing = false
  @State private var problem: String?
  @State private var deleting: Preset?

  var body: some View {
    Form {
      Section("Factory") {
        ForEach(Presets.factory, id: \.name) { preset in row(preset, user: false) }
      }
      Section("Yours") {
        if model.userPresets.isEmpty {
          Text("Save the current look, or import a preset file.").foregroundStyle(.secondary)
        }
        ForEach(model.userPresets, id: \.name) { preset in row(preset, user: true) }
      }
      Section {
        HStack {
          Button("Import…") { importing = true }
          Spacer()
          Button("Save Current Look…") {
            name = ""
            naming = true
          }
          .buttonStyle(.borderedProminent)
        }
      } footer: {
        Text("Presets keep the look, not the window behavior. The plugin reads the same files.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Presets")
    .onAppear { model.reload() }
    .alert("Save Current Look", isPresented: $naming) {
      TextField("Name", text: $name)
      Button("Save") { Task { await save() } }
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("A preset of this name is replaced.")
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
      switch result {
      case .success(let url): Task { await importPreset(url) }
      case .failure(let error): problem = error.localizedDescription
      }
    }
    .confirmationDialog(
      "Delete “\(deleting?.name ?? "")”?", isPresented: Binding(
        get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      presenting: deleting
    ) { preset in
      Button("Delete", role: .destructive) { Task { await delete(preset) } }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("The preset file is removed for the app and the plugin.")
    }
    .alert(
      "Something went wrong", isPresented: Binding(
        get: { problem != nil }, set: { if !$0 { problem = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(problem ?? "")
    }
  }

  private func row(_ preset: Preset, user: Bool) -> some View {
    HStack {
      Text(preset.name)
      if model.store.matches(preset) {
        Image(systemName: "checkmark").foregroundStyle(Palette.iris)
          .accessibilityLabel("Current look")
      }
      Spacer()
      Button("Apply") { model.apply(preset) }.controlSize(.small)
        .accessibilityLabel("Apply \(preset.name)")
      Menu {
        Button("Export…") { Task { await export(preset) } }
        if user {
          Button("Delete…", role: .destructive) { deleting = preset }
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel("More for \(preset.name)")
    }
  }

  private func save() async {
    do {
      try await model.saveCurrent(as: name.trimmingCharacters(in: .whitespaces))
    } catch {
      problem = error.description
    }
  }

  private func importPreset(_ url: URL) async {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    do {
      _ = try await model.importPreset(from: url)
    } catch {
      problem = error.description
    }
  }

  /// Asks where to write the preset's file, then writes it.
  private func export(_ preset: Preset) async {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = Presets.fileName(for: preset.name)
    guard await panel.begin() == .OK, let url = panel.url else { return }
    do {
      try await model.export(preset, to: url)
    } catch {
      problem = error.description
    }
  }

  private func delete(_ preset: Preset) async {
    do {
      try await model.delete(preset)
    } catch {
      problem = error.description
    }
  }
}
