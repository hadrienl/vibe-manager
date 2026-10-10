import SwiftUI

/// The sound wave that takes the place of the composer's field while the microphone listens
/// (#357): its bars follow the level heard, in the colour of who is speaking.
struct VoiceWave: View {
  /// How loud it is now, between 0 and about 0.3.
  let level: Float
  let color: Color
  /// A wave that moves on its own, the agent speaking or working: no level to follow.
  var isAmbient = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let bars = 56

  var body: some View {
    // Slower when the wave moves by itself: the voice is generated meanwhile, and every frame
    // drawn is taken from it.
    TimelineView(.animation(minimumInterval: isAmbient ? 1 / 15 : 1 / 30, paused: reduceMotion)) {
      context in
      let time = context.date.timeIntervalSinceReferenceDate
      Canvas { canvas, size in
        let spacing = size.width / CGFloat(Self.bars)
        let width = max(2, spacing * 0.45)
        // On a square-root scale: a voice at a normal distance fills most of the field, a whisper
        // still moves it, and nothing goes past it.
        let loudness = isAmbient ? 0.35 : min(1, Double(level).squareRoot() * 3.5)
        for index in 0..<Self.bars {
          let phase = Double(index) * 0.55
          let wobble = (sin(time * 6 + phase) + sin(time * 3.7 + phase * 1.7)) / 4 + 0.5
          let height = max(3, size.height * (0.12 + 0.88 * loudness * wobble))
          let rect = CGRect(
            x: CGFloat(index) * spacing + (spacing - width) / 2, y: (size.height - height) / 2,
            width: width, height: height)
          canvas.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(color))
        }
      }
    }
    .accessibilityHidden(true)
  }
}
