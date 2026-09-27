import SwiftUI
import UIKit

/// Week strip that pulls down into a full month calendar. Shared by the home
/// page and the diary page so both look and behave the same.
struct DiaryCalendarStrip: View {
    let selectedDate: Date
    /// Start-of-day dates that show the record dot.
    let markedDays: Set<Date>
    @Binding var isExpanded: Bool
    /// Fold back to the week row after a day is picked from the month grid.
    var collapsesOnSelect = false
    let onSelect: (Date) -> Void

    @State private var calendarMonth: Date = .now

    private let ink = Color(red: 0.22, green: 0.15, blue: 0.12)
    private let mutedInk = Color(red: 0.52, green: 0.46, blue: 0.42)
    private let accent = Color(red: 0.73, green: 0.43, blue: 0.17)
    private var calendar: Calendar { .current }

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                monthCalendar
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                weekRow
                    .transition(.opacity)
            }

            Button {
                setExpanded(!isExpanded)
            } label: {
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(mutedInk.opacity(0.45))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .frame(maxWidth: .infinity)
                    .frame(height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? String(localized: "收起日历") : String(localized: "展开日历"))
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(Color(red: 0.90, green: 0.87, blue: 0.83).opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    if abs(dy) > abs(dx) {
                        if dy > 24 { setExpanded(true) }
                        else if dy < -24 { setExpanded(false) }
                    } else if isExpanded, abs(dx) > 40 {
                        shiftMonth(dx < 0 ? 1 : -1)
                    }
                }
        )
        .onAppear { syncMonthToSelection() }
        .onChange(of: isExpanded) { _, expanded in
            if expanded { syncMonthToSelection() }
        }
    }

    private var weekRow: some View {
        let weekdaySymbols = AppLocale.veryShortWeekdaySymbols
        return HStack(spacing: 6) {
            ForEach(weekDates(centeredOn: selectedDate), id: \.self) { date in
                dayButton(date, weekday: weekdaySymbols[calendar.component(.weekday, from: date) - 1])
            }
        }
    }

    private var monthCalendar: some View {
        let weekdaySymbols = AppLocale.veryShortWeekdaySymbols
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        let canGoForward = !calendar.isDate(calendarMonth, equalTo: .now, toGranularity: .month)

        return VStack(spacing: 6) {
            HStack {
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 36, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "上个月"))

                Spacer()

                Text(AppLocale.string(from: calendarMonth, chinese: "yyyy年M月", template: "yMMMM"))
                    .font(DiaryFont.display(size: 16))
                    .foregroundStyle(ink)

                Spacer()

                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 36, height: 32)
                        .contentShape(Rectangle())
                }
                .disabled(!canGoForward)
                .opacity(canGoForward ? 1 : 0.3)
                .accessibilityLabel(String(localized: "下个月"))
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(mutedInk)
            .buttonStyle(.plain)
            .padding(.horizontal, 4)

            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { index in
                    Text(weekdaySymbols[index])
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(mutedInk.opacity(0.6))
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(monthCells.enumerated()), id: \.offset) { _, date in
                    if let date {
                        dayButton(date, weekday: nil)
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
            }
        }
    }

    private func dayButton(_ date: Date, weekday: String?) -> some View {
        let isToday = calendar.isDateInToday(date)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isFuture = calendar.startOfDay(for: date) > calendar.startOfDay(for: .now)
        let hasRecord = markedDays.contains(calendar.startOfDay(for: date))

        return Button {
            select(date)
        } label: {
            VStack(spacing: weekday == nil ? 2 : 4) {
                if let weekday {
                    Text(weekday)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(isFuture ? mutedInk.opacity(0.28) : (isSelected ? ink : mutedInk.opacity(0.6)))
                }

                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: weekday == nil ? 16 : 18, weight: .black, design: .rounded))
                    .foregroundStyle(isFuture ? mutedInk.opacity(0.28) : (isSelected ? ink : mutedInk.opacity(0.7)))

                Circle()
                    .fill(hasRecord ? accent : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, weekday == nil ? 5 : 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.white : Color.clear)
                    .shadow(color: isSelected ? .black.opacity(0.06) : .clear, radius: 6, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isToday && !isSelected ? accent.opacity(0.4) : .clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .accessibilityLabel(isToday ? String(localized: "今天") : AppLocale.string(from: date, chinese: "M月d日", template: "MMMMd"))
    }

    private func select(_ date: Date) {
        onSelect(date)
        if collapsesOnSelect, isExpanded {
            setExpanded(false)
        }
    }

    private var monthCells: [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: calendarMonth),
              let dayRange = calendar.range(of: .day, in: .month, for: calendarMonth) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: monthInterval.start)
        var cells = Array<Date?>(repeating: nil, count: firstWeekday - 1)
        for day in dayRange {
            cells.append(calendar.date(byAdding: .day, value: day - 1, to: monthInterval.start))
        }
        return cells
    }

    private func syncMonthToSelection() {
        calendarMonth = calendar.dateInterval(of: .month, for: selectedDate)?.start ?? selectedDate
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            isExpanded = expanded
        }
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: calendarMonth) else { return }
        let currentMonth = calendar.dateInterval(of: .month, for: .now)?.start ?? .now
        guard next <= currentMonth else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            calendarMonth = next
        }
    }

    private func weekDates(centeredOn date: Date) -> [Date] {
        (-3...3).compactMap { calendar.date(byAdding: .day, value: $0, to: date) }
    }

    /// Days with a real diary entry, skipping sticker-only placeholder records.
    static func diaryDays(in records: [StickerCalendarRecord]) -> Set<Date> {
        let calendar = Calendar.current
        return Set(records.compactMap { record in
            let text = record.diaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != "每日贴纸", text != "今日日记" else { return nil }
            return calendar.startOfDay(for: record.date)
        })
    }
}
