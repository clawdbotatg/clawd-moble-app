import CoreLocation
import CoreMotion
import EventKit
import Foundation
import MLXLMCommon
import UIKit

/// The rest of the tool belt: location, weather, reminders, calendar-write,
/// steps, clipboard. Everything is declared up front (Info.plist usage
/// strings) but iOS only shows each permission dialog the first time the
/// model actually calls the tool that needs it.
enum MoreTools {

    // MARK: get_location

    struct LocationInput: Codable {}
    struct LocationResult: Codable {
        let latitude: Double
        let longitude: Double
        let place: String
    }

    static let currentLocation = Tool<LocationInput, LocationResult>(
        name: "get_location",
        description: "Get the user's current location (coordinates and city).",
        parameters: []
    ) { _ in
        let location = try await LocationOnce.request()
        let placemark = try? await CLGeocoder()
            .reverseGeocodeLocation(location).first
        let place = [
            placemark?.locality, placemark?.administrativeArea, placemark?.country,
        ]
        .compactMap { $0 }.joined(separator: ", ")
        return LocationResult(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            place: place.isEmpty ? "unknown" : place
        )
    }

    // MARK: get_weather

    struct WeatherInput: Codable {}
    struct WeatherResult: Codable {
        let place: String
        let forecast_json: String
    }

    static let weather = Tool<WeatherInput, WeatherResult>(
        name: "get_weather",
        description:
            "Current weather and 4-day forecast at the user's location "
            + "(temperatures in °F, wind in mph).",
        parameters: []
    ) { _ in
        let location = try await LocationOnce.request()
        let placemark = try? await CLGeocoder()
            .reverseGeocodeLocation(location).first
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(location.coordinate.latitude)),
            .init(name: "longitude", value: String(location.coordinate.longitude)),
            .init(
                name: "current",
                value: "temperature_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m"),
            .init(
                name: "daily",
                value:
                    "temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code"
            ),
            .init(name: "forecast_days", value: "4"),
            .init(name: "temperature_unit", value: "fahrenheit"),
            .init(name: "wind_speed_unit", value: "mph"),
            .init(name: "timezone", value: "auto"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return WeatherResult(
            place: placemark?.locality ?? "current location",
            forecast_json: String((String(data: data, encoding: .utf8) ?? "").prefix(1800))
        )
    }

    // MARK: get_reminders / create_reminder

    struct RemindersInput: Codable {
        let include_completed: Bool?
    }
    struct ReminderItem: Codable {
        let title: String
        let due: String?
        let completed: Bool
    }

