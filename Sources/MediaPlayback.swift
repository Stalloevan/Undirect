import UIKit
import WebKit
import AVFoundation
import MediaPlayer

/// Web audio/video that keeps going while you use other apps:
/// - AirPlay to an Apple TV or AirPlay-compatible TV/speaker, from the
///   player's own button or ⋯ › Cast with AirPlay.
/// - Background audio, plus Picture in Picture when you leave a fullscreen
///   video (both need the app's "audio" background mode and a playback
///   audio session).
/// - Lock-screen / Control Center controls (play, pause, ±15 s, scrubbing).
/// - Tor stays awake while a Tor tab is playing, so the stream doesn't die
///   when the phone is locked.
///
/// A small script in each tab reports the media element the person is
/// actually playing; commands are sent back to that exact frame.
final class MediaPlayback {
    static let shared = MediaPlayback()
    static let didChange = Notification.Name("UndirectMediaDidChange")

    enum State: String { case playing, paused, ended }

    private(set) weak var tab: Tab?
    private var frame: WKFrameInfo?
    private(set) var state: State = .ended
    private(set) var isCasting = false
    private var title = ""
    private var artist = ""
    private var elapsed: Double = 0
    private var duration: Double = -1
    private var rate: Double = 1
    /// Tabs whose page has (or had) a video, so ⋯ can offer AirPlay.
    private var tabsWithVideo = NSHashTable<Tab>.weakObjects()
    private var commandsRegistered = false

    private init() {}

    // MARK: Setup

    /// Called once at launch. Only sets the category — the session becomes
    /// active when a page actually plays something, so opening Undirect
    /// never interrupts music from another app.
    func configureAudioSession() {
        // Default route sharing: the long-form-video policy hands the whole
        // app's output to the TV as if it were a native video player, which
        // left the TV on a loading spinner for web video.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var keepsTorAwake: Bool {
        guard let tab, tab.isTor else { return false }
        return state == .playing
    }

    func hasVideo(_ tab: Tab) -> Bool { tabsWithVideo.contains(tab) || self.tab === tab }

    // MARK: Messages from pages

    func handle(_ body: [String: Any], frame: WKFrameInfo, tab: Tab) {
        guard let raw = body["state"] as? String else { return }
        if (body["video"] as? Bool) == true { tabsWithVideo.add(tab) }
        if raw == "present" { return }
        guard let newState = State(rawValue: raw) else { return }

        // Something else starting to play becomes the one we control.
        if newState == .playing || self.tab === tab {
            self.tab = tab
            self.frame = frame
        } else {
            return
        }
        let wasPlaying = state == .playing
        state = newState
        title = (body["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tab.title
        artist = (body["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? tab.host.map(DomainUtil.normalize) ?? ""
        elapsed = (body["time"] as? Double) ?? 0
        duration = (body["duration"] as? Double) ?? -1
        rate = (body["rate"] as? Double) ?? 1

        let wireless = (body["wireless"] as? Bool) ?? false
        if wireless && !isCasting {
            toast("Playing on AirPlay — you can leave Undirect or lock your phone")
            AppLog.shared.log("AirPlay started on \(tab.host ?? "?")", category: "media")
        }
        isCasting = wireless

        if newState == .ended {
            clear()
        } else {
            registerCommands()
            updateNowPlaying()
        }
        if wasPlaying && newState != .playing { TorManager.shared.mediaStoppedPlaying() }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// The tab loaded a different page or was closed: its media is gone.
    func tabDidLeavePage(_ tab: Tab) {
        tabsWithVideo.remove(tab)
        guard self.tab === tab else { return }
        let wasPlaying = state == .playing
        clear()
        if wasPlaying { TorManager.shared.mediaStoppedPlaying() }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func clear() {
        tab = nil
        frame = nil
        state = .ended
        isCasting = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Now Playing / remote commands

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        } else {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        }
        // The site's own icon — already on the device, so nothing is fetched
        // (a poster image download would bypass Tor on Tor tabs).
        if let icon = tab?.icon {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: icon.size) { _ in icon }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let center = MPRemoteCommandCenter.shared()
        center.changePlaybackPositionCommand.isEnabled = duration > 0
        center.skipForwardCommand.isEnabled = duration > 0
        center.skipBackwardCommand.isEnabled = duration > 0
    }

    private func registerCommands() {
        guard !commandsRegistered else { return }
        commandsRegistered = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.send("play") ?? .commandFailed }
        center.pauseCommand.addTarget { [weak self] _ in self?.send("pause") ?? .commandFailed }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.send(self.state == .playing ? "pause" : "play")
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in self?.send("skip", 15) ?? .commandFailed }
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.send("skip", -15) ?? .commandFailed }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.send("seek", e.positionTime) ?? .commandFailed
        }
        // Not supported for web media.
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    private static let commandJS = """
        var m = window.__undirectActiveMedia;
        if (!m) return 'none';
        if (cmd === 'play') { var p = m.play(); if (p && p.catch) p.catch(function () {}); }
        else if (cmd === 'pause') m.pause();
        else if (cmd === 'skip') m.currentTime = Math.max(0, m.currentTime + arg);
        else if (cmd === 'seek') m.currentTime = Math.max(0, arg);
        return 'ok';
        """

    private func send(_ command: String, _ arg: Double = 0) -> MPRemoteCommandHandlerStatus {
        guard let tab else { return .noActionableNowPlayingItem }
        tab.webView.callAsyncJavaScript(Self.commandJS, arguments: ["cmd": command, "arg": arg],
                                        in: frame, in: .defaultClient) { _ in }
        // Reflect the change right away; the page's own event confirms it.
        switch command {
        case "play": state = .playing
        case "pause": state = .paused
        case "skip": elapsed = max(0, elapsed + arg)
        case "seek": elapsed = arg
        default: break
        }
        updateNowPlaying()
        return .success
    }

    // MARK: AirPlay

    private static let castJS = """
        var m = window.__undirectActiveMedia;
        if (!m || !m.isConnected) {
          var vids = Array.prototype.slice.call(document.querySelectorAll('video'));
          vids.sort(function (a, b) {
            var ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect();
            return (rb.width * rb.height) - (ra.width * ra.height);
          });
          m = vids[0];
        }
        if (!m) return 'none';
        // A site that turns AirPlay off usually streams in a way the TV can't
        // play (forcing it on just gives a spinner), so respect it.
        if (m.disableRemotePlayback || m.getAttribute('x-webkit-airplay') === 'deny') return 'blocked';
        if (typeof m.webkitShowPlaybackTargetPicker !== 'function') return 'unsupported';
        window.__undirectActiveMedia = m;
        m.webkitShowPlaybackTargetPicker();
        return 'ok';
        """

    /// ⋯ › Cast with AirPlay: opens the AirPlay picker for the page's video.
    func castCurrentVideo(in tab: Tab, from host: UIViewController) {
        let targetFrame = self.tab === tab ? frame : nil
        tab.webView.callAsyncJavaScript(Self.castJS, arguments: [:], in: targetFrame, in: .defaultClient) { [weak self, weak host] result in
            let outcome = (try? result.get()) as? String
            guard outcome != "ok", host != nil else { return }
            switch outcome {
            case "blocked":
                self?.toast("This site doesn't allow AirPlay for its videos")
            case "none" where !(self?.hasVideo(tab) ?? false):
                self?.toast("No video on this page to cast")
            default:
                // Usually a video inside an embedded player: the native
                // player's own AirPlay button reaches it.
                self?.toast("Play the video fullscreen, then tap its AirPlay button")
            }
        }
    }

    private func toast(_ message: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: DownloadManager.toastNotification, object: message)
        }
    }

