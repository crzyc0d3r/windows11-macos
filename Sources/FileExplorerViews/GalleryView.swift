import AppKit
import FileExplorerCore
import FileExplorerDesign
import SwiftUI

public struct GalleryView: View {
    public let store: ExplorerStore

    @Environment(\.fluentTheme) private var theme
    @State private var mediaFilter: GalleryFilter = .all
    @State private var thumbnailSize: Double = 132
    @State private var hoveredURL: URL?
    @State private var activeScrubberID: String?
    @State private var isScrubbing = false

    public init(store: ExplorerStore) {
        self.store = store
    }

    private enum GalleryFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case images = "Images"
        case videos = "Videos"

        var id: String { rawValue }
    }

    private struct TimelineSection: Identifiable {
        let id: String
        let monthTitle: String
        let yearString: String
        let shortLabel: String
        let items: [FileItem]
    }

    private var filteredItems: [FileItem] {
        let mediaItems = store.currentItems.filter { item in
            switch mediaFilter {
            case .all:
                return item.kind == .image || item.kind == .video
            case .images:
                return item.kind == .image
            case .videos:
                return item.kind == .video
            }
        }
        return mediaItems.sorted { $0.dateModified > $1.dateModified }
    }

    private var timelineSections: [TimelineSection] {
        let calendar = Calendar.current
        let monthYearFormatter = DateFormatter()
        monthYearFormatter.dateFormat = "MMMM yyyy"

        let shortFormatter = DateFormatter()
        shortFormatter.dateFormat = "MMM yyyy"

        let yearFormatter = DateFormatter()
        yearFormatter.dateFormat = "yyyy"

        var orderedKeys: [String] = []
        var grouped: [String: (monthTitle: String, year: String, shortLabel: String, items: [FileItem])] = [:]

        for item in filteredItems {
            let comps = calendar.dateComponents([.year, .month], from: item.dateModified)
            let key = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            if grouped[key] == nil {
                orderedKeys.append(key)
                grouped[key] = (
                    monthTitle: monthYearFormatter.string(from: item.dateModified),
                    year: yearFormatter.string(from: item.dateModified),
                    shortLabel: shortFormatter.string(from: item.dateModified),
                    items: []
                )
            }
            grouped[key]?.items.append(item)
        }

        return orderedKeys.compactMap { key in
            guard let entry = grouped[key] else { return nil }
            return TimelineSection(
                id: key,
                monthTitle: entry.monthTitle,
                yearString: entry.year,
                shortLabel: entry.shortLabel,
                items: entry.items
            )
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            galleryToolbar

            if timelineSections.isEmpty {
                emptyGalleryState
            } else {
                ScrollViewReader { proxy in
                    HStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 20) {
                                ForEach(timelineSections) { section in
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack(spacing: 8) {
                                            Text(section.monthTitle)
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(theme.palette.textPrimary)
                                            Text("(\(section.items.count))")
                                                .font(.system(size: 12.5))
                                                .foregroundStyle(theme.palette.textSecondary)
                                            Rectangle()
                                                .fill(theme.palette.borderSubtle)
                                                .frame(height: 1)
                                        }
                                        .id(section.id)

                                        LazyVGrid(
                                            columns: [
                                                GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize + 36), spacing: 10)
                                            ],
                                            spacing: 10
                                        ) {
                                            ForEach(section.items) { item in
                                                galleryTile(item)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(18)
                        }
                        .background(theme.palette.contentCanvas)
                        .onTapGesture {
                            store.deselectAll()
                        }
                        .overlay {
                            RightClickHandlerOverlay {
                                store.showContextMenu(for: .background(.gallery))
                            }
                        }

                        timelineScrubber(proxy: proxy)
                    }
                }
            }
        }
        .background(theme.palette.contentCanvas)
    }

    private var galleryToolbar: some View {
        HStack(spacing: 10) {
            ForEach(GalleryFilter.allCases) { filter in
                let selected = mediaFilter == filter
                Button {
                    mediaFilter = filter
                } label: {
                    Text(filter.rawValue)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .white : theme.palette.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selected ? theme.palette.accentBlue : theme.palette.cardSurface)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(selected ? theme.palette.accentBlue : theme.palette.borderSubtle, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text("\(filteredItems.count) \(filteredItems.count == 1 ? "item" : "items")")
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)

            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.palette.textSecondary)
                Slider(value: $thumbnailSize, in: 72...210, step: 12)
                    .frame(width: 110)
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.palette.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(theme.palette.commandBar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.palette.borderSubtle)
                .frame(height: 1)
        }
    }

    private func galleryTile(_ item: FileItem) -> some View {
        let isSelected = store.activeTab.selectedURLs.contains(item.url)
        let isHovered = hoveredURL == item.url
        let isCut = ExplorerViewFormatting.isCut(item, in: store)
        let tileSize = CGFloat(thumbnailSize)

        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                .fill(theme.palette.cardSurface)
                .frame(width: tileSize, height: tileSize)
                .overlay {
                    FileThumbnailView(item: item, size: tileSize - 10, isCut: isCut)
                }
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous))

            if item.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .padding(6)
            }

            if isHovered || isSelected {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.62)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous))

                Text(ExplorerViewFormatting.displayName(for: item, showExtensions: store.settings.showFileExtensions))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }

            if store.settings.showCheckboxes && (isHovered || isSelected) {
                VStack {
                    HStack {
                        FluentCheckbox(isChecked: isSelected) {
                            store.selectItem(url: item.url, toggling: true)
                        }
                        Spacer()
                    }
                    Spacer()
                }
                .padding(6)
            }
        }
        .frame(width: tileSize, height: tileSize)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                .stroke(
                    isSelected ? theme.palette.accentBlue : (isHovered ? theme.palette.borderSubtle.opacity(1.5) : theme.palette.borderSubtle),
                    lineWidth: isSelected ? 2.5 : 1
                )
        )
        .contentShape(Rectangle())
        .onHover { hoveredURL = $0 ? item.url : nil }
        .onTapGesture {
            ItemInteractionHandler.handleTap(item: item, store: store) {}
        }
        .onDrag {
            NSItemProvider(object: item.url as NSURL)
        }
        .overlay {
            RightClickHandlerOverlay {
                ItemInteractionHandler.handleRightClick(item: item, store: store) {}
            }
        }
    }

    private func timelineScrubber(proxy: ScrollViewProxy) -> some View {
        GeometryReader { geo in
            let sections = timelineSections
            ZStack(alignment: .trailing) {
                VStack(spacing: 4) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        let isFirstInYear = index == 0 || sections[index - 1].yearString != section.yearString
                        let isActive = activeScrubberID == section.id

                        Button {
                            activeScrubberID = section.id
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(section.id, anchor: .top)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if isFirstInYear {
                                    Text(section.yearString)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(isActive ? theme.palette.accentBlue : theme.palette.textSecondary)
                                }
                                Circle()
                                    .fill(isActive ? theme.palette.accentBlue : theme.palette.textSecondary.opacity(0.45))
                                    .frame(width: isActive ? 7 : 5, height: isActive ? 7 : 5)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
                .frame(width: 56)
                .background(theme.palette.navPane.opacity(0.65))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(theme.palette.borderSubtle)
                        .frame(width: 1)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isScrubbing = true
                            guard !sections.isEmpty else { return }
                            let usableHeight = max(1, geo.size.height - 24)
                            let fraction = min(1, max(0, (value.location.y - 12) / usableHeight))
                            let idx = min(sections.count - 1, max(0, Int(fraction * CGFloat(sections.count))))
                            let target = sections[idx]
                            if activeScrubberID != target.id {
                                activeScrubberID = target.id
                                proxy.scrollTo(target.id, anchor: .top)
                            }
                        }
                        .onEnded { _ in
                            isScrubbing = false
                        }
                )

                if isScrubbing,
                   let activeID = activeScrubberID,
                   let activeSection = sections.first(where: { $0.id == activeID }) {
                    Text(activeSection.shortLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(theme.palette.elevatedFlyout)
                                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(theme.palette.borderSubtle, lineWidth: 1)
                        )
                        .offset(x: -64)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: 56)
    }

    private var emptyGalleryState: some View {
        VStack(spacing: 12) {
            FluentIconView(kind: .gallery, size: 52)
            Text("No photos or videos to display")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
            Text("Switch to your Pictures folder or adjust the media filter above.")
                .font(.system(size: 12.5))
                .foregroundStyle(theme.palette.textSecondary)

            Button {
                let pictures = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
                store.navigate(to: .folder(pictures))
            } label: {
                Text("Open Pictures")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous)
                            .fill(theme.palette.accentBlue)
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
