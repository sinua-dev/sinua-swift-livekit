import AVFoundation
import Foundation
import LiveKit
import SinuaVoice

/// `VoiceSource` for a LiveKit Room with a LiveKit Agents voice agent in it --
/// the native mirror of the Web `LiveKitVoiceSource`
/// (packages/voice/src/LiveKitVoiceSource.ts). State comes from the agent's
/// `lk.agent.state` attribute, barge-in is inferred as on Web, and the
/// spectrum comes from the agent's remote audio track through the SDK's
/// `AudioRenderer` ("observe audio buffers before playback", client-sdk-swift
/// 2.17.0) into the same `SpectrumAnalyser` -> `AudioAnalysis` path as the mic.
/// All rules live in `LiveKitAgentTracker` (SinuaVoice, unit-tested); this
/// class only translates Room events. Callbacks arrive on the main thread.
///
/// Two ways in:
/// - `init(room:)` -- attach to the app's Room. Never connects, publishes,
///   plays or disconnects it; `disconnect()` only removes this source's
///   delegate and audio tap. The app's Room may connect later: the source
///   picks the agent up when it joins.
/// - `init(url:token:)` -- own a Room (demo / quick start): connects, enables
///   the mic so the agent hears the user, disconnects on teardown. The SDK
///   plays the agent's audio and manages `AVAudioSession` itself. The token is
///   a short-lived room JWT minted by the app's backend; nothing about it
///   passes through this library otherwise.
///
/// Not verified against a live agent yet (docs/audio-pipeline.md).
public final class LiveKitVoiceSource: NSObject, VoiceSource, RoomDelegate, @unchecked Sendable {
    public static let updateHz = 30.0
    /// components-js `useAgent`'s default, as on Web.
    public static let agentJoinTimeout: TimeInterval = 20

    private let room: Room
    private let ownsRoom: Bool
    private let url: String?
    private let token: String?
    private let publishMicrophone: Bool

    // Main-thread state.
    private let tracker = LiveKitAgentTracker()
    private var tappedTrack: RemoteAudioTrack?
    private lazy var renderer = Renderer(sink: tracker.sink)
    private var timer: DispatchSourceTimer?
    private var agentWaiter: CheckedContinuation<Void, Error>?

    public init(room: Room) {
        self.room = room
        ownsRoom = false
        url = nil
        token = nil
        publishMicrophone = false
    }

    public init(url: String, token: String, publishMicrophone: Bool = true) {
        room = Room()
        ownsRoom = true
        self.url = url
        self.token = token
        self.publishMicrophone = publishMicrophone
    }

    public func onMetrics(_ cb: @escaping (VoiceMetrics) -> Void) { tracker.onMetrics = cb }
    public func onStateChange(_ cb: @escaping (SinuaVoice.AgentState) -> Void) { tracker.onState = cb }
    public func onInterrupt(_ cb: @escaping () -> Void) { tracker.onInterrupt = cb }

    public func connect() async throws {
        await MainActor.run {
            tracker.start()
            room.add(delegate: self)
        }
        do {
            if ownsRoom, let url, let token {
                try await room.connect(url: url, token: token)
                if publishMicrophone { try await room.localParticipant.setMicrophone(enabled: true) }
            }
            let found = await MainActor.run { () -> Bool in
                for p in room.remoteParticipants.values { seen(p) }
                startTimer()
                return tracker.agentIdentity != nil
            }
            // Own Room: an agent must show up (the Web rule). Attached Room: the app may dispatch it later.
            if ownsRoom, !found { try await waitForAgent() }
        } catch {
            await MainActor.run { teardown() }
            throw error
        }
    }

    public func disconnect() {
        if Thread.isMainThread { teardown() } else { DispatchQueue.main.sync { teardown() } }
    }

    // MARK: - RoomDelegate (SDK queue -> main)

    public func room(_: Room, participantDidConnect participant: RemoteParticipant) {
        onMain { self.seen(participant) }
    }

    public func room(_: Room, participantDidDisconnect participant: RemoteParticipant) {
        onMain {
            guard let id = participant.identity?.stringValue else { return }
            if self.tracker.participantLeft(identity: id) { self.untap() }
        }
    }

    public func room(_ room: Room, participant: Participant, didUpdateAttributes attributes: [String: String]) {
        onMain {
            guard let id = participant.identity?.stringValue else { return }
            let hadAgent = self.tracker.agentIdentity != nil
            let role = self.tracker.attributesChanged(
                identity: id, isAgentKind: participant.kind == .agent,
                attributes: participant.attributes, changed: attributes,
                localSpeaking: room.localParticipant.isSpeaking)
            if !hadAgent { self.afterAdoption() }
            if role != .other, let remote = participant as? RemoteParticipant { self.scan(remote) }
        }
    }

