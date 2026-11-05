import SwiftUI

/// Canvas-based voice waveform renderer. Bars are drawn from
/// TDLib-decoded 5-bit peaks (0..31); when peaks are nil we animate
/// a synthetic sine placeholder via TimelineView so the bubble does
/// not feel dead while the audio file downloads. It is self-written to keep deps lean.
struct WaveformView: View {
    let peaks: [UInt8]?
    /// 0..1, played fraction. Pass 0 when this voice is not the
    /// active one to render the full unplayed waveform.
    let progress: Double
    let barColor: Color
    let playedColor: Color
    /// Whether the placeholder drawn without peaks moves. A row that is not
    /// playing holds still: twelve redraws a second for each audio file in a
    /// chat cost the battery and say nothing.
    var animatesPlaceholder = true

    var body: some View {
        if let peaks, !peaks.isEmpty {
            Canvas { context, size in
                Self.drawBars(in: context, size: size,
                              peaks: peaks, progress: progress,
                              barColor: barColor, playedColor: playedColor)
            }
        } else if !animatesPlaceholder {
            Canvas { context, size in
                Self.drawBars(in: context, size: size,
                              peaks: Self.synthetic(phase: 0, count: 60),
                              progress: 0,
                              barColor: barColor, playedColor: playedColor)
            }
        } else {
            TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { ctx in
                Canvas { context, size in
                    let phase = ctx.date.timeIntervalSinceReferenceDate
                    Self.drawBars(in: context, size: size,
                                  peaks: Self.synthetic(phase: phase, count: 60),
                                  progress: 0,
                                  barColor: barColor, playedColor: playedColor)
                }
            }
        }
    }

    private static func drawBars(in context: GraphicsContext,
                                 size: CGSize,
                                 peaks: [UInt8],
                                 progress: Double,
                                 barColor: Color,
                                 playedColor: Color) {
        guard !peaks.isEmpty, size.width > 0, size.height > 0 else { return }
        let count = CGFloat(peaks.count)
        let slot = size.width / count
        let gap: CGFloat = min(1, slot * 0.4)
        let barWidth = max(1, slot - gap)
        let maxHeight = size.height
        for (i, peak) in peaks.enumerated() {
            let normalized = CGFloat(peak) / 31.0
            let h = max(2, normalized * maxHeight)
            let x = CGFloat(i) * slot
            let y = (maxHeight - h) / 2
            let rect = CGRect(x: x, y: y, width: barWidth, height: h)
            let played = (Double(i) + 0.5) / Double(peaks.count) <= progress
            let radius = barWidth / 2
            context.fill(Path(roundedRect: rect, cornerRadius: radius),
                         with: .color(played ? playedColor : barColor))
        }
    }

    private static func synthetic(phase: Double, count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let t = Double(i) / Double(count)
            let value = sin(t * .pi * 4 + phase * 2) * 0.5 + 0.5
            let scaled = pow(value, 0.7) * 0.7 + 0.15
            out.append(UInt8(scaled * 31))
        }
        return out
    }
}
