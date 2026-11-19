# LevelifyKit

Swift package for the Levelify iOS app. It talks to the project passed into `LevelifyKit.configure` (URL and publishable key) and downloads content from the base URL the app supplies. It holds no secrets and no baked-in project URL.

Products:

- `LevelifyKit` — auth, remote config, content, progress outbox. Builds on Linux.
- `LevelifyPlayerHost` — `LevelifyPlayerView` and the Player session. The web view is compiled only where WebKit and UIKit exist.
- `LevelifyKitTesting` — in-memory fakes for previews and tests.

`supabase-swift` is a dependency on Apple platforms. Linux CI uses the same calls over HTTP, because that package does not build on Linux.

```sh
cd packages/levelify-kit-swift
swift build
swift test
```

The integration test runs only when `LEVELIFY_DEV_SUPABASE_URL` and `LEVELIFY_DEV_PUBLISHABLE_KEY` are set.
