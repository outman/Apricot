# ShareLocalDir 局域网目录分享 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS SwiftUI app that serves a user-selected directory over HTTP on the LAN (read-only), via SwiftNIO, with a copyable `http://<LAN-IP>:<port>` URL, QR code, open-in-browser, and a menu-bar status item.

**Architecture:** `@Observable @MainActor AppState` is the single UI state source and owns a `nonisolated FileShareServer` wrapping a SwiftNIO `ServerBootstrap`. A `ChannelInboundHandler` (`HTTPFileHandler`) routes GETs to directory listings or streamed file downloads. All server-side logic is `nonisolated` (opts out of the project's default `MainActor` isolation so it can run on NIO's event loop); pure helpers (`MimeTypeMap`, `PathResolver`, `RangeParser`, `DirectoryIndex`, `LocalNetwork`) are stateless enums/structs with unit tests.

**Tech Stack:** Swift 5/6 (Xcode 26), SwiftUI, AppKit (`NSStatusItem`/`NSOpenPanel`), SwiftNIO 2.101+ (`NIOCore`/`NIOPosix`/`NIOHTTP1` via the **`NIO`** umbrella product — note: the product is named `NIO`, not `SwiftNIO`), CoreImage (QR), App Sandbox + Hardened Runtime.

**Key constraints (from spec):**
- App Sandbox is ON. Binding a listen port requires `com.apple.security.network.server`. Reading a user-selected dir tree requires `files.user-selected.read-only`. Persisting it requires `files.bookmarks.app-sandbox`.
- SwiftNIO is referenced but **not linked** (`packageProductDependencies` empty) → must add a product dependency (the umbrella product is named `NIO`) or `import` fails.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` → every type touched by NIO MUST be declared `nonisolated` (type-level `nonisolated` parses fine in this toolchain, verified).
- Deployment target is macOS 14.6 (`@Observable`, `URL.components`, `.buttonStyle(.borderedProminent)` all available).

**Conventions for every task:** run builds/tests from the repo root. Commit at the end of each task with the exact message shown. If a SwiftNIO API signature differs slightly from what's written, follow the compiler — the exact shapes were verified against the resolved source (`~/Library/Developer/Xcode/DerivedData/ShareLocalDir-*/SourcePackages/checkouts/swift-nio`).

---

## Task 1: Link the SwiftNIO product to the app target

The package is referenced but the product isn't linked, so nothing can `import NIOCore` yet. The umbrella product is named **`NIO`** (not `SwiftNIO`).

**Files:**
- Modify: `ShareLocalDir.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add the `XCSwiftPackageProductDependency` object**

In `project.pbxproj`, replace:

```
/* End XCRemoteSwiftPackageReference section */
	};
```

with:

```
/* End XCRemoteSwiftPackageReference section */
/* Begin XCSwiftPackageProductDependency section */
		5C6EABCE2FE3DC8F00C9FF45 /* NIO */ = {
			isa = XCSwiftPackageProductDependency;
			package = 5C6EABCC2FE3DC8E00C9FF45 /* XCRemoteSwiftPackageReference "swift-nio" */;
			productName = NIO;
		};
/* End XCSwiftPackageProductDependency section */
	};
```

- [ ] **Step 2: Reference the dependency from the app target**

Replace:

```
			name = ShareLocalDir;
			packageProductDependencies = (
			);
			productName = ShareLocalDir;
```

with:

```
			name = ShareLocalDir;
			packageProductDependencies = (
				5C6EABCE2FE3DC8F00C9FF45 /* NIO */,
			);
			productName = ShareLocalDir;
```

- [ ] **Step 3: Verify the project still resolves + builds**

Run:
```bash
xcodebuild -scheme ShareLocalDir -configuration Debug build 2>&1 | tail -25
```
Expected: `** BUILD SUCCEEDED **` (the template still compiles; the product is now linked and resolvable). If you see `Missing package product`, the product name is `NIO` — confirm `productName = NIO;`.

- [ ] **Step 4: Commit**

```bash
git add ShareLocalDir.xcodeproj/project.pbxproj
git commit -m "build: link SwiftNIO product to app target"
```

---

## Task 2: Add the entitlements file + `CODE_SIGN_ENTITLEMENTS`

Sandbox is on but there is no entitlements file, and binding a port under the sandbox needs `network.server`.

**Files:**
- Create: `ShareLocalDir/ShareLocalDir.entitlements`
- Modify: `ShareLocalDir.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create the entitlements file**

Create `ShareLocalDir/ShareLocalDir.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-only</key>
	<true/>
	<key>com.apple.security.files.bookmarks.app-sandbox</key>
	<true/>
</dict>
</plist>
```

- [ ] **Step 2: Wire the build setting into both target configs**

`GENERATE_INFOPLIST_FILE = YES;` appears exactly twice in `project.pbxproj` (once in the Debug target config, once in Release). Use `replace_all` to add the entitlements line after each.

Replace (with `replace_all: true`):

```
				GENERATE_INFOPLIST_FILE = YES;
```

with (with `replace_all: true`):

```
				GENERATE_INFOPLIST_FILE = YES;
				CODE_SIGN_ENTITLEMENTS = "ShareLocalDir/ShareLocalDir.entitlements";
```

- [ ] **Step 3: Verify build + signing**

Run:
```bash
xcodebuild -scheme ShareLocalDir -configuration Debug build 2>&1 | tail -25
```
Expected: `** BUILD SUCCEEDED **`. If signing fails with a network/entitlement error, double-check the four keys are spelled exactly as above.

- [ ] **Step 4: Commit**

```bash
git add ShareLocalDir/ShareLocalDir.entitlements ShareLocalDir.xcodeproj/project.pbxproj
git commit -m "build: add entitlements (network.server, user-selected.read-only, bookmarks)"
```

---

## Task 3: Add the `ShareLocalDirTests` unit test target

There is no test target. We add one modeled on the app target, using its own `PBXFileSystemSynchronizedRootGroup` (`ShareLocalDirTests/`) so test `.swift` files are auto-compiled (no per-file pbxproj edits). All new object IDs are unique against the existing file.

**Files:**
- Modify: `ShareLocalDir.xcodeproj/project.pbxproj`
- Create: `ShareLocalDirTests/ShareLocalDirTests.swift`

- [ ] **Step 1: Add the test product file reference**

In the `PBXFileReference` section, replace:

```
/* Begin PBXFileReference section */
		5C6EABBE2FE3D9D600C9FF45 /* ShareLocalDir.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ShareLocalDir.app; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */
```

with:

```
/* Begin PBXFileReference section */
		5C6EABBE2FE3D9D600C9FF45 /* ShareLocalDir.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ShareLocalDir.app; sourceTree = BUILT_PRODUCTS_DIR; };
		5C6EABCF2FE3DC9000C9FF45 /* ShareLocalDirTests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = ShareLocalDirTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */
