import SwiftUI
import UIKit

/// "Where am I? (photo)": one photo, matched against the survey's spots, then a guide from there.
/// Anything short of a match falls back to the entrance route, so the demo always has a way on.
struct PhotoLocateRows: View {
    static let title = "Where am I? (photo)"
    static let hint = "Takes one photo and asks Gemini which surveyed spot it's closest to. Enabled once you confirm the building."
    static let locating = "Matching your photo to the building survey…"
    static let checking = "On-device match. Checking with Gemini…"
    static let agreed = "On-device match, checked by Gemini"
    static let updated = "Updated by Gemini"
    static let unchecked = "On-device match"
    static let guideFromHere = "Guide me from here (AR)"
    static let guideFromEntrance = "Guide me from the entrance (AR)"

    let coordinator: AppCoordinator
    let building: BuildingBrief
    let confirmed: Bool
    let locate: PhotoLocate
    @Binding var guiding: AEDGuideTarget?
    @State private var takingPhoto = false

    private var aed: BuildingBrief.AED? { BuildingWording.guideTarget(building) }

    /// No camera prompt here: that is onboarding's alone, so without access the button stays away.
    static var cameraReady: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera) && Permissions.cameraGranted
    }

    var body: some View {
        if locate.available(for: building), let aed {
            Button(Self.title) { takingPhoto = true }
                .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.awake))
                .disabled(!confirmed || !Self.cameraReady || locate.state == .locating)
                .accessibilityHint(Self.hint)
                // The on-device index takes a few seconds to build, so it starts before the photo does.
                .task { await locate.warm() }
                .fullScreenCover(isPresented: $takingPhoto) {
                    CameraPicker { image in
                        takingPhoto = false
                        guard let image else { return }
                        // Every AED the file carries, scanned or staged; the shortest walk from the photo wins.
                        let ids = building.aeds.filter { BuildingWording.aed($0) != nil }.map(\.id)
                        Task { await locate.locate(image, aedIDs: ids) }
                    }
                    .ignoresSafeArea()
                }
            result(aed)
        }
    }

    static func caption(_ check: PhotoLocate.Check) -> String {
        switch check {
        case .checking: checking
        case .agreed: agreed
        case .updated: updated
        case .unchecked: unchecked
        }
    }

    @ViewBuilder private func result(_ aed: BuildingBrief.AED) -> some View {
        switch locate.state {
        case .idle:
            EmptyView()
        case .locating:
            HStack(spacing: DS.Space.s) {
                ProgressView()
                Text(Self.locating).dsFont(DS.Fonts.label)
            }
            .foregroundStyle(DS.Colors.textSecondary)
        case let .done(.found(pano, aedID, route)):
            HStack(alignment: .center, spacing: DS.Space.m) {
                if let url = LocatorData.tileURL(pano.tile), let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.row / 2, style: .continuous))
                        .accessibilityLabel("Survey view of the matched spot")
                }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(PhotoLocateOutcome.youAreHere(pano))
                        .dsFont(DS.Fonts.prompt)
                        .fixedSize(horizontal: false, vertical: true)
                    if let check = locate.check {
                        HStack(spacing: DS.Space.xs) {
                            if check == .checking { ProgressView().controlSize(.mini) }
                            Text(Self.caption(check))
                        }
                        .dsFont(DS.Fonts.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
            }
            // The person's own flight first: it is what the photo was for.
            DroneFromHereButton(building: building, aedID: aedID, pano: pano.id, locator: locate.locator)
                .id(pano.id)
            Button(Self.guideFromHere) {
                let target = building.aeds.first { $0.id == aedID } ?? aed
                guiding = AEDGuideTarget(building: building, aed: target, route: route, fromPhoto: true, startPano: pano.id)
            }
            .buttonStyle(CommandButtonStyle(kind: .primary, height: DS.Height.awake))
            .disabled(!confirmed)
        case let .done(.fallback(message)):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .dsFont(DS.Fonts.label)
                .foregroundStyle(DS.Colors.caution)
            if let entrance = AEDGuideTarget(building: building) {
                Button(Self.guideFromEntrance) { guiding = entrance }
                    .buttonStyle(CommandButtonStyle(kind: .primary, height: DS.Height.awake))
                    .disabled(!confirmed)
                DronePreviewButton(building: building, aedID: entrance.aed.id, lengthM: entrance.route.lengthM)
            }
        }
    }
}

/// The system camera for one still. Nil when cancelled.
private struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void

        init(done: @escaping (UIImage?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            done(nil)
        }
    }
}
