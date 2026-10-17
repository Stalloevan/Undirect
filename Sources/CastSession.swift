import UIKit
import AVKit
import AVFoundation

/// The native iOS player for ⋯ › Cast with AirPlay. Plays the page's
/// video through CastRelay, so the TV (or the phone) gets it with the tab's
/// own cookies and network — including Tor. Its controls have the standard
/// AirPlay button; the AirPlay picker also opens on its own when it appears.
///
/// Casting keeps going after the player is closed, while you use other apps,
/// or with the phone locked (the phone keeps relaying the video); it ends
/// when AirPlay is stopped or a new video is cast.
final class CastSession: NSObject, AVPlayerViewControllerDelegate {
    private(set) static var current: CastSession?

    let isTor: Bool
    private let player: AVPlayer
    private weak var playerController: AVPlayerViewController?
    private var observations: [NSKeyValueObservation] = []
    private var playerOnScreen = true
    private var routePicker: AVRoutePickerView?
    private var pictureInPicture = false
    private var watchdog: Timer?

    private init(relayURL: URL, isTor: Bool, title: String, startAt: Double) {
        self.isTor = isTor
        let item = AVPlayerItem(url: relayURL)
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = .commonIdentifierTitle
        titleItem.value = title as NSString
        titleItem.extendedLanguageTag = "und"
        item.externalMetadata = [titleItem]
        player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        super.init()

        // Resume where the page was.
        if startAt > 1 {
            observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .readyToPlay else { return }
                self?.player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600))
            })
        }
        observations.append(item.observe(\.status, options: [.new]) { item, _ in
            if item.status == .failed {
                AppLog.shared.log("Cast player couldn't play the stream: \(item.error?.localizedDescription ?? "unknown error")", category: "media")
            }
        })
        // When the TV disconnects and the player isn't on screen, we're done.
        observations.append(player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self, !player.isExternalPlaybackActive, !self.playerOnScreen else { return }
                self.end()
            }
        })
    }

    static func start(stream: URL, context: CastRelay.Context, title: String, startAt: Double, from host: UIViewController) {
        current?.end()
        CastRelay.shared.start(upstream: stream, context: context) { result in
            switch result {
            case .failure(let error):
                NotificationCenter.default.post(name: DownloadManager.toastNotification, object: error.localizedDescription)
            case .success(let relayURL):
                MediaPlayback.shared.yieldToNativePlayer()
                let session = CastSession(relayURL: relayURL, isTor: context.isTor, title: title, startAt: startAt)
                current = session
                session.present(from: host)
            }
        }
    }

    /// Ends the session once nothing uses it: the player is closed, it isn't
    /// on the TV and it isn't in Picture in Picture. (Backs up the delegate
    /// call, which iOS doesn't send for every way of closing the player.)
    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let visible = self.playerController?.viewIfLoaded?.window != nil
            if !visible && !self.pictureInPicture && !self.player.isExternalPlaybackActive { self.end() }
        }
    }

    private func present(from host: UIViewController) {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = self
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = true
        controller.modalPresentationStyle = .fullScreen
        playerController = controller
        let presenter = host.presentedViewController ?? host
        presenter.present(controller, animated: true) { [weak self] in
            self?.player.play()
            self?.startWatchdog()
            // Straight to the AirPlay picker — that's why you're here.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.showAirPlayPicker(in: controller.view) }
        }
    }

    private func showAirPlayPicker(in view: UIView) {
        guard !player.isExternalPlaybackActive else { return }
        let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.prioritizesVideoDevices = true
        picker.alpha = 0.01
        view.addSubview(picker)
        routePicker = picker
        // There's no public "show" call; tapping its button is how it opens.
        picker.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for: .touchUpInside)
    }

    // MARK: AVPlayerViewControllerDelegate

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self, !context.isCancelled else { return }
            self.playerOnScreen = false
            // Still on the TV: keep relaying in the background.
            if !self.player.isExternalPlaybackActive { self.end() }
        }
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        pictureInPicture = true
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        pictureInPicture = false
    }

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    // MARK: Ending

    func end() {
        guard CastSession.current === self else { return }
        CastSession.current = nil
        watchdog?.invalidate()
        watchdog = nil
        observations.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
        routePicker?.removeFromSuperview()
        if let controller = playerController, controller.presentingViewController != nil {
            controller.dismiss(animated: true)
        }
        CastRelay.shared.stop()
        MediaPlayback.shared.nativePlayerActive = false
        TorManager.shared.mediaStoppedPlaying()
    }
}