```

- [ ] **Step 2: Add the synchronized group for the test sources**

In the `PBXFileSystemSynchronizedRootGroup` section, replace:

```
		5C6EABC02FE3D9D600C9FF45 /* ShareLocalDir */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = ShareLocalDir;
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */
```

with:

```
		5C6EABC02FE3D9D600C9FF45 /* ShareLocalDir */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = ShareLocalDir;
			sourceTree = "<group>";
		};
		5C6EABD02FE3DC9100C9FF45 /* ShareLocalDirTests */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = ShareLocalDirTests;
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */
```

- [ ] **Step 3: Add test Sources/Frameworks/Resources build phases**

In the `PBXSourcesBuildPhase` section, replace:

```
		5C6EABBA2FE3D9D600C9FF45 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */
```

with:

```
		5C6EABBA2FE3D9D600C9FF45 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		5C6EABD12FE3DC9200C9FF45 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */
```

In the `PBXFrameworksBuildPhase` section, replace:

```
		5C6EABBB2FE3D9D600C9FF45 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */
```

with:

```
		5C6EABBB2FE3D9D600C9FF45 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		5C6EABD22FE3DC9300C9FF45 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */
```

In the `PBXResourcesBuildPhase` section, replace:

```
		5C6EABBC2FE3D9D600C9FF45 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */
```

with:

```
		5C6EABBC2FE3D9D600C9FF45 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		5C6EABD32FE3DC9400C9FF45 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */
```

- [ ] **Step 4: Add ContainerItemProxy + TargetDependency (new sections)**

Replace:

```
/* End PBXResourcesBuildPhase section */
```

with:

```
/* End PBXResourcesBuildPhase section */

/* Begin PBXContainerItemProxy section */
		5C6EABD42FE3DC9500C9FF45 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = 5C6EABB62FE3D9D500C9FF45 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = 5C6EABBD2FE3D9D600C9FF45;
			remoteInfo = ShareLocalDir;
		};
/* End PBXContainerItemProxy section */

/* Begin PBXTargetDependency section */
		5C6EABD52FE3DC9600C9FF45 /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = 5C6EABBD2FE3D9D600C9FF45 /* ShareLocalDir */;
			targetProxy = 5C6EABD42FE3DC9500C9FF45 /* PBXContainerItemProxy */;
		};
/* End PBXTargetDependency section */
```

- [ ] **Step 5: Add the test native target**

In the `PBXNativeTarget` section, replace:

```
/* End PBXNativeTarget section */
```

with:

```
		5C6EABD62FE3DC9700C9FF45 /* ShareLocalDirTests */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 5C6EABDA2FE3DC9B00C9FF45 /* Build configuration list for PBXNativeTarget "ShareLocalDirTests" */;
			buildPhases = (
				5C6EABD12FE3DC9200C9FF45 /* Sources */,
				5C6EABD22FE3DC9300C9FF45 /* Frameworks */,
				5C6EABD32FE3DC9400C9FF45 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
				5C6EABD52FE3DC9600C9FF45 /* PBXTargetDependency */,
			);
			fileSystemSynchronizedGroups = (
				5C6EABD02FE3DC9100C9FF45 /* ShareLocalDirTests */,
			);
			name = ShareLocalDirTests;
			packageProductDependencies = (
			);
			productName = ShareLocalDirTests;
			productReference = 5C6EABCF2FE3DC9000C9FF45 /* ShareLocalDirTests.xctest */;
			productType = "com.apple.product-type.bundle.unit-test";
		};
/* End PBXNativeTarget section */
```

> **Important:** the product type **must** be `com.apple.product-type.bundle.unit-test` (not the plain `.bundle`). Xcode keys the XCTest Swift overlay / test-target handling off this product type; a plain `.bundle` makes `import XCTest` resolve to the Clang headers (`XCTAssertEqual` comes through as an unavailable C macro).

- [ ] **Step 6: Add the test group + product to the main group and Products group**

Replace:

```
		5C6EABB52FE3D9D500C9FF45 = {
			isa = PBXGroup;
			children = (
				5C6EABC02FE3D9D600C9FF45 /* ShareLocalDir */,
				5C6EABBF2FE3D9D600C9FF45 /* Products */,
			);
			sourceTree = "<group>";
		};
		5C6EABBF2FE3D9D600C9FF45 /* Products */ = {
			isa = PBXGroup;
			children = (
				5C6EABBE2FE3D9D600C9FF45 /* ShareLocalDir.app */,
			);
			name = Products;
			sourceTree = "<group>";
		};
```

with:

```
		5C6EABB52FE3D9D500C9FF45 = {
			isa = PBXGroup;
			children = (
				5C6EABC02FE3D9D600C9FF45 /* ShareLocalDir */,
				5C6EABD02FE3DC9100C9FF45 /* ShareLocalDirTests */,
				5C6EABBF2FE3D9D600C9FF45 /* Products */,
			);
			sourceTree = "<group>";
		};
		5C6EABBF2FE3D9D600C9FF45 /* Products */ = {
			isa = PBXGroup;
			children = (
				5C6EABBE2FE3D9D600C9FF45 /* ShareLocalDir.app */,
				5C6EABCF2FE3DC9000C9FF45 /* ShareLocalDirTests.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		};
```

- [ ] **Step 7: Register the test target in the project's targets list**

Replace:

```
			targets = (
				5C6EABBD2FE3D9D600C9FF45 /* ShareLocalDir */,
			);
```

with:

```
			targets = (
				5C6EABBD2FE3D9D600C9FF45 /* ShareLocalDir */,
				5C6EABD62FE3DC9700C9FF45 /* ShareLocalDirTests */,
			);
```

- [ ] **Step 8: Add the two test build configurations**

In the `XCBuildConfiguration` section, replace:

```
/* End XCBuildConfiguration section */
```

with:

```
		5C6EABDB2FE3DC9C00C9FF45 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				BUNDLE_LOADER = "$(TEST_HOST)";
				FRAMEWORK_SEARCH_PATHS = (
					"$(inherited)",
					"$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/Library/Frameworks",
				);
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = 3R9FCEYZB4;
				GENERATE_INFOPLIST_FILE = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.6;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = cn.basecrypto.ShareLocalDirTests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = macosx;
				SWIFT_APPROACHABLE_CONCURRENCY = YES;
				SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_VERSION = 5.0;
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/ShareLocalDir.app/Contents/MacOS/ShareLocalDir";
				WRAPPER_EXTENSION = xctest;
			};
			name = Debug;
		};
		5C6EABDC2FE3DC9D00C9FF45 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				BUNDLE_LOADER = "$(TEST_HOST)";
				FRAMEWORK_SEARCH_PATHS = (
					"$(inherited)",
					"$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/Library/Frameworks",
				);
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = 3R9FCEYZB4;
				GENERATE_INFOPLIST_FILE = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.6;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = cn.basecrypto.ShareLocalDirTests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = macosx;
				SWIFT_APPROACHABLE_CONCURRENCY = YES;
				SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_VERSION = 5.0;
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/ShareLocalDir.app/Contents/MacOS/ShareLocalDir";
				WRAPPER_EXTENSION = xctest;
			};
			name = Release;
		};