    public func room(_: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        onMain {
            guard let track = publication.track as? RemoteAudioTrack else { return }
            if self.seen(participant, scan: false) != .other { self.tap(track) }
        }
    }

    public func room(_: Room, participant _: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication)
    {
        onMain {
            if let t = self.tappedTrack, publication.track === t {
                self.untap()
                self.tracker.audioDetached()
            }
        }
    }

    public func room(_: Room, didDisconnectWithError _: LiveKitError?) {
        onMain { if self.timer != nil { self.teardown() } }
    }

    // MARK: - Main-thread helpers

    @discardableResult
    private func seen(_ p: RemoteParticipant, scan doScan: Bool = true) -> LiveKitParticipantRole {
        guard let id = p.identity?.stringValue else { return .other }
        let hadAgent = tracker.agentIdentity != nil
        let role = tracker.participantSeen(identity: id, isAgentKind: p.kind == .agent, attributes: p.attributes)
        if doScan, role != .other { scan(p) }
        if !hadAgent { afterAdoption() }
        return role
    }

    /// If an agent was just adopted: pick up a worker already publishing for it (the Web adapter's adoptAgent scan).
    private func afterAdoption() {
        guard tracker.agentIdentity != nil else { return }
        for other in room.remoteParticipants.values {
            if let oid = other.identity?.stringValue,
                tracker.role(identity: oid, isAgentKind: other.kind == .agent, attributes: other.attributes)
                    == .agentWorker
            {
                scan(other)
            }
        }
        agentWaiter?.resume()
        agentWaiter = nil
    }

    /// Tracks subscribed before this source was listening never fire didSubscribeTrack for it.
    private func scan(_ p: RemoteParticipant) {
        for pub in p.trackPublications.values {
            if let track = pub.track as? RemoteAudioTrack {
                tap(track)
                return
            }
        }
    }

    private func tap(_ track: RemoteAudioTrack) {
        if tappedTrack === track { return }
        untap()
        tappedTrack = track
        tracker.audioAttached()
        track.add(audioRenderer: renderer)
    }

    private func untap() {
        tappedTrack?.remove(audioRenderer: renderer)
        tappedTrack = nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1 / Self.updateHz)
        t.setEventHandler { [weak self] in self?.tracker.tick() }
        timer = t
        t.resume()
    }

    private func waitForAgent() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                if self.tracker.agentIdentity != nil { return cont.resume() }
                self.agentWaiter = cont
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.agentJoinTimeout) {
                    guard let w = self.agentWaiter else { return }
                    self.agentWaiter = nil
                    w.resume(throwing: LiveKitVoiceSourceError.noAgent)
                }
            }
        }
    }

    private func teardown() {
        timer?.cancel()
        timer = nil
        untap()
        room.remove(delegate: self)
        agentWaiter?.resume(throwing: CancellationError())
        agentWaiter = nil
        tracker.stop()
        if ownsRoom { Task { await room.disconnect() } }
    }

    private func onMain(_ f: @escaping () -> Void) {
        DispatchQueue.main.async(execute: f)
    }

    /// Runs on the WebRTC audio thread: copy channel 0 into the tracker's ring, nothing else.
    private final class Renderer: NSObject, AudioRenderer, @unchecked Sendable {
        let sink: LiveKitPcmSink
        init(sink: LiveKitPcmSink) { self.sink = sink }

        func render(pcmBuffer: AVAudioPCMBuffer) {
            let n = Int(pcmBuffer.frameLength)
            guard n > 0 else { return }
            if let ch = pcmBuffer.floatChannelData?[0] {
                let stride = pcmBuffer.format.isInterleaved ? Int(pcmBuffer.format.channelCount) : 1
                if stride == 1 {
                    sink.write(UnsafeBufferPointer(start: ch, count: n))
                } else {
                    let mono = (0..<n).map { ch[$0 * stride] }
                    mono.withUnsafeBufferPointer { sink.write($0) }
                }
            } else if let ch = pcmBuffer.int16ChannelData?[0] {
                let channels = pcmBuffer.format.isInterleaved ? Int(pcmBuffer.format.channelCount) : 1
                sink.write(int16: UnsafeBufferPointer(start: ch, count: n * channels), channels: channels)
            }
        }
    }
}

public enum LiveKitVoiceSourceError: Error, Equatable {
    /// No agent joined the own Room within `agentJoinTimeout` (is one dispatched to this room?).
    case noAgent
}
