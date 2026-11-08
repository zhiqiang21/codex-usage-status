import SwiftUI

@main
@MainActor
struct CodexUsageStatusApp: App {
    @StateObject private var settings: UserSettings
    @StateObject private var systemMetricsStore: SystemMetricsStore
    @StateObject private var usageStore: UsageStore
    @StateObject private var storageStore = DeveloperStorageStore()
    @StateObject private var launchAtLoginController: LaunchAtLoginController

    init() {
        let settings = UserSettings()
        let usageStore = UsageStore(settings: settings)
        let systemMetricsStore = SystemMetricsStore(settings: settings)
        _systemMetricsStore = StateObject(wrappedValue: systemMetricsStore)
        _settings = StateObject(wrappedValue: settings)
        _usageStore = StateObject(wrappedValue: usageStore)
        _launchAtLoginController = StateObject(
            wrappedValue: LaunchAtLoginController()
        )
        usageStore.start()
        systemMetricsStore.start()
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(
                store: usageStore,
                storageStore: storageStore,
                settings: settings,
                systemMetricsStore: systemMetricsStore,
                launchAtLoginController: launchAtLoginController
            )
        } label: {
            UsageMenuBarLabel(store: usageStore, settings: settings, systemMetricsStore: systemMetricsStore)
        }
        .menuBarExtraStyle(.window)
    }
}
