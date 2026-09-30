Apple silicon (arm64) build for macOS 15 or later.

**Install**
1. Open `Splicewright.dmg` and drag Splicewright to Applications.
2. This build isn't notarized yet (that needs a paid Apple Developer account and is planned for M8), so macOS blocks the first launch. Open the app once, then go to **System Settings ▸ Privacy & Security** and click **Open Anyway**. Alternatively, run this in Terminal:
   `xattr -dr com.apple.quarantine /Applications/Splicewright.app`
