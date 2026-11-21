/// The settings the app reads and writes, by their schema keys. The schema itself
/// (Sources/Core/include/nmr/settings.h) is the single source of truth; SchemaTests keeps this
/// list, the types and the choice cases in step with it.
enum SettingKey: String, CaseIterable, Sendable {
  case mode
  case logRangeDb = "log_range_db"
  case orientation
  case drawStyle = "draw_style"
  case guides
  case pointSize = "point_size"
  case pointShape = "point_shape"
  case lineThickness = "line_thickness"
  case density
  case brightness
  case glow
  case trailMs = "trail_ms"
  case integrationMs = "integration_ms"
  case gainDb = "gain_db"
  case autoGain = "auto_gain"
  case colorMode = "color_mode"
  case colormap
  case solidColor = "solid_color"
  case correlationMeter = "correlation_meter"
  case balanceMeter = "balance_meter"
  case meterReadouts = "meter_readouts"
  case backgroundColor = "background_color"
  case backgroundOpacity = "background_opacity"
  case alwaysOnTop = "always_on_top"
  case clickThrough = "click_through"
  case allSpaces = "all_spaces"
  case hoverControls = "hover_controls"
  case dockIcon = "dock_icon"
  case frameRate = "frame_rate"
}

enum SettingType: Equatable, Sendable {
  case bool, int, float, choice, color, text
}

/// Which product uses a setting.
enum SettingScope: Equatable, Sendable {
  case shared, app, plugin
}

enum MeterMode: String, CaseIterable, Sendable {
  case goniometer
  case goniometerLog = "goniometer_log"
  case half
  case halfLog = "half_log"
  case lissajous
  case original
}

enum Orientation: String, CaseIterable, Sendable {
  case midSide = "mid_side"
  case leftRight = "left_right"
}

enum DrawStyle: String, CaseIterable, Sendable {
  case dots, lines
}

enum Guides: String, CaseIterable, Sendable {
  case off, subtle, full
}

enum PointShape: String, CaseIterable, Sendable {
  case soft, circle, square
}

enum AutoGain: String, CaseIterable, Sendable {
  case off, slow, fast
}

enum ColorMode: String, CaseIterable, Sendable {
  case frequency, solid, amplitude
  case midSide = "mid_side"
}

enum FrameRate: String, CaseIterable, Sendable {
  case auto
  case fps120 = "120"
  case fps60 = "60"
  case fps30 = "30"
}

extension SettingKey {
  var type: SettingType {
    switch self {
    case .mode, .orientation, .drawStyle, .guides, .pointShape, .autoGain, .colorMode, .frameRate:
      .choice
    case .logRangeDb, .pointSize, .lineThickness, .brightness, .glow, .trailMs, .integrationMs,
      .gainDb, .backgroundOpacity:
      .float
    case .density:
      .int
    case .solidColor, .backgroundColor:
      .color
    case .colormap:
      .text
    case .correlationMeter, .balanceMeter, .meterReadouts, .alwaysOnTop, .clickThrough, .allSpaces,
      .hoverControls, .dockIcon:
      .bool
    }
  }

  /// The choice keys in schema order; empty for other types.
  var choiceKeys: [String] {
    switch self {
    case .mode: MeterMode.allCases.map(\.rawValue)
    case .orientation: Orientation.allCases.map(\.rawValue)
    case .drawStyle: DrawStyle.allCases.map(\.rawValue)
    case .guides: Guides.allCases.map(\.rawValue)
    case .pointShape: PointShape.allCases.map(\.rawValue)
    case .autoGain: AutoGain.allCases.map(\.rawValue)
    case .colorMode: ColorMode.allCases.map(\.rawValue)
    case .frameRate: FrameRate.allCases.map(\.rawValue)
    default: []
    }
  }
}
