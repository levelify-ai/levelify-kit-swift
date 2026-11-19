# Bridge fixtures (bridge protocol v1)

Shared by the two test suites, so the Player and LevelifyKit's `LevelifyPlayerView` reach the same verdict on every message. The rules are in [`packages/contract/src/bridge.ts`](../../src/bridge.ts) (docs/08 §7.4).

| Path | What |
|---|---|
| `cases.json` | Every file in `messages/`, the side that receives it (`toPlayer` or `toHost`) and the verdict: `accept` (with its `type`), `ignore` or `reject` (with its `code`) |
| `messages/` | One wire message per file, exactly as sent: the JSON text, UTF-8. `not-json.txt` isn't JSON, and `too-large.json` is over 65,536 bytes |
| `conversations/` | Scripted sessions: `happy-path`, `version-mismatch` and `step-type-unknown`. `hostBridgeVersions` is what the host speaks, `messages` the order on the wire, and `expect` the outcome |

**For the Swift suite:** decode each `messages/` file as the receiving side named in `cases.json`, and check the verdict and its `code`. Run each conversation against the host's handshake: in `version-mismatch` the host sends nothing back and reports the Player unavailable.

**Changing them:** the fixtures are generated with fixed ids. Add a case to both `messages/` and `cases.json`, and `npm test` checks that the two lists match. A change to an existing `accept` case is a contract change: it needs a new bridge version unless it's additive (bridge.ts, "Versioning").
