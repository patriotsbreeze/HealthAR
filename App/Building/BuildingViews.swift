import SwiftUI

/// The building section of the mock dispatcher. It says where an AED was seen in a survey scan and
/// which entrance the survey suggests for EMS, and only after the person confirms the building can it
/// be read aloud. It places no call and opens nothing. Hidden when the app carries no usable building.
struct BuildingBriefSection: View {
    let coordinator: AppCoordinator
    var store = BuildingBriefStore.shared
    @State private var guiding: AEDGuideTarget?
    @State private var locate = PhotoLocate()

    var body: some View {
        if store.showsSection {
            let run = coordinator.state.startedAt
            let building = store.selected
            let confirmed = store.isConfirmed(run: run)

            VStack(alignment: .leading, spacing: DS.Space.s) {
                SectionHeader(title: BuildingWording.sectionTitle)
                if let building {
                    if store.isPickedByHand {
                        Text(BuildingWording.nameAndAddress(building)).dsFont(DS.Fonts.prompt)
                        Text(BuildingWording.chosenByHand)
                            .dsFont(DS.Fonts.label)
                            .foregroundStyle(DS.Colors.caution)
                    } else {
                        Text(BuildingWording.match(building)).dsFont(DS.Fonts.prompt)
                    }
                    if confirmed {
                        Label(BuildingWording.confirmedLabel, systemImage: "checkmark.circle.fill")
                            .dsFont(DS.Fonts.label)
                            .foregroundStyle(DS.Colors.ok)
                    } else {
                        Button(BuildingWording.confirmTitle) { store.confirm(run: run) }
                            .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.awake))
                    }
                    // Three taps from here to arrows: this confirm, this guide, and I'm here at the door.
                    if let target = AEDGuideTarget(building: building) {
                        Button(BuildingWording.guideTitle) { guiding = target }
                            .buttonStyle(CommandButtonStyle(kind: .primary, height: DS.Height.awake))
                            .disabled(!confirmed)
                            .accessibilityHint(BuildingWording.guideHint)
                        // Once a photo has placed the person, their own flight replaces the entrance sample.
                        if !locate.hasFound {
                            DronePreviewButton(building: building, aedID: target.aed.id, lengthM: target.route.lengthM)
                        }
                    }
                    PhotoLocateRows(coordinator: coordinator, building: building, confirmed: confirmed, locate: locate, guiding: $guiding)
                } else {
                    Text(BuildingWording.noMatch)
                        .dsFont(DS.Fonts.body)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                BuildingPicker(store: store)
                if let building {
                    ForEach(BuildingWording.aeds(building), id: \.self) { line in
                        Text(line).dsFont(DS.Fonts.body)
                    }
                    if let entrance = BuildingWording.entrance(building) {
                        Text(entrance).dsFont(DS.Fonts.body)
                    }
                    Button(BuildingWording.readAloudTitle) {
                        if let text = BuildingWording.spoken(building, confirmed: store.isConfirmed(run: coordinator.state.startedAt)) {
                            // The app's own voice, with the on-device read-aloud as the fallback.
                            BuildingVoice.shared.speak(text) { coordinator.readAloud(text) }
                        }
                    }
                    .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.awake))
                    .disabled(!confirmed)
                    .accessibilityHint(BuildingWording.readAloudHint)
                }
            }
            .foregroundStyle(DS.Colors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .task { BuildingLocator.shared.refresh() }
            // Rendered once the building is confirmed, so Read building aloud plays at once.
            .task(id: confirmed) {
                if let building, let text = BuildingWording.spoken(building, confirmed: confirmed) {
                    BuildingVoice.shared.prefetch(text)
                }
            }
            .fullScreenCover(item: $guiding) { target in
                AEDGuideView(target: target, coordinator: coordinator)
            }
        }
    }
}

/// Lets a building be tried away from it, in TestFlight too. Labeled as a simulation wherever it shows.
private struct BuildingPicker: View {
    let store: BuildingBriefStore

