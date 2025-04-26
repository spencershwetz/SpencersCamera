import UIKit
import SwiftUI
import os.log

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let logger = Logger(subsystem: "com.camera", category: "SceneDelegate")
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        
        logger.info("Scene will connect")
        
        // Configure the window scene
        window = UIWindow(windowScene: windowScene)
        window?.overrideUserInterfaceStyle = .dark // Force dark mode
        window?.tintColor = .systemBlue
        
        // Set up the root view
        let contentView = MainView()
        window?.rootViewController = UIHostingController(rootView: contentView)
        window?.makeKeyAndVisible()
    }
    
    func windowScene(_ windowScene: UIWindowScene,
                    supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // Support all orientations for camera functionality
        return [.portrait, .landscapeLeft, .landscapeRight]
    }
    
    func sceneDidDisconnect(_ scene: UIScene) {
        logger.info("Scene did disconnect")
    }
    
    func sceneDidBecomeActive(_ scene: UIScene) {
        logger.info("Scene did become active")
    }
    
    func sceneWillResignActive(_ scene: UIScene) {
        logger.info("Scene will resign active")
    }
    
    func sceneWillEnterForeground(_ scene: UIScene) {
        logger.info("Scene will enter foreground")
    }
    
    func sceneDidEnterBackground(_ scene: UIScene) {
        logger.info("Scene did enter background")
    }
} 