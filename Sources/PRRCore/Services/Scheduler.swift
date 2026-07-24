import Foundation

/// Pure computation of the next collection time. Kept side-effect free so it is
/// fully unit-testable; the app drives an actual timer from `nextRunDate`.
public enum Scheduler {
    /// Returns the next date at which collection should run, given the settings
    /// and a reference "now". `calendar` is injectable for deterministic tests.
    public static func nextRunDate(after now: Date, settings: AppSettings, calendar: Calendar = .current) -> Date {
        switch settings.scheduleMode {
        case .everyNHours:
            let hours = max(1, settings.intervalHours)
            return now.addingTimeInterval(TimeInterval(hours) * 3600)

        case .dailyAt:
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = min(max(settings.dailyHour, 0), 23)
            components.minute = min(max(settings.dailyMinute, 0), 59)
            components.second = 0
            let candidate = calendar.date(from: components) ?? now
            if candidate > now {
                return candidate
            }
            // Already passed today → same time tomorrow.
            return calendar.date(byAdding: .day, value: 1, to: candidate) ?? now.addingTimeInterval(86_400)
        }
    }
}
