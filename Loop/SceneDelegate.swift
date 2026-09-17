//
//  SceneDelegate.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import UIKit

/// Minimal UIScene adoption: the iOS 27 SDK requires the scene life cycle, so this
/// delegate owns the window (instantiated from Main.storyboard via UISceneStoryboardFile)
/// and forwards every event to AppDelegate, which remains the app's WindowProvider and
/// single owner of LoopAppManager. The app supports exactly one scene.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private let log = DiagnosticLog(category: "SceneDelegate")

    /// sceneWillEnterForeground also fires on cold launch, unlike the legacy
    /// applicationWillEnterForeground; this flag preserves the legacy timing.
    private var isInitialForeground = true

    private var appDelegate: AppDelegate? {
        UIApplication.shared.delegate as? AppDelegate
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        log.default(#function)

        // UIKit has already instantiated the window from the storyboard; initialization
        // that used to happen in didFinishLaunching continues now that the window exists.
        appDelegate?.sceneWindowConnected(window)

        for urlContext in connectionOptions.urlContexts {
            _ = appDelegate?.handleOpenURL(urlContext.url)
        }
        for userActivity in connectionOptions.userActivities {
            appDelegate?.handleUserActivity(userActivity)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        log.default(#function)

        appDelegate?.sceneDidBecomeActive()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        log.default(#function)

        if isInitialForeground {
            isInitialForeground = false
            return
        }
        appDelegate?.sceneWillEnterForeground()
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        log.default(#function)

        for urlContext in URLContexts {
            _ = appDelegate?.handleOpenURL(urlContext.url)
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        log.default(#function)

        appDelegate?.handleUserActivity(userActivity)
    }
}
