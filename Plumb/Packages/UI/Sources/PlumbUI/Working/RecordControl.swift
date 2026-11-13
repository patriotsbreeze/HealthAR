import SwiftUI

/// The one control that starts and stops recording what the sensors measured, so a session can be
/// replayed on a Mac. Shown on the show-working screen only.
struct RecordControl: View {
    /// True while measurements are going to a file.
    let isRecording: Bool
    /// Called with the state asked for: true to start recording, false to stop.
    let onChange: (Bool) -> Void

    var body: some View {
        // Quiet while idle, so it does not compete with the way back; plain mark while on, so it is not forgotten.
        PlainControl(title: Self.title(isRecording: isRecording), tone: isRecording ? .mark : .quiet, action: press)
    }

    /// Asks for the other state.
    func press() {
        onChange(!isRecording)
    }

    /// What the control says: what pressing it will do.
    static func title(isRecording: Bool) -> String {
        isRecording ? "Stop recording" : "Record measurements"
    }
}
