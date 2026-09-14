//
//  SodaPushNotificationCoordinator.swift
//  SodaPush
//
//  Created by Phineas Guo on 2026/9/13.
//

import Foundation
import UserNotifications

#if os(iOS) || os(visionOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#elseif os(watchOS)
import WatchKit
#endif

@MainActor
@available(tvOS, unavailable, message: "tvOS does not provide remote-notification registration for third-party apps.")
public final class SodaPushNotificationCoordinator: NSObject {
    public let client: SodaPushClient

    public init(client: SodaPushClient) {
        self.client = client
        super.init()
    }

    /// Requests notification permission and starts the platform remote-notification registration flow.
    @discardableResult
    public func requestAuthorization(
        options: UNAuthorizationOptions = [.alert, .badge, .sound]
    ) async throws -> Bool {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: options)
        if granted {
            registerForRemoteNotifications()
        }
        return granted
    }

    /// Call this from the app delegate's didRegisterForRemoteNotificationsWithDeviceToken callback.
    @discardableResult
    public func didReceiveDeviceToken(_ deviceToken: Data) async throws -> SodaPushDeviceRegistration {
        try await client.updateDeviceToken(deviceToken)
    }

    /// Removes this installation from the server when the user signs out or disables push for the app.
    public func unregister() async throws {
        try await client.unregister()
    }

    private func registerForRemoteNotifications() {
        #if os(iOS) || os(visionOS)
        UIApplication.shared.registerForRemoteNotifications()
        #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications(matching: [.alert, .badge, .sound])
        #elseif os(watchOS)
        WKApplication.shared().registerForRemoteNotifications()
        #endif
    }
}
