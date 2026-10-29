import SwiftUI

import VampireIndex

/// The HUD strip: glanceable chips for every signal the indexer extracted.
/// Pure information, no judgment calls — warnings appear only when their
/// condition is met so the strip stays skimmable. Empty until the asset is
/// indexed (never blocks browsing).
///
/// Press-and-hold the score chip for the rating explainer.
struct SignalStripView: View {
    let record: AssetIndexRecord?
    @State private var showsExplainer = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let record {
                    chips(for: record)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
        }
        .frame(height: 30)
    }

    @ViewBuilder
    private func chips(for record: AssetIndexRecord) -> some View {
        // Aesthetic score, always shown once computed: the skim anchor.
        // Hold it down for the explainer.
        if let score = record.aestheticScore100 {
            chip(
                icon: "star.fill",
                text: "\(score)",
                color: score >= 70 ? .yellow : score >= 45 ? .white : .gray
            )
            .onLongPressGesture(minimumDuration: 0.35) {
                showsExplainer = true
            }
            .popover(isPresented: $showsExplainer) {
                RatingExplainerView(record: record)
                    .presentationCompactAdaptation(.popover)
            }
        }
        if record.isUtility == true {
            chip(icon: "doc.text.fill", text: "utility", color: .gray)
        }
        // Faces: blink warning when someone's mid-blink.
        if let closed = record.closedEyesCount, closed > 0 {
            chip(icon: "eye.slash.fill", text: "\(closed) closed", color: .red)
        }
        // Exposure: warnings only, with the magnitude.
        if let clipped = record.clippedHighlights, clipped > 0.03 {
            chip(icon: "sun.max.fill", text: "\(Int(clipped * 100))% blown", color: .yellow)
        }
        if let crushed = record.crushedShadows, crushed > 0.12 {
            chip(icon: "moon.fill", text: "\(Int(crushed * 100))% crushed", color: .indigo)
        }
        // Tilt has no chip: the artificial horizon is drawn over the photo
        // itself (ZoomablePhotoView); the degrees live in the explainer.
    }

    private func chip(icon: String, text: String, color: Color) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon)
        }
        .font(.caption2.bold())
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(chipBackground)
    }

    /// Opaque-dark with a hairline: stays readable over clouds and snow when
    /// the strip floats above the photo in landscape.
    private var chipBackground: some View {
        Capsule()
            .fill(.black.opacity(0.6))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }
}

/// What's behind the star: the model's score plus our measured signals,
/// phrased as working-for / working-against. Information, not a verdict.
struct RatingExplainerView: View {
    let record: AssetIndexRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                Text("\(record.aestheticScore100 ?? 0) / 100")
                    .font(.headline)
            }
            Text("Apple's on-device aesthetics model — composition, lighting, and subject clarity in one score. The signals below are measured separately by Vampire:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(findings, id: \.text) { finding in
                    Label {
                        Text(finding.text)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: finding.positive ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(finding.positive ? .green : .orange)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 280)
    }

    private struct Finding {
        let positive: Bool
        let text: String
    }

    private var findings: [Finding] {
        var result: [Finding] = []

        if record.faceCount > 0 {
            let closed = record.closedEyesCount ?? 0
            if closed > 0 {
                result.append(Finding(
                    positive: false,
                    text: closed == 1 ? "1 face caught mid-blink" : "\(closed) faces caught mid-blink"
                ))
            } else {
                result.append(Finding(positive: true, text: "All \(record.faceCount) face\(record.faceCount == 1 ? "" : "s") have open eyes"))
            }
            if let quality = record.bestFaceQuality {
                result.append(Finding(
                    positive: quality >= 0.5,
                    text: quality >= 0.5
                        ? "Sharp, well-captured face (\(Int(quality * 100))%)"
                        : "Best face is soft or awkward (\(Int(quality * 100))%)"
                ))
            }
        }

        if let clipped = record.clippedHighlights {
            if clipped > 0.03 {
                result.append(Finding(positive: false, text: "\(Int(clipped * 100))% of the frame is blown highlights"))
            } else if let crushed = record.crushedShadows, crushed > 0.12 {
                result.append(Finding(positive: false, text: "\(Int(crushed * 100))% of the frame is crushed shadows"))
            } else {
                result.append(Finding(positive: true, text: "Exposure intact — no clipping"))
            }
        }

        if let tilt = record.horizonDegrees {
            if abs(tilt) >= 2 {
                result.append(Finding(positive: false, text: String(format: "Horizon tilted %.1f°", tilt)))
            } else {
                result.append(Finding(positive: true, text: "Horizon level"))
            }
        }

        if let salient = record.salientRect {
            let fraction = Int(salient.width * salient.height * 100)
            result.append(Finding(
                positive: fraction >= 8,
                text: fraction >= 8
                    ? "Clear subject (fills \(fraction)% of frame)"
                    : "Small subject (fills \(fraction)% of frame)"
            ))
        }

        if record.isUtility == true {
            result.append(Finding(positive: false, text: "Looks like a utility image (screenshot, document)"))
        }

        if result.isEmpty {
            result.append(Finding(positive: true, text: "No issues detected by the measured signals"))
        }
        return result
    }
}
