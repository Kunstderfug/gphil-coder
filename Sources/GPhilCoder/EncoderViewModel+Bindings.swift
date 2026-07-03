import SwiftUI

@MainActor
extension EncoderViewModel {
    func binding<Value>(
        _ keyPath: ReferenceWritableKeyPath<EncoderViewModel, Value>
    ) -> Binding<Value> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { self[keyPath: keyPath] = $0 }
        )
    }
}
