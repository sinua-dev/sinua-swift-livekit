# SinuaLiveKit

A `VoiceSource` that drives a Sinua visual from a [LiveKit](https://livekit.io)
room's agent audio. iOS 15+.

It is a separate SwiftPM package on purpose: it depends on
`livekit/client-sdk-swift`, and an app that doesn't use LiveKit shouldn't carry
that SDK. [`packages/ios`](../ios) has no dependency on this one.

```swift
import Sinua
import SinuaLiveKit

// Attach to a Room your app already has -- no credential passes through Sinua.
let voice = LiveKitVoiceSource(room: room)
SinuaView(pattern: "breathing", size: 64, voice: voice)
```

Two modes:

- **`init(room:)`** — attach to the app's existing `Room`. Sinua never connects,
  publishes, disconnects or attaches the track; the app owns all of that, and no
  credential reaches this package at all.
- **`init(url:token:)`** — own a Room for a demo: connect, publish the
  microphone, wait up to 20 s for an agent, and disconnect on teardown.

The agent's own `lk.agent.state` attribute drives the lifecycle
(`initializing`/`listening`/`thinking`/`speaking`); the energy heuristic is only
a fallback for a room that never publishes one.

## Adding it

```swift
.package(path: "../sinua/packages/ios-livekit")   // once published: .package(url: "https://github.com/sinua-dev/sinua-swift-livekit", from: "0.1.0-beta.1")
```

It depends on `packages/ios` by path, so both must be present.

## Building

```sh
xcodebuild build -scheme SinuaLiveKit -destination 'platform=iOS Simulator,name=iPhone 17e'
```

Compile-only: the SDK-free logic — which participant is the agent, how its
attributes map to a lifecycle state, how its PCM reaches the spectrum analyser —
is unit-tested in `SinuaVoiceTests` over in [`packages/ios`](../ios), because
that is where it lives. This package is the glue.

## What is not verified

**No live session has ever run.** Testing it needs a LiveKit Cloud project, a
room token and a dispatched agent. No physical device has run this code either.

## Licence

Apache-2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](../../NOTICE).
