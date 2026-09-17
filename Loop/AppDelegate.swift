//
//  AppDelegate.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 8/15/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import UIKit
import LoopKit

final class AppDelegate: UIResponder, UIApplicationDelegate, WindowProvider {
    var window: UIWindow?

    private let loopAppManager = LoopAppManager()
    private let log = DiagnosticLog(category: "AppDelegate")

    // MARK: - UIApplicationDelegate - Initialization

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        log.default("%{public}@ with launchOptions: %{public}@", #function, String(describing: launchOptions))

        setenv("CFNETWORK_DIAGNOSTICS", "3", 1)

        log.default("lastPathComponent = %{public}@", String(describing: Bundle.main.appStoreReceiptURL?.lastPathComponent))

        self.launchOptions = launchOptions
        // Initialization continues in sceneWindowConnected(_:) once SceneDelegate has a window
        return true
    }

    /// Held until the scene connects; under the scene life cycle the window doesn't
    /// exist yet at didFinishLaunching, and LoopAppManager needs it to launch.
    private var launchOptions: [UIApplication.LaunchOptionsKey: Any]?

    // MARK: - Scene life cycle (forwarded by SceneDelegate)

    /// Completes launch once the scene's storyboard-instantiated window is available.
    /// This is the same point in the legacy life cycle where didFinishLaunching ran,
    /// relative to window availability.
    func sceneWindowConnected(_ window: UIWindow?) {
        log.default(#function)

        self.window = window
        loopAppManager.initialize(windowProvider: self, launchOptions: launchOptions)
        launchOptions = nil
        loopAppManager.launch()
    }

    func sceneDidBecomeActive() {
        log.default(#function)

        loopAppManager.didBecomeActive()
    }

    func sceneWillEnterForeground() {
        log.default(#function)

        loopAppManager.askUserToConfirmLoopReset()
    }

    func handleOpenURL(_ url: URL) -> Bool {
        log.default(#function)

        return loopAppManager.handle(url)
    }

    func handleUserActivity(_ userActivity: NSUserActivity) {
        log.default(#function)

        _ = loopAppManager.userActivity(userActivity, restorationHandler: { _ in })
    }

    // MARK: - UIApplicationDelegate - Life Cycle

    func applicationDidBecomeActive(_ application: UIApplication) {
        log.default(#function)

        loopAppManager.didBecomeActive()
    }

    func applicationWillResignActive(_ application: UIApplication) {
        log.default(#function)
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        log.default(#function)
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        log.default(#function)
        
        loopAppManager.askUserToConfirmLoopReset()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        log.default(#function)
    }

    // MARK: - UIApplicationDelegate - Environment

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        DispatchQueue.main.async {
            if self.loopAppManager.isLaunchPending {
                self.loopAppManager.launch()
            }
        }
    }

    // MARK: - UIApplicationDelegate - Remote Notification

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        log.default(#function)

        loopAppManager.remoteNotificationRegistrationDidFinish(.success(deviceToken))
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log.error("%{public}@ with error: %{public}@", #function, String(describing: error))
        loopAppManager.remoteNotificationRegistrationDidFinish(.failure(error))
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        log.default(#function)

        completionHandler(loopAppManager.handleRemoteNotification(userInfo as? [String: AnyObject]) ? .noData : .failed)
    }
    
    // MARK: - UIApplicationDelegate - Deeplinking
    
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        loopAppManager.handle(url)
    }

    // MARK: - UIApplicationDelegate - Continuity

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        log.default(#function)

        return loopAppManager.userActivity(userActivity, restorationHandler: restorationHandler)
    }

    // MARK: - UIApplicationDelegate - Interface

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return loopAppManager.supportedInterfaceOrientations
    }
}