/* End XCBuildConfiguration section */
```

- [ ] **Step 9: Add the test configuration list**

In the `XCConfigurationList` section, replace:

```
/* End XCConfigurationList section */
```

with:

```
		5C6EABDA2FE3DC9B00C9FF45 /* Build configuration list for PBXNativeTarget "ShareLocalDirTests" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				5C6EABDB2FE3DC9C00C9FF45 /* Debug */,
				5C6EABDC2FE3DC9D00C9FF45 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */
```

- [ ] **Step 10: Create a shared scheme with a Test action**

The project ships with no `.xcscheme` files, so `xcodebuild` uses auto-generated implicit schemes whose Test action is empty (`Scheme … is not currently configured for the test action`). Create a shared scheme that lists the test bundle in its Test action.

Create `ShareLocalDir.xcodeproj/xcshareddata/xcschemes/ShareLocalDir.xcscheme`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2650"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "5C6EABBD2FE3D9D600C9FF45"
               BuildableName = "ShareLocalDir.app"
               BlueprintName = "ShareLocalDir"
               ReferencedContainer = "container:ShareLocalDir.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "5C6EABD62FE3DC9700C9FF45"
               BuildableName = "ShareLocalDirTests.xctest"
               BlueprintName = "ShareLocalDirTests"
               ReferencedContainer = "container:ShareLocalDir.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "5C6EABBD2FE3D9D600C9FF45"
            BuildableName = "ShareLocalDir.app"
            BlueprintName = "ShareLocalDir"
            ReferencedContainer = "container:ShareLocalDir.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "5C6EABBD2FE3D9D600C9FF45"
            BuildableName = "ShareLocalDir.app"
            BlueprintName = "ShareLocalDir"
            ReferencedContainer = "container:ShareLocalDir.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
```

- [ ] **Step 11: Add a dummy passing test so the target compiles**

Create `ShareLocalDirTests/ShareLocalDirTests.swift`:

```swift
import XCTest
@testable import ShareLocalDir

final class ShareLocalDirTests: XCTestCase {
    func testSanity() {
        XCTAssertEqual(1 + 1, 2)
    }
}
```

- [ ] **Step 12: Verify the test target builds and runs**

