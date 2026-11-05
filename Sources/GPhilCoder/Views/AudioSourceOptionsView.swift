import SwiftUI

struct AudioSourceOptionsView: View {
    @EnvironmentObject private var model: EncoderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Extract audio from video", isOn: $model.extractAudioFromVideo)
                .toggleStyle(.checkbox)
                .disabled(model.isEncoding)

            if model.isExtractingAudio {
                Text("Add MP4, MOV, or M4V files. Save audio in its original format, or convert it below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