    var body: some View {
        Menu {
            ForEach(store.buildings) { building in
                Button(BuildingWording.nameAndAddress(building)) { store.pick(building.id) }
            }
            if store.isPickedByHand {
                Divider()
                Button(BuildingWording.matchByLocation) { store.pick(nil) }
            }
            if let marks = store.marks, let id = store.selected?.id, marks.count(for: id) > 0 {
                Divider()
                Button(BuildingWording.clearMarks, role: .destructive) { marks.clear(building: id) }
            }
        } label: {
            Label(BuildingWording.chooseTitle, systemImage: "building.2")
                .dsFont(DS.Fonts.label)
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(2)
                .padding(.horizontal, DS.Space.l)
                .frame(maxWidth: .infinity, minHeight: DS.Height.control)
                .overlay(Capsule(style: .continuous).strokeBorder(DS.Glass.edge, lineWidth: 1))
                .contentShape(Capsule(style: .continuous))
        }
    }
}

/// The handoff card's building rows. They come from a survey, not this rescue's log, and the title says
/// so. Shown only once the person confirmed the building in this rescue.
struct BuildingHandoffRows: View {
    let coordinator: AppCoordinator
    var store = BuildingBriefStore.shared

    var body: some View {
        if let building = store.confirmed(run: coordinator.state.startedAt) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: BuildingWording.handoffTitle)
                    .padding(.top, DS.Space.xl)
                    .padding(.bottom, DS.Space.xs)
                ForEach(Array(Self.rows(building).enumerated()), id: \.offset) { index, row in
                    if index > 0 { Rectangle().fill(DS.Colors.hairline).frame(height: 1) }
                    BuildingRow(row: row)
                }
            }
        }
    }

    struct Row: Equatable {
        var label: String
        var value: String
        var meta: String?
        var tag: String
        /// The entrance is AI-assisted, so it gets a second look, like an AI-inferred fact does.
        var caution = false
    }

    static func rows(_ building: BuildingBrief) -> [Row] {
        var rows = [Row(label: "Building", value: BuildingWording.nameAndAddress(building), tag: "survey")]
        let aeds = building.aeds.filter { BuildingWording.aed($0) != nil }
        if aeds.isEmpty {
            rows.append(Row(label: "AED in scan", value: "None seen", tag: "survey"))
        }
        for aed in aeds {
            let floor = BuildingWording.clean(aed.floor)
            let place = BuildingWording.clean(aed.place)
            let walk = aed.typicalWalkM.map { "about \($0) m walk, " } ?? ""
            rows.append(Row(
                label: aed.isFromScan ? "AED seen in scan" : BuildingWording.label(aed),
                value: floor.isEmpty ? place : "\(place), \(floor)",
                meta: aed.markedByHand ? "\(walk)marked on this phone"
                    : BuildingWording.monthYear(aed.scanDate).map { "\(walk)scan \($0), may have moved" },
                tag: aed.markedByHand ? "marked" : "survey",
                caution: !aed.isFromScan
            ))
        }
        if let entrance = building.emsEntrance, let source = BuildingWording.source(entrance) {
            rows.append(Row(
                label: "Suggested EMS entrance",
                value: BuildingWording.clean(entrance.text),
                meta: "from \(source), not checked on site",
                tag: "AI-assisted",
                caution: true
            ))
        }
        return rows
    }
}

/// The handoff card's row, rebuilt here since that one is private: label left, value right, where it
/// came from under it.
private struct BuildingRow: View {
    let row: BuildingHandoffRows.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            Text(row.label)
                .dsFont(DS.Fonts.body)
                .foregroundStyle(DS.Colors.textSecondary)
            Spacer(minLength: DS.Space.xs)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.value)
                    .dsFont(DS.Fonts.value)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .multilineTextAlignment(.trailing)
                HStack(spacing: 6) {
                    if let meta = row.meta {
                        Text(meta)
                            .dsFont(DS.Fonts.meta)
                            .foregroundStyle(DS.Colors.textTertiary)
                            .multilineTextAlignment(.trailing)
                    }
                    BuildingSourceTag(text: row.tag, caution: row.caution)
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

private struct BuildingSourceTag: View {
    let text: String
    let caution: Bool

    var body: some View {
        Text(text)
            .dsFont(DS.Fonts.badge)
            .foregroundStyle(caution ? DS.Colors.caution : DS.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(caution ? DS.Colors.caution.opacity(0.7) : DS.Colors.hairline, lineWidth: 1))
    }
}
