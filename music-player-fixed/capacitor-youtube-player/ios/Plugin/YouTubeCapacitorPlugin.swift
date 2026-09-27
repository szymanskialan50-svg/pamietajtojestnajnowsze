import Foundation
import Capacitor
import WebKit

import AVFoundation

@objc(YouTubeCapacitorPlugin)
public class YouTubeCapacitorPlugin: CAPPlugin {
    
    private var player: YouTubePlayer?
    private var timer: Timer?
    private let silentPlayer = SilentAudioPlayer()
    
    public override func load() {
        super.load()
        DispatchQueue.main.async {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [])
                try session.setActive(true)
            } catch {
                print("Failed to set audio session category: \(error)")
            }
            
            self.silentPlayer.play() // Start silent audio to keep app alive in background
            
            // Inject script into the main Capacitor WebView to override Page Visibility
            // This applies to the main frame and all subframes (including the YouTube iframe).
            if let webView = self.bridge?.webView {
                let source = """
                Object.defineProperty(document, 'visibilityState', {
                    get: function() { return 'visible'; }
                });
                Object.defineProperty(document, 'hidden', {
                    get: function() { return false; }
                });
                document.addEventListener('visibilitychange', function(e) {
                    e.stopImmediatePropagation();
                }, true);
                """
                let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
                webView.configuration.userContentController.addUserScript(script)
            }
            
            self.player = YouTubePlayer()
            
            // Add the plugin's secondary web view as a hidden subview
            if let webView = self.player?.webView {
                webView.isHidden = true
                self.bridge?.webView?.superview?.addSubview(webView)
            }
            
            NotificationCenter.default.addObserver(self, selector: #selector(self.appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        }
    }
    
    @objc func appDidEnterBackground() {
        // Force WebKit/YouTube to resume playback if it was paused by backgrounding.
        // BUGFIX: this used to run on `self.bridge?.webView` (the MAIN app webview,
        // which never has a `ytPlayer` global — that's why background audio kept
        // stopping). The YouTube IFrame API + its `ytPlayer` object only exist
        // inside the hidden SECONDARY webview created by `YouTubePlayer` — i.e.
        // `self.player?.webView`. Also re-assert the audio session here, since
        // iOS can deactivate it right as the app is suspended.
        DispatchQueue.main.async {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [])
                try session.setActive(true)
            } catch {
                print("Failed to re-activate audio session in background: \(error)")
            }
            self.silentPlayer.play()
            self.player?.play()
            self.player?.webView?.evaluateJavaScript("if (typeof ytPlayer !== 'undefined' && ytPlayer && typeof ytPlayer.playVideo === 'function') { ytPlayer.playVideo(); }", completionHandler: nil)
        }
    }
    
    @objc func load(_ call: CAPPluginCall) {
        let videoId = call.getString("videoId") ?? ""
        
        DispatchQueue.main.async {
            if self.player?.webView == nil {
                // In case it wasn't initialized yet
                self.player?.load(videoId: videoId)
                if let webView = self.player?.webView {
                    webView.isHidden = true
                    self.bridge?.webView?.superview?.addSubview(webView)
                }
            } else {
                self.player?.load(videoId: videoId)
            }
            
            self.startStateObserver()
            call.resolve()
        }
    }
    
    @objc func play(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.player?.play()
            self.silentPlayer.play()
            call.resolve()
        }
    }
    
    @objc func pause(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.player?.pause()
            self.silentPlayer.pause()
            call.resolve()
        }
    }
    
    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.player?.stop()
            self.silentPlayer.pause()
            self.stopStateObserver()
            call.resolve()
        }
    }
    
    @objc func seekTo(_ call: CAPPluginCall) {
        let seconds = call.getFloat("seconds") ?? 0
        DispatchQueue.main.async {
            self.player?.seekTo(seconds, allowSeekAhead: true)
            call.resolve()
        }
    }
    
    @objc func setVolume(_ call: CAPPluginCall) {
        // IFrame API volume controls are not directly exposed by YouTubePlayer in this version,
        // but it doesn't matter much since iOS manages volume via hardware buttons.
        call.resolve()
    }
    
    private func startStateObserver() {
        stopStateObserver()
        
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.notifyState()
            }
        }
    }
    
    private func stopStateObserver() {
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = nil
        }
    }
    
    private func notifyState() {
        guard let player = self.player else { return }
        
        let stateStr: String
        switch player.playerState {
        case .unstarted: stateStr = "unstarted"
        case .ended: stateStr = "ended"
        case .playing: stateStr = "playing"
        case .paused: stateStr = "paused"
        case .buffering: stateStr = "buffering"
        case .cued: stateStr = "cued"
        case .unknown: stateStr = "unknown"
        }
        
        self.notifyListeners("youtubeStateChange", data: ["state": stateStr])
        
        Task {
            do {
                let duration = try await player.duration()
                let currentTime = try await player.currentTime()
                
                self.notifyListeners("youtubeTimeUpdate", data: [
                    "currentTime": currentTime,
                    "duration": duration
                ])
            } catch {
                // Ignore
            }
        }
    }
}

class SilentAudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    
    init() {
        engine.attach(playerNode)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) else { return }
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        
        let frames = AVAudioFrameCount(44100)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        for ch in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData?[ch]
            for i in 0..<Int(frames) {
                data?[i] = 0.0
            }
        }
        
        playerNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }
    
    func play() {
        do {
            if !engine.isRunning {
                try engine.start()
            }
            playerNode.play()
        } catch {
            print("Failed to start silent audio engine")
        }
    }
    
    func pause() {
        playerNode.pause()
        engine.pause()
    }
}
