import AppKit
import Observation
import SwiftUI
import Win11ShellCore

@MainActor
@Observable
public final class CalendarFlyoutState {
    public var displayedMonth: Date = Date()
    public var currentDate: Date = Date()
}

@MainActor
public final class CalendarFlyoutController {
    private let model: RunningAppsModel
    private let state = CalendarFlyoutState()
    private var panel: FocusableFloatingPanel?
    private var outsideMonitor: Any?
    private var clockTimer: Timer?

    public init(model: RunningAppsModel) {
        self.model = model
    }

    public func toggle(on screen: NSScreen? = nil) {
        if let panel, panel.isVisible {
            dismiss()
        } else {
            show(on: screen)
        }
    }

    public func show(on screen: NSScreen? = nil) {
        state.currentDate = Date()
        state.displayedMonth = Date()

        if panel == nil {
            let p = FocusableFloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 360),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.contentView = NSHostingView(rootView: CalendarFlyoutView(
                state: state,
                onDismiss: { [weak self] in self?.dismiss() }
            ))
            panel = p
        }

        let target = screen ?? NSScreen.main ?? NSScreen.screens.first
        if let target, let panel {
            let x = target.frame.maxX - panel.frame.width - 12
            let y = target.frame.minY + CGFloat(model.config.taskbarHeight) + 12
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            panel.makeKeyAndOrderFront(nil)
        }

        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.state.currentDate = Date()
            }
        }
        installOutsideMonitor()
    }

    public func dismiss() {
        clockTimer?.invalidate()
        clockTimer = nil
        panel?.orderOut(nil)
        if let outsideMonitor {
            NSEvent.removeMonitor(outsideMonitor)
            self.outsideMonitor = nil
        }
    }

    private func installOutsideMonitor() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) {
                    self.dismiss()
                }
            }
        }
    }
}

private struct CalendarFlyoutView: View {
    @Bindable var state: CalendarFlyoutState
    let onDismiss: () -> Void

    private let calendar = Calendar.current
    private let weekdays = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.currentDate.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 24, weight: .light))
                    .monospacedDigit()
                Text(state.currentDate.formatted(date: .complete, time: .omitted))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            Divider()

            HStack {
                Text(monthTitle(state.displayedMonth))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Today") {
                    state.displayedMonth = Date()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.accentColor)

                Button {
                    if let prev = calendar.date(byAdding: .month, value: -1, to: state.displayedMonth) {
                        state.displayedMonth = prev
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)

                Button {
                    if let next = calendar.date(byAdding: .month, value: 1, to: state.displayedMonth) {
                        state.displayedMonth = next
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 6) {
                ForEach(weekdays, id: \.self) { day in
                    Text(day)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(monthCells(for: state.displayedMonth).enumerated()), id: \.offset) { _, cell in
                    if let date = cell {
                        let isToday = calendar.isDateInToday(date)
                        Text("\(calendar.component(.day, from: date))")
                            .font(.system(size: 12, weight: isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? .white : .primary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(isToday ? Color.accentColor : .clear))
                    } else {
                        Color.clear.frame(width: 30, height: 30)
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("Open Calendar App") {
                    onDismiss()
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 320, height: 360)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThickMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        )
        .onExitCommand { onDismiss() }
    }

    private func monthTitle(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        return fmt.string(from: date)
    }

    private func monthCells(for date: Date) -> [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: date),
              let dayRange = calendar.range(of: .day, in: .month, for: date)
        else {
            return []
        }

        let firstWeekday = calendar.component(.weekday, from: monthInterval.start) - 1
        var cells: [Date?] = Array(repeating: nil, count: firstWeekday)
        for day in dayRange {
            if let d = calendar.date(byAdding: .day, value: day - 1, to: monthInterval.start) {
                cells.append(d)
            }
        }
        return cells
    }
}
