#if DEBUG
import SwiftUI

/// Stands in for the camera under `-StagedCamera`. A flat grey, so a screenshot can't pass for a real
/// scene, and the marks are judged against something plain.
struct StagedBackdrop: View {
    var body: some View {
        Color(hex: 0x3A3A3C)
    }
}
#endif
