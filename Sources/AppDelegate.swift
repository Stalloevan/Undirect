import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Tor takes a few seconds to load its directory cache and build a
        // circuit. When it's going to be needed, start it before the UI is
        // built so the two overlap.
        if Settings.shared.torForNewTabs || (!Settings.shared.closeTabsOnExit && SessionStore.shared.hasTorTabs()) {
            TorManager.shared.start()
        }
        // Lets web audio/video keep playing (and AirPlay keep streaming)
        // in the background and with the silent switch on, like Safari.
        // A synchronous round trip to the audio server, so off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            MediaPlayback.configureAudioSession()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}
