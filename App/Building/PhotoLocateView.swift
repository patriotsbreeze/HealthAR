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
    static let picked = "Chosen by you"
    static let isThisYou = "Is this where you are? Tap the right view."
    static let allSpots = "All spots"
    static let fewerSpots = "Fewer spots"
    static let guideFromHere = "Guide me from here (AR)"
    static let guideFromEntrance = "Guide me from the entrance (AR)"
    // The AED button's mode, where fewer words do.
    static let shortLocating = "Matching your photo…"
    static let shortIsThisYou = "Not right? Tap your spot."

    let coordinator: AppCoordinator
    let building: BuildingBrief
    let confirmed: Bool
    let locate: PhotoLocate
    @Binding var guiding: AEDGuideTarget?
    /// Opened from the AED button: shorter lines, and the fallback says only that it's using the entrance.
    var aedMode = false
    @State private var takingPhoto = false

    /// Every AED the file carries, scanned or staged; the shortest walk from the spot wins.
    private var aedIDs: [String] { building.aeds.filter { BuildingWording.aed($0) != nil }.map(\.id) }

    private var aed: BuildingBrief.AED? { BuildingWording.guideTarget(building) }

    /// No camera prompt here: that is onboarding's alone, so without access the button stays away.
    static var cameraReady: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera) && Permissions.cameraGranted
    }

    var body: some View {
        if locate.available(for: building), let aed {
            Button { takingPhoto = true } label: {
                if aedMode { Label(Self.title, systemImage: "camera.fill") } else { Text(Self.title) }
            }
                .buttonStyle(CommandButtonStyle(kind: .secondary, height: aedMode ? DS.Height.arrest : DS.Height.awake))
                .disabled(!confirmed || !Self.cameraReady || locate.state == .locating)
                .accessibilityHint(Self.hint)
                // The on-device index takes a few seconds to build, so it starts before the photo does.
                .task {
                    await locate.warm()
                    #if DEBUG
                    if let pano = StagedLaunch.photoPano, locate.state == .idle,
                       let data = PhotoLocate.droneView(pano: pano, building: building.id), let image = UIImage(data: data) {
                        await locate.locate(image, aedIDs: aedIDs)
                    }
                    #endif
                }
                .fullScreenCover(isPresented: $takingPhoto) {
                    CameraPicker { image in
                        takingPhoto = false
                        guard let image else { return }
                        let ids = aedIDs
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
        case .picked: picked
        }
    }

    @ViewBuilder private func result(_ aed: BuildingBrief.AED) -> some View {
        switch locate.state {
        case .idle:
            EmptyView()
        case .locating:
            HStack(spacing: DS.Space.s) {
                ProgressView()
                Text(aedMode ? Self.shortLocating : Self.locating).dsFont(DS.Fonts.label)
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
            SpotChooser(
                building: building,
                locate: locate,
                caption: aedMode ? Self.shortIsThisYou : Self.isThisYou,
                allTitle: locate.showsAllSpots ? Self.fewerSpots : Self.allSpots,
                choose: { locate.choose($0, aedIDs: aedIDs) },
                browse: { withAnimation(DS.Motion.alert) { locate.showsAllSpots.toggle() } }
            )
            // Inline rather than a sheet: this already sits in one, and a sheet on a sheet dropped taps.
            if locate.showsAllSpots {
                AllSpotsGrid(building: building, locate: locate) { index in
                    withAnimation(DS.Motion.alert) { locate.choose(index, aedIDs: aedIDs) }
                }
            }
            // The person's own flight first: it is what the photo was for.
            DroneFromHereButton(building: building, aedID: aedID, pano: pano.id, locator: locate.locator,
                                title: aedMode ? DroneFromHereButton.shortTitle : DroneFromHereButton.title)
                .id(pano.id)
            Button(Self.guideFromHere) {
                let target = building.aeds.first { $0.id == aedID } ?? aed
                guiding = AEDGuideTarget(building: building, aed: target, route: route, fromPhoto: true, startPano: pano.id)
            }
            .buttonStyle(CommandButtonStyle(kind: .primary, height: DS.Height.awake))
            .disabled(!confirmed)
        case let .done(.fallback(message)):
            Label(aedMode ? PhotoLocateOutcome.shortFallback : message, systemImage: "exclamationmark.triangle.fill")
                .dsFont(DS.Fonts.label)
                .foregroundStyle(DS.Colors.caution)
            // The AED button's mode already shows the entrance guide and flight above.
            if !aedMode, let entrance = AEDGuideTarget(building: building) {
                Button(Self.guideFromEntrance) { guiding = entrance }
                    .buttonStyle(CommandButtonStyle(kind: .primary, height: DS.Height.awake))
                    .disabled(!confirmed)
                DronePreviewButton(building: building, aedID: entrance.aed.id, lengthM: entrance.route.lengthM)
            }
        }
    }
}

/// "Is this where you are?": the best few matches as views from each spot, the one in use ringed.
/// Matching confuses look-alike hallways, so a tap here is what makes it work from anywhere.
private struct SpotChooser: View {
    let building: BuildingBrief
    let locate: PhotoLocate
    let caption: String
    let allTitle: String
    let choose: (Int) -> Void
    let browse: () -> Void

    var body: some View {
        if let locator = locate.locator, !locate.candidates.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(caption)
                    .dsFont(DS.Fonts.label)
                    .foregroundStyle(DS.Colors.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.s) {
                        ForEach(locate.candidates, id: \.self) { index in
                            SpotCard(pano: locator.panos[index], building: building, selected: locate.currentIndex == index) {
                                choose(index)
                            }
                        }
                        Button(action: browse) {
                            VStack(spacing: DS.Space.xs) {
                                Image(systemName: "square.grid.2x2")
                                    .font(.system(size: 22, weight: .semibold))
                                Text(allTitle).dsFont(DS.Fonts.caption)
                            }
                            .foregroundStyle(DS.Colors.textPrimary)
                            .frame(width: SpotCard.width, height: SpotCard.height)
                            .overlay(RoundedRectangle(cornerRadius: SpotCard.radius, style: .continuous).strokeBorder(DS.Glass.edge, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show all spots")
                    }
                }
            }
        }
    }
}

/// One spot: its view, and its room and floor under it.
private struct SpotCard: View {
    static let width: CGFloat = 112
    static let height: CGFloat = 76
    static let radius: CGFloat = 10

    let pano: LocatorData.Pano
    let building: BuildingBrief
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let url = PhotoLocate.previewURL(pano, building: building.id), let image = UIImage(contentsOfFile: url.path) {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            DS.Colors.surfaceRaised
                        }
                    }
                    .frame(width: Self.width, height: Self.height)
                    // A filled image spills past its frame, and would take taps meant for the next card.
                    .clipped()
                    .contentShape(Rectangle())
                    .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                            .strokeBorder(selected ? DS.Colors.ok : DS.Glass.edge, lineWidth: selected ? 3 : 1)
                    )
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(DS.Colors.ok)
                            .background(Circle().fill(DS.Colors.surface))
                            .padding(4)
                    }
                }
                Text(Self.label(pano))
                    .dsFont(DS.Fonts.caption)
                    .foregroundStyle(selected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .lineLimit(1)
                    .frame(width: Self.width, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Self.label(pano))\(selected ? ", selected" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// "Hallway · Floor 1", or whichever of the two there is.
    static func label(_ pano: LocatorData.Pano) -> String {
        let parts = [BuildingWording.clean(pano.room), BuildingWording.clean(pano.floor)].filter { !$0.isEmpty }
        return parts.isEmpty ? "Spot" : parts.joined(separator: " · ")
    }
}

/// Every surveyed spot that has a way to the AED, in survey order, for when none of the best few is right.
private struct AllSpotsGrid: View {
    let building: BuildingBrief
    let locate: PhotoLocate
    let choose: (Int) -> Void

    private let columns = [GridItem(.adaptive(minimum: SpotCard.width), spacing: DS.Space.s, alignment: .leading)]

    var body: some View {
        if let locator = locate.locator {
            let routed = Set(locator.routes.values.flatMap(\.keys))
            let indices = locator.panos.indices.filter { routed.contains(locator.panos[$0].id) }
            LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.m) {
                ForEach(indices, id: \.self) { index in
                    SpotCard(pano: locator.panos[index], building: building, selected: locate.currentIndex == index) { choose(index) }
                }
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
