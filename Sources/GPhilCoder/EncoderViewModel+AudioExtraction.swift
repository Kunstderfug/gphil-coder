import GPhilCoderCore

extension EncoderViewModel {
    var isExtractingAudio: Bool {
        encodingWorkflow == .audio && extractAudioFromVideo
    }

    var isCopyingOriginalAudio: Bool {
        isExtractingAudio && copyOriginalAudio
    }

    /// Source selection can be video while the output uses the audio encoder.
    var inputWorkflow: EncodingWorkflow {
        isExtractingAudio ? .video : encodingWorkflow
    }
}