    static let listReminders = Tool<RemindersInput, [ReminderItem]>(
        name: "get_reminders",
        description: "List the user's reminders (incomplete by default).",
        parameters: [
            .optional(
                "include_completed", type: .bool,
                description: "Also include completed reminders (default false)")
        ]
    ) { input in
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw PhoneTools.ToolFailure.denied("reminders")
        }
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: store.predicateForReminders(in: nil)) {
                continuation.resume(returning: $0 ?? [])
            }
        }
        return reminders
            .filter { input.include_completed == true || !$0.isCompleted }
            .prefix(25)
            .map { reminder in
                ReminderItem(
                    title: reminder.title ?? "(untitled)",
                    due: reminder.dueDateComponents.flatMap {
                        Calendar.current.date(from: $0).map(Self.format)
                    },
                    completed: reminder.isCompleted
                )
            }
    }

    struct CreateReminderInput: Codable {
        let title: String
        let due: String?
        let notes: String?
    }
    struct Confirmation: Codable {
        let created: String
    }

    static let createReminder = Tool<CreateReminderInput, Confirmation>(
        name: "create_reminder",
        description: "Create a reminder for the user.",
        parameters: [
            .required("title", type: .string, description: "What to remind them about"),
            .optional(
                "due", type: .string,
                description: "Due date-time as 'yyyy-MM-dd HH:mm' in the user's local time"),
            .optional("notes", type: .string, description: "Optional extra notes"),
        ]
    ) { input in
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw PhoneTools.ToolFailure.denied("reminders")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = input.title
        reminder.notes = input.notes
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let due = input.due, let date = Self.parse(due) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date)
            reminder.addAlarm(EKAlarm(absoluteDate: date))
        }
        try store.save(reminder, commit: true)
        return Confirmation(
            created: "reminder '\(input.title)'"
                + (input.due.map { " due \($0)" } ?? ""))
    }

    // MARK: create_calendar_event

    struct CreateEventInput: Codable {
        let title: String
        let start: String
        let duration_minutes: Int?
        let location: String?
    }

    static let createEvent = Tool<CreateEventInput, Confirmation>(
        name: "create_calendar_event",
        description: "Create a calendar event for the user.",
        parameters: [
            .required("title", type: .string, description: "Event title"),
            .required(
                "start", type: .string,
                description: "Start date-time as 'yyyy-MM-dd HH:mm' in the user's local time"),
            .optional(
                "duration_minutes", type: .int, description: "Length in minutes (default 60)"),
            .optional("location", type: .string, description: "Optional location"),
        ]
    ) { input in
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            throw PhoneTools.ToolFailure.denied("calendar")
        }
        guard let start = Self.parse(input.start) else {
            throw PhoneTools.ToolFailure.bad("invalid start format, use yyyy-MM-dd HH:mm")
        }
        let event = EKEvent(eventStore: store)
        event.title = input.title
        event.startDate = start
        event.endDate = start.addingTimeInterval(
            Double(input.duration_minutes ?? 60) * 60)
        event.location = input.location
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
        return Confirmation(created: "event '\(input.title)' at \(input.start)")
    }

    // MARK: get_steps

    struct StepsInput: Codable {
        let days: Int?
    }
    struct DailySteps: Codable {
        let date: String
        let steps: Int
    }

    static let steps = Tool<StepsInput, [DailySteps]>(
        name: "get_steps",
        description: "Daily step counts from the pedometer (default: today only).",
        parameters: [
            .optional("days", type: .int, description: "How many past days to include (1–7)")
        ]
    ) { input in
        guard CMPedometer.isStepCountingAvailable() else {
            throw PhoneTools.ToolFailure.denied("step counting (unavailable on this device)")
        }
        let pedometer = CMPedometer()
        let calendar = Calendar.current
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE MMM d"
        var results: [DailySteps] = []
        for offset in 0..<min(max(input.days ?? 1, 1), 7) {
            let day = calendar.date(byAdding: .day, value: -offset, to: Date())!
            let start = calendar.startOfDay(for: day)
            let end = offset == 0 ? Date() : calendar.date(byAdding: .day, value: 1, to: start)!
            let data: CMPedometerData? = try await withCheckedThrowingContinuation {
                continuation in
                pedometer.queryPedometerData(from: start, to: end) { data, error in
                    if let error { continuation.resume(throwing: error) } else {
                        continuation.resume(returning: data)
                    }
                }
            }
            results.append(
                DailySteps(
                    date: dayFormatter.string(from: start),
                    steps: data?.numberOfSteps.intValue ?? 0
                ))
        }
        return results
    }

    // MARK: read_clipboard

    struct ClipboardInput: Codable {}
    struct ClipboardResult: Codable {
        let text: String
    }

    static let clipboard = Tool<ClipboardInput, ClipboardResult>(
        name: "read_clipboard",
        description: "Read the text currently on the user's clipboard.",
        parameters: []
    ) { _ in
        await MainActor.run {
            ClipboardResult(
                text: String((UIPasteboard.general.string ?? "(clipboard is empty)").prefix(2000))
            )
        }
    }

    // MARK: wiring

    static var specs: [ToolSpec] {
        [
            currentLocation.schema, weather.schema, listReminders.schema,
            createReminder.schema, createEvent.schema, steps.schema, clipboard.schema,
        ]
    }

    static func dispatch(_ call: ToolCall) async -> String? {
        do {
            switch call.function.name {
            case currentLocation.name: return try encode(await call.execute(with: currentLocation))
            case weather.name: return try encode(await call.execute(with: weather))
            case listReminders.name: return try encode(await call.execute(with: listReminders))
            case createReminder.name: return try encode(await call.execute(with: createReminder))
            case createEvent.name: return try encode(await call.execute(with: createEvent))
            case steps.name: return try encode(await call.execute(with: steps))
            case clipboard.name: return try encode(await call.execute(with: clipboard))
            default: return nil
            }
        } catch {
            return #"{"error": "\#(error.localizedDescription)"}"#
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "{}"
    }

    static func parse(_ dateTime: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: dateTime)
    }

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d, h:mm a"
        return formatter.string(from: date)
    }
}

/// One-shot location fetch that owns the permission-dialog dance:
/// request authorization if undetermined, then a single location fix.
final class LocationOnce: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    static func request() async throws -> CLLocation {
        try await LocationOnce().run()
    }

    private func run() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                finish(.failure(PhoneTools.ToolFailure.denied("location")))
            default:
                manager.requestLocation()
            }
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(PhoneTools.ToolFailure.denied("location")))
        default:
            break  // .notDetermined: dialog still up
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.first {
            finish(.success(location))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }
}