    // MARK: Page script

    static func script(messageName: String) -> String {
        """
        (function () {
          if (window.__undirectMediaOn) return;
          window.__undirectMediaOn = true;
          var NAME = '\(messageName)';
          function post(m) { try { window.webkit.messageHandlers[NAME].postMessage(m); } catch (e) {} }
          var active = null;
          function meta() {
            var md = navigator.mediaSession && navigator.mediaSession.metadata;
            return { title: (md && md.title) || document.title || '', artist: (md && md.artist) || '' };
          }
          function report(m, state) {
            var d = m.duration, md = meta();
            post({ type: 'media', state: state, video: m.tagName === 'VIDEO',
                   title: md.title, artist: md.artist,
                   time: isFinite(m.currentTime) ? m.currentTime : 0,
                   duration: isFinite(d) ? d : -1,
                   rate: m.playbackRate || 1,
                   wireless: !!m.webkitCurrentPlaybackTargetIsWireless });
          }
          function onEvent(e) {
            var m = e.target;
            if (!(m instanceof HTMLMediaElement)) return;
            switch (e.type) {
              case 'playing':
                // Tiny muted clips (looping backgrounds, previews) aren't "media".
                if (m.muted && !m.webkitCurrentPlaybackTargetIsWireless) return;
                active = m; window.__undirectActiveMedia = m; report(m, 'playing'); break;
              case 'pause': if (m === active && !m.ended) report(m, 'paused'); break;
              case 'ended': case 'emptied': if (m === active) { report(m, 'ended'); active = null; } break;
              case 'volumechange':
                // A muted clip the person unmuted counts as real playback.
                if (m !== active && !m.muted && !m.paused) { active = m; window.__undirectActiveMedia = m; report(m, 'playing'); }
                break;
              case 'loadedmetadata':
                if (m.tagName === 'VIDEO') post({ type: 'media', state: 'present', video: true }); break;
              default: if (m === active) report(m, m.paused ? 'paused' : 'playing');
            }
          }
          ['playing', 'pause', 'ended', 'emptied', 'ratechange', 'seeked', 'durationchange', 'volumechange',
           'loadedmetadata', 'webkitcurrentplaybacktargetiswirelesschanged'].forEach(function (t) {
            document.addEventListener(t, onEvent, true);
          });
        })();
        """
    }
}
