# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

`ShareLocalDir` is a **macOS** SwiftUI application managed as an Xcode project (not Swift Package Manager — there is no `Package.swift`). It is currently the default Xcode template; the intended "share a local directory" functionality is not yet implemented.

## Build and run

There is a single scheme/target, `ShareLocalDir`. There are **no test or lint targets** configured.

```bash
# Open in Xcode (primary dev workflow; run with ⌘R)
open ShareLocalDir.xcodeproj

# Build from the command line
xcodebuild -scheme ShareLocalDir -configuration Debug build
xcodebuild -scheme ShareLocalDir -configuration Release build
```

To run the built app, build and launch from Xcode (⌘R). CLI builds land in your default `DerivedData` folder unless you pass `-derivedDataPath`.

## Architecture

- **Entry point**: `ShareLocalDir/ShareLocalDirApp.swift` (`@main`) → `WindowGroup { ContentView() }`. UI lives in `ShareLocalDir/ContentView.swift`.
- **macOS only**: `SDKROOT = macosx`, deployment target macOS 26.5, Swift 5. Use AppKit / SwiftUI-for-macOS APIs, not UIKit/iOS.
- **File System Synchronized Groups**: the `ShareLocalDir/` source folder uses Xcode's `PBXFileSystemSynchronizedRootGroup`. New `.swift` files added anywhere under `ShareLocalDir/` are automatically compiled into the target — **do not hand-edit `project.pbxproj` to register source files**; just add the file.
- **App Sandbox + Hardened Runtime are enabled** (`ENABLE_APP_SANDBOX = YES`, `ENABLE_HARDENED_RUNTIME = YES`). Sandbox file access is limited to user-selected files, read-only (`ENABLE_USER_SELECTED_FILES = readonly`). Any directory-sharing feature will need additional entitlements (e.g. a network-listening entitlement and security-scoped bookmarks or broader file access). This is the core constraint for this app's purpose.
- **Concurrency defaults**: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES` are set, so types default to MainActor isolation under Swift's strict-concurrency model.
- **Localization**: String Catalogs (`LOCALIZATION_PREFERS_STRING_CATALOGS = YES`); route user-facing strings through a catalog rather than hardcoding.

## Signing

`CODE_SIGN_STYLE = Automatic`; product bundle identifier `cn.basecrypto.ShareLocalDir`.
