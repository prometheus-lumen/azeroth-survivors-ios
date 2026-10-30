# Azeroth Survivors for iOS / iPadOS

An independent WKWebView client for [Azeroth Survivors](https://wow.aethus.pl/), with an original fantasy shield-and-sword icon. The game is rendered by its original Rust/WASM/WebGPU client. This repository contains the iOS wrapper and build tools, not the game's source or game assets. It is not an official game release.

- Bundle identifier: `com.azerothsurvivors.app`
- Minimum iOS / iPadOS: **26.0**, with a working WebGPU adapter
- Landscape, original touch and gamepad controls
- The game's `pipe_warm=0` startup option compiles shaders on demand instead of prewarming every variant; the first use of a new effect can still cause a short compilation pause
- Packaged core, boot, world, initial UI/character resources and Stormwind model/texture dependencies; additional public `/data/` files download and cache as needed
- Persistent WebKit storage, a local safety copy of character saves, and native `.sav` export
- Three-finger double tap opens the wrapper menu (export, reload, official website)

## Build an unsigned IPA

Requirements: macOS, Xcode with the iOS 26 SDK or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen), Python 3 and curl with compression support. No Python packages are required.

```sh
python3 tools/fetch_assets.py www
bash build-ipa.sh
```

Output: `artifacts/AzerothSurvivors-unsigned.ipa`. Sign it using your own valid certificate and provisioning profile before installing it. Building an unsigned package does not establish that a signing tool's installation trigger works; test the resulting signed package on the target device.

The downloader obtains a consistent website build, checks the WASM header and decoded size, and packages the union of the boot/world manifests. A matching `tools/startup-manifest.json` adds initial UI, character and Stormwind scene asset names. It fails if required downloads are incomplete, preserving any previously complete build. `www/` is generated and excluded from Git. The whole public data index is much larger than the packaged set; unvisited game content still requires the upstream service. HTTP errors, server quotas, or unavailable network routes can prevent those downloads. Successful static responses can be cached long-term; errors are `no-store`, and a failed/cancelled local connection cancels its upstream task.

The packaged core does not update itself during play. Fetch and rebuild to adopt a newer game build. Keep the same bundle identifier, signing identity and stable loopback origin when updating, and export important saves beforehand. Deleting the app also deletes its local data and safety copy.

## Saves and diagnostics

Use the game's Options → Saves screen to import a `.sav` file. Export uses the native share sheet; the wrapper passes the game's sealed save text unchanged. The wrapper menu can also export the latest character data. The safety copy covers `rogue.characters` and its automatic backups; add-on storage remains in WebKit's persistent data store.

Diagnostics stay inside the app's Documents directory and record startup stages, GPU availability, request paths and error codes. They do not collect save contents, request bodies, cookies or URL query strings. There is no diagnostic upload service. A developer launch with `AZEROTH_VALIDATE=1` also saves local screenshots 3, 20 and 60 seconds after the game reports ready; normal launches do not take snapshots. Certificates, profiles, IPAs, device data and logs are excluded from this repository.

## Validation

```sh
python3 -m py_compile tools/*.py
python3 tools/verify_ipa.py artifacts/AzerothSurvivors-unsigned.ipa
# With the app's loopback server running in a simulator:
python3 tools/smoke_http.py --port 49761
```

The HTTP smoke check exercises real native responses, full WASM delivery, MIME, HEAD, ranges and path boundaries. Source CI typechecks the iOS wrapper without fetching or publishing game assets. See [the release checklist](docs/release-checklist.md) for installation, device network and gameplay checks. Compilation, installation, startup and full gameplay are separate validation results.

## Rights

The MIT license applies only to this repository's original wrapper code, scripts and icon. Azeroth Survivors and all downloaded game content retain their respective owners' rights. This repository does not grant permission to redistribute game assets or imply affiliation with their owners.