Run:
```bash
xcodebuild test -scheme ShareLocalDir -destination 'platform=macOS' 2>&1 | tail -40
```
Expected: `** TEST SUCCEEDED **` with `ShareLocalDirTests/testSanity` passing. (The shared scheme's Test action runs `ShareLocalDirTests`.)

- [ ] **Step 13: Commit**

```bash
git add ShareLocalDir.xcodeproj/project.pbxproj ShareLocalDir.xcodeproj/xcshareddata/xcschemes/ShareLocalDir.xcscheme ShareLocalDirTests/ShareLocalDirTests.swift
git commit -m "build: add ShareLocalDirTests unit test target"
```

---

## Task 4: `MimeTypeMap` (TDD)

Pure extension→Content-Type lookup. `nonisolated` so it's callable from the event loop.

**Files:**
- Create: `ShareLocalDir/server/MimeTypeMap.swift`
- Modify: `ShareLocalDirTests/ShareLocalDirTests.swift` (append a test)

- [ ] **Step 1: Write the failing test**

Append to `ShareLocalDirTests/ShareLocalDirTests.swift` (before the final closing brace of the class — i.e. replace the `}` that closes `final class ShareLocalDirTests` with the test below followed by `}`):

```swift

    func testMimeTypeKnownExtensions() {
        XCTAssertEqual(MimeTypeMap.contentType(forPathExtension: "html"), "text/html; charset=utf-8")
        XCTAssertEqual(MimeTypeMap.contentType(forPathExtension: "PNG"), "image/png")
        XCTAssertEqual(MimeTypeMap.contentType(forPathExtension: "pdf"), "application/pdf")
    }

    func testMimeTypeUnknownIsOctetStream() {
        XCTAssertEqual(MimeTypeMap.contentType(forPathExtension: "zzz"), "application/octet-stream")
        XCTAssertEqual(MimeTypeMap.contentType(forPathExtension: ""), "application/octet-stream")
    }
```

(Place these inside the class body; keep one final `}` to close the class.)

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild test -scheme ShareLocalDir -destination 'platform=macOS' -only-testing:ShareLocalDirTests 2>&1 | tail -30
```
Expected: FAIL — `cannot find 'MimeTypeMap' in scope`.

- [ ] **Step 3: Implement `MimeTypeMap`**

Create `ShareLocalDir/server/MimeTypeMap.swift`:

```swift
import Foundation

nonisolated enum MimeTypeMap {
    private static let map: [String: String] = [
        "html": "text/html; charset=utf-8",
        "htm": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "application/javascript",
        "json": "application/json",
        "txt": "text/plain; charset=utf-8",
        "md": "text/markdown; charset=utf-8",
        "xml": "application/xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "svg": "image/svg+xml",
        "webp": "image/webp",
        "ico": "image/x-icon",
        "bmp": "image/bmp",
        "pdf": "application/pdf",
        "zip": "application/zip",
        "gz": "application/gzip",
        "tar": "application/x-tar",
        "7z": "application/x-7z-compressed",
        "mp4": "video/mp4",
        "mov": "video/quicktime",
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "m4a": "audio/mp4",
    ]

    static func contentType(forPathExtension ext: String) -> String {
        map[ext.lowercased()] ?? "application/octet-stream"
    }

    static func contentType(for url: URL) -> String {
        contentType(forPathExtension: url.pathExtension)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
xcodebuild test -scheme ShareLocalDir -destination 'platform=macOS' -only-testing:ShareLocalDirTests 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ShareLocalDir/server/MimeTypeMap.swift ShareLocalDirTests/ShareLocalDirTests.swift
git commit -m "feat: add MimeTypeMap with tests"
```

---

## Task 5: `PathResolver` — path-traversal guard (TDD, security-critical)

Resolves a request URI against the shared root and rejects anything escaping it.

**Files:**
- Create: `ShareLocalDir/server/PathResolver.swift`
- Modify: `ShareLocalDirTests/ShareLocalDirTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside the test class:

```swift

    func testPathResolverAllowsRoot() {
        let root = URL(fileURLWithPath: "/tmp/sharelocal_root")
        let path = PathResolver.containedAbsolutePath(relativePath: "/", root: root)
        XCTAssertEqual(path, "/tmp/sharelocal_root")
    }

    func testPathResolverAllowsSubpath() {
        let root = URL(fileURLWithPath: "/tmp/sharelocal_root")
        let path = PathResolver.containedAbsolutePath(relativePath: "/a/b.txt", root: root)
        XCTAssertEqual(path, "/tmp/sharelocal_root/a/b.txt")
    }

    func testPathResolverDecodesPercentEncoding() {
        let root = URL(fileURLWithPath: "/tmp/sharelocal_root")
        let path = PathResolver.containedAbsolutePath(relativePath: "/%61/%62.txt", root: root)
        XCTAssertEqual(path, "/tmp/sharelocal_root/a/b.txt")
    }

    func testPathResolverRejectsTraversal() {
        let root = URL(fileURLWithPath: "/tmp/sharelocal_root")
        XCTAssertNil(PathResolver.containedAbsolutePath(relativePath: "/../etc/passwd", root: root))
        XCTAssertNil(PathResolver.containedAbsolutePath(relativePath: "/a/../../etc/passwd", root: root))
        XCTAssertNil(PathResolver.containedAbsolutePath(relativePath: "/%2e%2e/secret", root: root))
    }

    func testPathResolverStripsQueryAndFragment() {
        let root = URL(fileURLWithPath: "/tmp/sharelocal_root")
        let path = PathResolver.containedAbsolutePath(relativePath: "/a.txt?x=1#frag", root: root)
        XCTAssertEqual(path, "/tmp/sharelocal_root/a.txt")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild test -scheme ShareLocalDir -destination 'platform=macOS' -only-testing:ShareLocalDirTests 2>&1 | tail -30
```
Expected: FAIL — `cannot find 'PathResolver' in scope`.

- [ ] **Step 3: Implement `PathResolver`**

Create `ShareLocalDir/server/PathResolver.swift`:

```swift
import Foundation

nonisolated enum PathResolver {
    enum Error: Swift.Error, Equatable {
        case forbidden
        case notFound
    }

    /// Pure: resolve `relativePath` (an HTTP request URI) against `root` and verify the result
    /// stays inside `root`. Returns the standardized absolute path on success, nil on escape.
    static func containedAbsolutePath(relativePath uri: String, root: URL) -> String? {
        // strip query and fragment
        var pathOnly = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        pathOnly = pathOnly.split(separator: "#", maxSplits: 1).first.map(String.init) ?? pathOnly

        // percent-decode once (catches %2e%2e)
        guard let decoded = pathOnly.removingPercentEncoding else { return nil }

        let rootStd = root.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPrefix = rootStd.hasSuffix("/") ? rootStd : rootStd + "/"

        // drop a leading "/" so we append relative segments
        let relative = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded

        let candidate = URL(fileURLWithPath: rootStd, isDirectory: true)
            .appendingPathComponent(relative)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        let isRoot = candidate == rootStd
        let isUnder = candidate.hasPrefix(rootPrefix)
        guard isRoot || isUnder else { return nil }
        return candidate
    }

    /// Filesystem-aware resolve. `.forbidden` if the path escapes root, `.notFound` if it
    /// doesn't exist.
    static func resolve(relativePath uri: String, root: URL) -> Result<URL, Error> {
        guard let path = containedAbsolutePath(relativePath: uri, root: root) else {
            return .failure(.forbidden)
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(.notFound)
        }
        return .success(URL(fileURLWithPath: path))
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
xcodebuild test -scheme ShareLocalDir -destination 'platform=macOS' -only-testing:ShareLocalDirTests 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **` (all 5 path tests pass).

- [ ] **Step 5: Commit**

```bash
git add ShareLocalDir/server/PathResolver.swift ShareLocalDirTests/ShareLocalDirTests.swift
git commit -m "feat: add PathResolver traversal guard with tests"
```

---

## Task 6: `RangeParser` (TDD)

Parses `Range: bytes=start-end` for partial-content support.

**Files:**
- Create: `ShareLocalDir/server/RangeParser.swift`
- Modify: `ShareLocalDirTests/ShareLocalDirTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside the test class:

```swift

    func testRangeParserValid() {
        XCTAssertEqual(RangeParser.parse("bytes=0-99", total: 100)?.start, 0)
        XCTAssertEqual(RangeParser.parse("bytes=0-99", total: 100)?.end, 99)
        XCTAssertEqual(RangeParser.parse("bytes=10-19", total: 100)?.start, 10)
        XCTAssertEqual(RangeParser.parse("bytes=10-19", total: 100)?.end, 19)
    }

    func testRangeParserInvalid() {
        XCTAssertNil(RangeParser.parse("", total: 100))
        XCTAssertNil(RangeParser.parse("bytes=abc-def", total: 100))
        XCTAssertNil(RangeParser.parse("bytes=50-10", total: 100))     // start > end
        XCTAssertNil(RangeParser.parse("bytes=0-100", total: 100))     // end == total (out of range)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild test -scheme ShareLocalDir -destination 'platform=macOS' -only-testing:ShareLocalDirTests 2>&1 | tail -30
```
Expected: FAIL — `cannot find 'RangeParser' in scope`.

- [ ] **Step 3: Implement `RangeParser`**

Create `ShareLocalDir/server/RangeParser.swift`:

```swift
import Foundation

nonisolated enum RangeParser {
    struct Range: Equatable {
        let start: Int64
        let end: Int64
    }

    /// Parse a `Range: bytes=start-end` header into inclusive bounds, or nil if absent/invalid.
    static func parse(_ header: String, total: Int64) -> Range? {
        guard header.hasPrefix("bytes=") else { return nil }
        let body = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        let parts = body.split(separator: "-").map(String.init)
        guard parts.count == 2,
              let start = Int64(parts[0]),
              let end = Int64(parts[1]) else { return nil }
        guard start >= 0, end < total, start <= end else { return nil }
        return Range(start: start, end: end)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
xcodebuild test -scheme ShareLocalDir -destination 'platform=macOS' -only-testing:ShareLocalDirTests 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ShareLocalDir/server/RangeParser.swift ShareLocalDirTests/ShareLocalDirTests.swift
git commit -m "feat: add RangeParser with tests"
```

---

## Task 7: `DirectoryIndex` + `DirectoryEntry` (TDD)

Generates the HTML listing. Tests assert escaping, sorting (dirs first then alpha), parent link, and size formatting — not locale-dependent date strings.

**Files:**
- Create: `ShareLocalDir/server/DirectoryIndex.swift`
- Modify: `ShareLocalDirTests/ShareLocalDirTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside the test class:

```swift

    private func entry(_ name: String, isDir: Bool = false, size: Int64 = 0) -> DirectoryEntry {
        DirectoryEntry(name: name, isDirectory: isDir, size: size,
                       modificationDate: Date(timeIntervalSince1970: 0))
    }

    func testDirectoryIndexEscapesNames() {
        let html = DirectoryIndex.html(title: "t",
                                       entries: [entry("<b>&x</b>")],
                                       requestPath: "/")
        XCTAssertTrue(html.contains("&lt;b&gt;&amp;x&lt;/b&gt;"))
        XCTAssertFalse(html.contains("<b>&x</b>"))
    }

    func testDirectoryIndexParentLinkOnlyForNonRoot() {
        let withParent = DirectoryIndex.html(title: "t", entries: [], requestPath: "/sub/")
        let atRoot = DirectoryIndex.html(title: "t", entries: [], requestPath: "/")
        XCTAssertTrue(withParent.contains("href=\"../\""))
        XCTAssertFalse(atRoot.contains("href=\"../\""))
    }

    func testDirectoryIndexSortsDirsFirstThenAlpha() {
        let entries = [entry("zeta.txt"), entry("Alpha", isDir: true), entry("beta.txt"), entry("Gamma", isDir: true)]
        let html = DirectoryIndex.html(title: "t", entries: entries, requestPath: "/")
        let alphaRange = html.range(of: "Alpha/")
        let gammaRange = html.range(of: "Gamma/")
        let betaRange = html.range(of: "beta.txt")
        let zetaRange = html.range(of: "zeta.txt")
        // directories precede files
        XCTAssertNotNil(alphaRange); XCTAssertNotNil(gammaRange)
        XCTAssertNotNil(betaRange); XCTAssertNotNil(zetaRange)
        XCTAssertLessThan(alphaRange!.lowerBound, gammaRange!.lowerBound)
        XCTAssertLessThan(gammaRange!.lowerBound, betaRange!.lowerBound)
        XCTAssertLessThan(betaRange!.lowerBound, zetaRange!.lowerBound)
    }

    func testHumanReadable() {
        XCTAssertEqual(DirectoryIndex.humanReadable(0), "0 B")
        XCTAssertEqual(DirectoryIndex.humanReadable(1023), "1023 B")
        XCTAssertEqual(DirectoryIndex.humanReadable(2048), "2.0 KB")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild test -scheme ShareLocalDir -destination 'platform=macOS' -only-testing:ShareLocalDirTests 2>&1 | tail -30
```
Expected: FAIL — `cannot find 'DirectoryIndex' / 'DirectoryEntry' in scope`.

- [ ] **Step 3: Implement `DirectoryIndex`**

Create `ShareLocalDir/server/DirectoryIndex.swift`:

```swift
import Foundation

nonisolated struct DirectoryEntry: Equatable {
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date
}

nonisolated enum DirectoryIndex {
    static func html(title: String, entries: [DirectoryEntry], requestPath: String) -> String {
        var out = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        body{font-family:-apple-system,system-ui,sans-serif;max-width:920px;margin:24px auto;padding:0 16px;color:#222}
        h1{font-size:18px;font-weight:600;word-break:break-all}
        table{width:100%;border-collapse:collapse}
        th,td{text-align:left;padding:8px;border-bottom:1px solid #eee;font-size:14px}
        th{color:#888;font-weight:500}
        a{color:#0a66c2;text-decoration:none}
        a:hover{text-decoration:underline}
        .meta{color:#888;text-align:right;white-space:nowrap}
        </style></head><body>
        <h1>\(escape(title))</h1>
        <table><thead><tr><th>名称</th><th class="meta">大小</th><th class="meta">修改时间</th></tr></thead><tbody>

        """
        if requestPath != "/" {
            out += "<tr><td colspan=\"3\"><a href=\"../\">../</a></td></tr>\n"
        }

        let sorted = entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        for e in sorted {
            let display = escape(e.name) + (e.isDirectory ? "/" : "")
            let href = (escapePathComponent(e.name)) + (e.isDirectory ? "/" : "")
            let size = e.isDirectory ? "-" : humanReadable(e.size)
            let date = df.string(from: e.modificationDate)
            out += "<tr><td><a href=\"\(href)\">\(display)</a></td><td class=\"meta\">\(size)</td><td class=\"meta\">\(escape(date))</td></tr>\n"
        }

        out += "</tbody></table></body></html>\n"
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func escapePathComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    static func humanReadable(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1024, idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        if idx == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[idx])
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
xcodebuild test -scheme ShareLocalDir -destination 'platform=macOS' -only-testing:ShareLocalDirTests 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **` (all directory-index tests pass).

- [ ] **Step 5: Commit**

```bash
git add ShareLocalDir/server/DirectoryIndex.swift ShareLocalDirTests/ShareLocalDirTests.swift
git commit -m "feat: add DirectoryIndex HTML generator with tests"
```

---

## Task 8: `LocalNetwork` — LAN IPv4 detection (TDD for the pure selector)

`bestIPv4` is pure/testable; `ipv4Addresses()` wraps `getifaddrs`.

**Files:**
- Create: `ShareLocalDir/net/LocalNetwork.swift`
- Modify: `ShareLocalDirTests/ShareLocalDirTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside the test class:

```swift

    func testBestIPv4PrefersEnInterface() {
        let interfaces = [
            LocalNetwork.Interface(name: "en0", address: "192.168.1.20"),
            LocalNetwork.Interface(name: "bridge100", address: "10.0.0.5"),
        ]
        XCTAssertEqual(LocalNetwork.bestIPv4(from: interfaces), "192.168.1.20")
    }

    func testBestIPv4ExcludesLoopback() {
        let interfaces = [
            LocalNetwork.Interface(name: "lo0", address: "127.0.0.1"),
            LocalNetwork.Interface(name: "en0", address: "192.168.1.20"),
        ]
        XCTAssertEqual(LocalNetwork.bestIPv4(from: interfaces), "192.168.1.20")
    }

    func testBestIPv4FallsBackToFirstNonLoopback() {
        let interfaces = [
            LocalNetwork.Interface(name: "lo0", address: "127.0.0.1"),
            LocalNetwork.Interface(name: "utun0", address: "10.0.0.9"),
        ]
        XCTAssertEqual(LocalNetwork.bestIPv4(from: interfaces), "10.0.0.9")
    }

    func testBestIPv4EmptyReturnsNil() {
        XCTAssertNil(LocalNetwork.bestIPv4(from: []))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild test -scheme ShareLocalDir -destination 'platform=macOS' -only-testing:ShareLocalDirTests 2>&1 | tail -30
```
Expected: FAIL — `cannot find 'LocalNetwork' in scope`.

- [ ] **Step 3: Implement `LocalNetwork`**

Create `ShareLocalDir/net/LocalNetwork.swift`:

```swift
import Foundation
import Darwin

nonisolated enum LocalNetwork {
    struct Interface: Equatable {
        let name: String
        let address: String
    }

    /// Enumerate active, non-loopback IPv4 interfaces.
    static func ipv4Addresses() -> [Interface] {
        var results: [Interface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            let addrPtr = cur.pointee.ifa_addr
            let flags = cur.pointee.ifa_flags
            if let addr = addrPtr,
               addr.pointee.sa_family == sa_family_t(AF_INET) {
                let isUp = (flags & UInt32(IFF_UP)) != 0
                let isRunning = (flags & UInt32(IFF_RUNNING)) != 0
                let isLoopback = (flags & UInt32(IFF_LOOPBACK)) != 0
                if isUp && isRunning && !isLoopback {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let len = socklen_t(addr.pointee.sa_len)
                    if getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        results.append(Interface(name: String(cString: cur.pointee.ifa_name),
                                                 address: String(cString: host)))
                    }
                }
            }
            cursor = cur.pointee.ifa_next
        }
        return results
    }

    /// Pure: pick the best LAN IPv4 from a candidate list — prefer `en*`, exclude loopback.
    static func bestIPv4(from interfaces: [Interface]) -> String? {
        let candidates = interfaces.filter { !$0.address.hasPrefix("127.") }
        if let en = candidates.first(where: { $0.name.hasPrefix("en") }) {
            return en.address
        }
        return candidates.first?.address
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
xcodebuild test -scheme ShareLocalDir -destination 'platform=macOS' -only-testing:ShareLocalDirTests 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **` (all LocalNetwork tests pass).

- [ ] **Step 5: Commit**

```bash
git add ShareLocalDir/net/LocalNetwork.swift ShareLocalDirTests/ShareLocalDirTests.swift
git commit -m "feat: add LocalNetwork IPv4 detection with tests"
```

---

## Task 9: `HTTPFileHandler` (build-verified)

The SwiftNIO `ChannelInboundHandler`. Uses the helpers from Tasks 4–7. Verified by compiling; runtime behavior is checked in Task 16.

> **Before this task:** `import NIOHTTP1` requires the `NIOHTTP1` product linked **separately** — the `NIO` umbrella product only contains the `NIO` target (which re-exports `NIOCore`/`NIOPosix`), not `NIOHTTP1`. Add a second `XCSwiftPackageProductDependency` (`productName = NIOHTTP1`, same package ref), a `PBXBuildFile` (`NIOHTTP1 in Frameworks`), a frameworks-phase entry, and a reference in the target's `packageProductDependencies` — mirroring the `NIO` entries from Task 1.

**Files:**
- Create: `ShareLocalDir/server/HTTPFileHandler.swift`

- [ ] **Step 1: Implement the handler**

Create `ShareLocalDir/server/HTTPFileHandler.swift`:

```swift
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

nonisolated final class HTTPFileHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let rootURL: URL
    private let fileIO: NonBlockingFileIO
    private var pendingHead: HTTPRequestHead?

    init(rootURL: URL, fileIO: NonBlockingFileIO) {
        self.rootURL = rootURL
        self.fileIO = fileIO
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.pendingHead = head
        case .body:
            break
        case .end:
            handle(context: context)
        }
    }

    func channelUnregistered(context: ChannelHandlerContext) {
        pendingHead = nil
    }

    private func handle(context: ChannelHandlerContext) {
        guard let head = pendingHead else {
            respondStatus(context, status: .badRequest)
            return
        }
        pendingHead = nil

        guard head.method == .GET else {
            respondStatus(context, status: .methodNotAllowed, extraHeaders: ["Allow": "GET"])
            return
        }

        switch PathResolver.resolve(relativePath: head.uri, root: rootURL) {
        case .failure(.forbidden):
            respondStatus(context, status: .forbidden)
        case .failure(.notFound):
            respondStatus(context, status: .notFound)
        case .success(let url):
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                serveDirectory(context: context, head: head, url: url)
            } else {
                serveFile(context: context, head: head, url: url)
            }
        }
    }

    // MARK: Directory listing

    private func serveDirectory(context: ChannelHandlerContext, head: HTTPRequestHead, url: URL) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            respondStatus(context, status: .forbidden)
            return
        }

        var entries: [DirectoryEntry] = []
        for item in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            entries.append(DirectoryEntry(
                name: item.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0),
                modificationDate: values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            ))
        }

        let title = rootURL.path == url.path ? "/" : url.lastPathComponent
        let body = DirectoryIndex.html(title: title, entries: entries, requestPath: head.uri)
        let bytes = Array(body.utf8)
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/html; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(bytes.count)")
        respond(context, status: .ok, headers: headers, body: buffer)
    }

    // MARK: File serving (streamed, with Range)

    private func serveFile(context: ChannelHandlerContext, head: HTTPRequestHead, url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let total = (attrs[.size] as? NSNumber)?.int64Value else {
            respondStatus(context, status: .notFound)
            return
        }

        let range = RangeParser.parse(head.headers.first(name: "Range") ?? "", total: total)
        let start: Int64 = range?.start ?? 0
        let endInclusive: Int64 = range?.end ?? (total - 1)
        let length = Int(endInclusive - start + 1)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: MimeTypeMap.contentType(for: url))
        headers.add(name: "Content-Length", value: "\(length)")
        headers.add(name: "Accept-Ranges", value: "bytes")
        if range != nil {
            headers.add(name: "Content-Range", value: "bytes \(start)-\(endInclusive)/\(total)")
        }
        let status: HTTPResponseStatus = range == nil ? .ok : .partialContent
        let responseHead = HTTPResponseHead(version: .http1_1, status: status, headers: headers)

        let allocator = context.channel.allocator
        let eventLoop = context.eventLoop
        let fileIO = self.fileIO
        let owner = self

        fileIO.openFile(path: url.path, eventLoop: eventLoop)
            .flatMap { (handle, _) -> EventLoopFuture<Void> in
                context.write(owner.wrapOutboundOut(.head(responseHead))).flatMap { _ -> EventLoopFuture<Void> in
                    fileIO.readChunked(
                        fileHandle: handle,
                        fromOffset: start,
                        byteCount: length,
                        allocator: allocator,
                        eventLoop: eventLoop
                    ) { chunk -> EventLoopFuture<Void> in
                        context.writeAndFlush(owner.wrapOutboundOut(.body(.byteBuffer(chunk))))
                    }
                }.flatMap { _ -> EventLoopFuture<Void> in
                    context.writeAndFlush(owner.wrapOutboundOut(.end(nil)))
                }.always { _ in
                    try? handle.close()
                    context.close(promise: nil)
                }
            }
            .whenFailure { _ in
                // Only reached if openFile itself failed (we had not written any head yet).
                owner.respondStatus(context, status: .notFound)
            }
    }

    // MARK: Response helpers

    private func respond(_ context: ChannelHandlerContext,
                         status: HTTPResponseStatus,
                         headers: HTTPHeaders,
                         body: ByteBuffer) {
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }

    private func respondStatus(_ context: ChannelHandlerContext,
                               status: HTTPResponseStatus,
                               extraHeaders: [String: String] = [:]) {
        var headers = HTTPHeaders()
        for (k, v) in extraHeaders { headers.add(name: k, value: v) }
        let text = "\(status.code) \(status.reasonPhrase)\n"
        var buf = context.channel.allocator.buffer(capacity: text.utf8.count)
        buf.writeString(text)
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(text.utf8.count)")
        respond(context, status: status, headers: headers, body: buf)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run:
```bash
xcodebuild -scheme ShareLocalDir -configuration Debug build 2>&1 | tail -30
```
Expected: `** BUILD SUCCEEDED **`. If the compiler flags an NIO signature mismatch (e.g. `readChunked`/`openFile`/`configureHTTPServerPipeline`), cross-check against the resolved source in `~/Library/Developer/Xcode/DerivedData/ShareLocalDir-*/SourcePackages/checkouts/swift-nio` and adjust — the confirmed shapes are: `openFile(path:eventLoop:) -> EventLoopFuture<(NIOFileHandle, FileRegion)>`, `readChunked(fileHandle:fromOffset:byteCount:chunkSize:allocator:eventLoop:chunkHandler:)`, `configureHTTPServerPipeline() -> EventLoopFuture<Void>`.

- [ ] **Step 3: Commit**

```bash
git add ShareLocalDir/server/HTTPFileHandler.swift
git commit -m "feat: add HTTPFileHandler (directory listing + streamed file serving)"
```

---

## Task 10: `FileShareServer` — bootstrap, port fallback, lifecycle (build-verified)

Owns the `MultiThreadedEventLoopGroup`, `NIOThreadPool`, and the bound `Channel`. Port fallback 7321 → +1 … up to 7321+49.

**Files:**
- Create: `ShareLocalDir/server/FileShareServer.swift`

- [ ] **Step 1: Implement the server**

Create `ShareLocalDir/server/FileShareServer.swift`:

```swift
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

enum FileShareError: Error, LocalizedError {
    case noPortAvailable(first: Int, attempted: Int)
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .noPortAvailable(let first, let n):
            return "端口 \(first)–\(first + n - 1) 均被占用，未能启动服务器。"
        case .alreadyRunning:
            return "服务器已在运行。"
        }
    }
}

nonisolated final class FileShareServer: @unchecked Sendable {
    static let defaultPort = 7321
    static let defaultMaxAttempts = 50

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    private let threadPool: NIOThreadPool
    private let fileIO: NonBlockingFileIO
    private var channel: Channel?

    private(set) var boundHost: String = "0.0.0.0"
    private(set) var boundPort: Int = 0

    var isRunning: Bool { channel != nil }

    init() {
        let pool = NIOThreadPool(numberOfThreads: 6)
        pool.start()
        self.threadPool = pool
        self.fileIO = NonBlockingFileIO(threadPool: pool)
    }

    deinit {
        try? group.syncShutdownGracefully()
        try? threadPool.syncShutdownGracefully()
    }

    func start(rootURL: URL,
               host: String = "0.0.0.0",
               preferredPort: Int = FileShareServer.defaultPort,
               maxAttempts: Int = FileShareServer.defaultMaxAttempts) async throws {
        guard channel == nil else { throw FileShareError.alreadyRunning }
        let normalizedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let bootstrap = makeBootstrap(rootURL: normalizedRoot)

        var lastError: Error?
        for attempt in 0..<maxAttempts {
            let port = preferredPort + attempt
            do {
                let ch = try await bootstrap.bind(host: host, port: port).asyncValue()
                self.channel = ch
                self.boundHost = host
                self.boundPort = port
                return
            } catch {
                lastError = error
            }
        }
        throw FileShareError.noPortAvailable(first: preferredPort, attempted: maxAttempts)
    }

    func stop() async {
        if let ch = channel {
            channel = nil
            try? await ch.close().asyncValue()
        }
    }

    private func makeBootstrap(rootURL: URL) -> ServerBootstrap {
        let fileIO = self.fileIO
        return ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPFileHandler(rootURL: rootURL, fileIO: fileIO))
                }
            }
    }
}

nonisolated extension EventLoopFuture {
    /// Bridge an `EventLoopFuture` to async/await.
    func asyncValue() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            whenComplete { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run:
```bash
xcodebuild -scheme ShareLocalDir -configuration Debug build 2>&1 | tail -30
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ShareLocalDir/server/FileShareServer.swift
git commit -m "feat: add FileShareServer (bootstrap, port fallback, lifecycle)"
```

---

## Task 11: `QRCodeImage` + `BookmarkStore` (build-verified)

**Files:**
- Create: `ShareLocalDir/qr/QRCodeImage.swift`
- Create: `ShareLocalDir/storage/BookmarkStore.swift`

- [ ] **Step 1: Implement `QRCodeImage`**

Create `ShareLocalDir/qr/QRCodeImage.swift`:

```swift
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum QRCodeImage {
    static func make(from string: String, pixelsPerModule: CGFloat = 10) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: pixelsPerModule, y: pixelsPerModule))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
```

- [ ] **Step 2: Implement `BookmarkStore`**

Create `ShareLocalDir/storage/BookmarkStore.swift`:

```swift
import Foundation

enum BookmarkStore {
    private static let key = "selectedFolderBookmark"

    static func save(url: URL) {
        if let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            clear()
            return nil
        }
        if stale { save(url: url) }
        return url
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run:
```bash
xcodebuild -scheme ShareLocalDir -configuration Debug build 2>&1 | tail -30
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add ShareLocalDir/qr/QRCodeImage.swift ShareLocalDir/storage/BookmarkStore.swift
git commit -m "feat: add QRCodeImage and BookmarkStore"
```

---

## Task 12: `AppState` — the `@Observable` view model (build-verified)

MainActor-isolated (default). Owns the server and drives UI state.

**Files:**
- Create: `ShareLocalDir/AppState.swift`

- [ ] **Step 1: Implement `AppState`**

Create `ShareLocalDir/AppState.swift`:

```swift
import Foundation
import Observation

@Observable
final class AppState {
    var selectedFolderURL: URL?
    var isRunning: Bool = false
    var serverURL: URL?
    var statusText: String = "未运行"
    var errorMessage: String?

    private let server = FileShareServer()
    private var scopedFolder: URL?

    init() {
        if let saved = BookmarkStore.load(), FileManager.default.fileExists(atPath: saved.path) {
            self.selectedFolderURL = saved
        }
    }

    func chooseFolder(_ url: URL) {
        if let previous = scopedFolder {
            previous.stopAccessingSecurityScopedResource()
            scopedFolder = nil
        }
        selectedFolderURL = url
        BookmarkStore.save(url: url)
        errorMessage = nil
    }

    func start() async {
        guard !isRunning else { return }
        guard let folder = selectedFolderURL else {
            errorMessage = "请先选择一个要分享的目录。"
            return
        }
        errorMessage = nil
        statusText = "启动中…"

        let acquired = folder.startAccessingSecurityScopedResource()
        do {
            try await server.start(rootURL: folder, preferredPort: FileShareServer.defaultPort)
            let ip = LocalNetwork.bestIPv4(from: LocalNetwork.ipv4Addresses()) ?? "127.0.0.1"
            if ip == "127.0.0.1" {
                errorMessage = "未检测到局域网 IPv4 地址，将使用 127.0.0.1（仅本机可访问）。"
            }
            var components = URLComponents()
            components.scheme = "http"
            components.host = ip
            components.port = server.boundPort
            serverURL = components.url
            scopedFolder = acquired ? folder : nil
            isRunning = true
            statusText = "运行中 · 端口 \(server.boundPort)"
        } catch {
            if acquired { folder.stopAccessingSecurityScopedResource() }
            scopedFolder = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusText = "未运行"
            isRunning = false
        }
    }

    func stop() async {
        await server.stop()
        isRunning = false
        serverURL = nil
        statusText = "未运行"
        if let folder = scopedFolder {
            folder.stopAccessingSecurityScopedResource()
            scopedFolder = nil
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run:
```bash
xcodebuild -scheme ShareLocalDir -configuration Debug build 2>&1 | tail -30
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ShareLocalDir/AppState.swift
git commit -m "feat: add AppState observable view model"
```

---

## Task 13: `StatusItemController` — menu-bar status item (build-verified)

**Files:**
- Create: `ShareLocalDir/StatusItemController.swift`

- [ ] **Step 1: Implement the controller**

Create `ShareLocalDir/StatusItemController.swift`:

```swift
import AppKit

final class StatusItemController: NSObject {
    private let appState: AppState
    private var statusItem: NSStatusItem?
    private var iconTimer: Timer?

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshIcon()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIcon() }
        }
        RunLoop.main.add(timer, forMode: .common)
        iconTimer = timer
    }

    deinit {
        iconTimer?.invalidate()
    }

    @MainActor
    private func refreshIcon() {
        statusItem?.button?.title = appState.isRunning ? "●" : "○"
        statusItem?.button?.toolTip = "ShareLocalDir · \(appState.statusText)"
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = menu.addItem(withTitle: "ShareLocalDir", action: nil, keyEquivalent: "")
        header.isEnabled = false

        if let url = appState.serverURL {
            menu.addItem(.separator())
            menu.addItem(withTitle: "复制地址", action: #selector(copyAddress), keyEquivalent: "c").target = self
            menu.addItem(withTitle: "在浏览器打开", action: #selector(openInBrowser), keyEquivalent: "").target = self
            menu.addItem(withTitle: url.absoluteString, action: nil, keyEquivalent: "").isEnabled = false
        }

        menu.addItem(.separator())
        let toggleTitle = appState.isRunning ? "停止" : "启动"
        menu.addItem(withTitle: toggleTitle, action: #selector(toggleRunning), keyEquivalent: "").target = self
        menu.addItem(withTitle: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 ShareLocalDir", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func copyAddress() {
        guard let url = appState.serverURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func openInBrowser() {
        guard let url = appState.serverURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleRunning() {
        Task {
            if appState.isRunning { await appState.stop() } else { await appState.start() }
        }
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.isWindowSelectable {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run:
```bash
xcodebuild -scheme ShareLocalDir -configuration Debug build 2>&1 | tail -30
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ShareLocalDir/StatusItemController.swift
git commit -m "feat: add menu-bar status item controller"
```

---

## Task 14: `ContentView` — main window UI (build-verified)

Replaces the template. Directory picker, status, URL + copy + open-in-browser + QR, start/stop button.

**Files:**
- Modify: `ShareLocalDir/ContentView.swift` (replace entire contents)

- [ ] **Step 1: Replace `ContentView.swift`**

Overwrite `ShareLocalDir/ContentView.swift` with:

```swift
import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            directoryRow

            Divider()

            statusRow

            if let url = appState.serverURL {
                urlRow(url: url)
            }

            if let message = appState.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(appState.isRunning ? "停止" : "启动") {
                    Task {
                        if appState.isRunning { await appState.stop() } else { await appState.start() }
                    }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(appState.selectedFolderURL == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 380)
    }

    private var directoryRow: some View {
        HStack(spacing: 12) {
            Text("共享目录").font(.headline)
            Text(appState.selectedFolderURL?.path ?? "未选择")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("选择…") { chooseFolder() }
                .disabled(appState.isRunning)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appState.isRunning ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
            Text(appState.statusText)
                .foregroundStyle(.secondary)
        }
    }

    private func urlRow(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(url.absoluteString)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button(copied ? "已复制" : "复制") { copy(url) }
                Button("在浏览器打开") { NSWorkspace.shared.open(url) }
            }
            if let qr = QRCodeImage.make(from: url.absoluteString) {
                Image(nsImage: qr)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 150, height: 150)
                    .accessibilityLabel("访问地址二维码")
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "分享"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.chooseFolder(url)
    }

    private func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
```

- [ ] **Step 2: Verify it compiles**

Run:
```bash
xcodebuild -scheme ShareLocalDir -configuration Debug build 2>&1 | tail -30
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ShareLocalDir/ContentView.swift
git commit -m "feat: implement main-window ContentView"
```

---

## Task 15: Wire `ShareLocalDirApp` — app delegate + status item + state (build-verified)

**Files:**
- Modify: `ShareLocalDir/ShareLocalDirApp.swift` (replace entire contents)

- [ ] **Step 1: Replace `ShareLocalDirApp.swift`**

Overwrite `ShareLocalDir/ShareLocalDirApp.swift` with:

```swift
import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = StatusItemController(appState: appState)
        item.install()
        statusItem = item
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Best-effort graceful shutdown. The OS reclaims the listening port on exit regardless,
        // so we don't block terminate (blocking main + a MainActor async stop would deadlock).
        Task { await appState.stop() }
    }
}

@main
struct ShareLocalDirApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appDelegate.appState)
        }
    }
}
```

- [ ] **Step 2: Verify Debug build + tests still pass**

Run:
```bash
xcodebuild -scheme ShareLocalDir -configuration Debug build 2>&1 | tail -25
```
Expected: `** BUILD SUCCEEDED **`.

Run:
```bash
xcodebuild test -scheme ShareLocalDir -destination 'platform=macOS' -only-testing:ShareLocalDirTests 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ShareLocalDir/ShareLocalDirApp.swift
git commit -m "feat: wire AppDelegate, status item, and AppState into the app"
```

---

## Task 16: Release build + manual integration verification

**Files:** none (verification + run).

- [ ] **Step 1: Build Release**

Run:
```bash
xcodebuild -scheme ShareLocalDir -configuration Release build 2>&1 | tail -25
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Launch the app**

Run:
```bash
APP=$(xcodebuild -scheme ShareLocalDir -configuration Debug -showBuildSettings 2>/dev/null | awk '/BUILT_PRODUCTS_DIR/{print $3}' | head -1)/ShareLocalDir.app
open "$APP"
```
Expected: the main window appears; a menu-bar item (●/○) appears.

- [ ] **Step 3: Manual checklist (perform in the running app)**

- Click **选择…**, pick a folder with a mix of files and subfolders. The folder path shows.
- Click **启动**. The status dot turns green, `http://<LAN-IP>:7321` appears with a QR code.
- In a browser (same machine or another device on the LAN) open the URL → directory listing renders; click a file → it downloads; click a subfolder → it lists.
- Click **复制**, paste somewhere → the URL.
- Click **在浏览器打开** → default browser opens the URL.
- Click the menu-bar item → menu shows the address, **复制地址**, **在浏览器打开**, **停止**, **显示主窗口**, **退出**. **停止** stops the server (dot goes grey).
- Port fallback: from a terminal, hold port 7321 (`python3 -m http.server 7321`), then start the app server → it should bind 7322 and the displayed URL should end in `:7322`. Stop the python server afterwards.
- Path traversal check: in a browser request `http://<host>:<port>/../../../../etc/passwd` → must return `403 Forbidden`, not the file.
- Range check (optional): `curl -r 0-9 http://<host>:<port>/<file> -o part.bin` → `part.bin` is 10 bytes and the response status is `206`.

- [ ] **Step 4: Confirm there are no leftover source/template issues**

Run:
```bash
git status --short
```
Expected: clean working tree (everything committed across Tasks 1–15).

- [ ] **Step 5: Final commit (if any verification notes/fixes)**

If the manual run surfaced fixes, commit them:
```bash
git add -A
git commit -m "fix: adjustments from integration verification"
```
Otherwise, no commit needed — the feature is complete.

---

## Done criteria

- `xcodebuild build` (Debug + Release) and `xcodebuild test` all succeed.
- Selecting a directory and clicking 启动 serves it over HTTP on 0.0.0.0:<7321+n> with a LAN-IP URL.
- Directory listing, file download, range requests, and path-traversal rejection all work.
- Copy / open-in-browser / QR / menu-bar status item all work.
- All pure-logic units (`MimeTypeMap`, `PathResolver`, `RangeParser`, `DirectoryIndex`, `LocalNetwork.bestIPv4`) have passing unit tests.
