# Handoff: a standalone MacPorts UI

This document hands the MacPorts UI work to a fresh development session. It records what already exists in this repository (a fork of [Latest](https://github.com/mangerlahn/Latest)), what was learned, what is proven and what is not, and a proposed plan for a standalone app.

Date of writing: 2026-10-10. Everything below was exercised on an Intel MacBook Pro (x86_64) running macOS 26.7.1 with Homebrew 7.0.9 and MacPorts 2.12.6.

---

## 1. Why this exists

- Homebrew 7 reduces Intel Mac support. On the test machine, **133 of 138 outdated Homebrew formulae had no x86_64 bottle**, so `brew upgrade` compiles them from source (rust, qt, python, node, ffmpeg, openssl, git…).
- MacPorts still publishes **prebuilt archives for macOS 26 on Intel** (`darwin_25.x86_64`). 94 of those 133 formulae had a prebuilt MacPorts equivalent.
- I found **no maintained modern MacPorts GUI** (see section 8). Homebrew now ships an official one (BrewUI).

The standalone app's job: be to MacPorts what BrewUI is to Homebrew, with the extra angle of *prebuilt-first* behavior and moving packages over from Homebrew.

---

## 2. What already exists in this repo

Branch `main`, remote `origin` = `github.com/joshmans/latest-extended` (private), `upstream` = `mangerlahn/Latest`.

All package code is in `Latest/Model/Packages/`. Apart from the two window controllers (AppKit), it is Foundation-based with two exceptions: `PrivilegedHelper.swift` also uses ServiceManagement and Security, and `HomebrewPackageChecker.swift` reaches into Latest's `HomebrewUpdateOperation` to locate `brew`. Most of it can move into a Swift package nearly unchanged.

| File | What it does | Reusable as-is? |
|---|---|---|
| `PortAction.swift` | The **allow-list** of privileged `port` commands (`selfupdate`, `install`, `upgrade -b`, `uninstall`). Builds the argument vector and parses it back (`init?(arguments:)`). Validates names and variants. | Yes. Also compiled into the helper. |
| `HelperProtocol.swift` | XPC protocol, helper constants, code-signing requirement builder. | Yes (change identifiers). |
| `PrivilegedPort.swift` | `PrivilegedPortRunner` protocol, `PromptingPortRunner` (one `osascript` password prompt per batch, per-step exit markers), `PortPrivileges.runner` selection. | Yes. |
| `PrivilegedHelper.swift` | `SMAppService` registration, status, XPC client, `HelperPortRunner` with fallback to the prompt. | Yes (needs a signed build to run). |
| `CommandRunner.swift` | Synchronous `Process` runner, `osascript` admin runner, shell quoting. | Yes. |
| `MacPortsSupport.swift` | `MacPortsParser` (outdated/installed/variants/archive URLs/name mapping), `MacPortsPackageChecker` (check, equivalents, install, uninstall, index staleness), `Network` helpers. | Yes. |
| `MacPortsBrowsing.swift` | Parsers for `port search --line`, `port installed`, `port info --index`; variant validation; `PackageSwitch` planner (Homebrew → MacPorts with dependents). | Yes. |
| `PackageUpdate.swift` | Model (`PackageUpdate`, `State`, `Alternative`) and `PackageVersions` comparison. | Mostly (it has Homebrew concepts). |
| `HomebrewPackageChecker.swift` | Homebrew side: outdated formulae, bottle check for this Mac, reverse dependencies, safe uninstall. | Only needed for the "switch from Homebrew" feature. |
| `MacPortsWindowController.swift` | AppKit browser window (search, categories, installed/requested, detail, install/uninstall/build from source). | **No: rewrite in SwiftUI.** It is a working reference for behavior. |
| `PackagesWindowController.swift` | The Package Updates window (filters, sorting, Update All Ready, Switch to MacPorts). | Stays in Latest. |

Other relevant files:

- `Latest/Helper/main.swift` and `Latest/Helper/com.max-langer.Latest.helper.plist`: the privileged helper and its launch daemon plist.
- `scripts/build-release.sh`: builds the app, compiles the universal helper, embeds it, signs inside-out, optionally notarizes. Read its header for usage.
- `Tests/PackageUpdateTest.swift`: 36 unit tests (plus 4 in `UpdateRepositoryTest.swift` and 4 in `AppStoreUpdatesTest.swift` for the Latest side) covering the parsers, allow-list, planner, version comparison and batching.

---

## 3. How MacPorts is driven (verified commands and formats)

All run as the user unless noted. A "stale index" warning line starting `Warning: port definitions are more than two weeks old` is printed on stderr/stdout by most commands. **Filter lines starting with `Warning:`** before parsing.

| Need | Command | Output format |
|---|---|---|
| Search | `port search --line --glob '*term*'` | Tab separated: `name<TAB>version<TAB>categories (space separated)<TAB>description`. `No match for X found` when empty. |
| Browse a category | `port search --line --category net` | Same format (1,887 rows for `net`). `--category` and `--name` together do **not** combine: filter client side. |
| Installed | `port installed` / `port installed requested` | Lines like `  name @1.2.3_0+variant (active)`. Inactive versions have no `(active)`. |
| Outdated | `port outdated` | `name   3.14.1_0 < 3.15.1_0`, preceded by a header line. Depends on the **local index**. |
| Details | `port info --index --fullname --category --description --long_description --homepage --license --variants --depends_lib NAME` | `key: value` lines. |
| Variants | `port variants NAME` | Human readable; `[+]` marks default-on. |
| Local version | `port info --index --version --revision NAME` | `version: 2.9.6` / `revision: 0`. |
| Install (root) | `port -N -p -b install NAME [+variant …]` | `-N` non-interactive, `-p` continue after a failure, `-b` binary only (fail instead of compiling). |
| Upgrade (root) | `port -N -b upgrade NAME…` | |
| Uninstall (root) | `port -N uninstall NAME` | Refuses if dependents are installed. |
| Index refresh (root) | `port -N selfupdate` | |

### Prebuilt archives

- Directory listing: `https://packages.macports.org/<port>/` (HTML with `href`s).
- File name: `<port>-<version>_<revision><variants>.darwin_<N>.<arch>.tbz2`. `N` is the **Darwin** major version: **macOS 26 → 25** (use `uname -r`, not an arithmetic rule). `arch` is `x86_64` or `arm64`.
- **Pure scripts/Python ports are published as `darwin_any.noarch.tbz2`** and work everywhere. Missing these made `yt-dlp`, `pipx`, `poetry` and `streamlink` look unavailable. Always check both.
- Variants are part of the file name (`+ffmpeg+js_runtime+python314`). Archives exist only for the default variant set that the build farm uses.
- `HEAD` the file URL to test existence of a known version; fetch the directory listing to find the newest one.

### The stale-index trap

`port -b install` asks for the version in the **local** ports index. If the index is two weeks old, the wanted archive (e.g. `deno-2.9.6_0`) may no longer exist because the server only keeps the newest. The install then fails (safely, thanks to `-b`). Fix: run `port selfupdate` first. The code compares the server's newest archive with `port info --index --version --revision` (`MacPortsPackageChecker.portsWithOutdatedIndex`) and refreshes before installing. Any new app should check index age up front and offer the refresh.

### Name mapping Homebrew → MacPorts

Heuristic, in `MacPortsParser.candidateNames(forHomebrewFormula:)`: strip `@` and `.` (`python@3.13` → `python313`), drop `+` (`gtk+3` → `gtk3`), `python-tk@3.12` → `py312-tkinter`, `qtbase` → `qt6-qtbase`. It missed some real equivalents (for example `node` → `nodejs*`, `git`), so treat "none found" as "unknown".

---

## 4. Things that went wrong (so you do not repeat them)

1. **Three different "no prebuilt" false alarms**: wrong Darwin number, missing `noarch` archives, stale index. See section 3.
2. **`brew uninstall` auto-removes "unneeded" formulae** (it removed `deno` after `yt-dlp`). Removals now set `HOMEBREW_NO_AUTOREMOVE=1`, and "already gone" counts as success.
3. **`brew uses --installed` takes ~15 s per formula.** Build the reverse dependency map once from `brew info --json=v2 --installed --formula` (`installed[-1].runtime_dependencies[].full_name`).
4. **Passwords**: osascript's `with administrator privileges` prompts per invocation. Batch several `port` steps into one `sh -c` script and split results by marker lines (`@@LATEST-EXIT:<status>`). A hash of the password cannot authenticate, and an encrypted keyfile only moves the problem, so do not store passwords. Use the helper (section 6).
5. **Switching a tool you depend on mid-session**: switching `gh` could change the binary that reads the keychain login. Test switches on tools nothing else needs.
6. **The in-app App Store updater** (CommerceKit, private frameworks) fails on current macOS ("The installation could not be started"). Latest now opens the App Store page instead. This is unrelated to MacPorts but affects the Latest side.
7. **Tests run inside the app** (the test host is Latest itself). A test that writes to `UserDefaults` pollutes the real preferences; one test left a bogus ignored-app entry. Clean up with `addTeardownBlock`. A scheduler closure that captured `self` as `unowned` also crashed the test run; it is `weak` now.
8. **Project file edits**: Latest's `.xcodeproj` lists files explicitly. The new app should start from a fresh project or Swift package instead of patching `project.pbxproj`.

---

## 5. What is proven, and what is not

Proven on real packages:

- Switching Homebrew → MacPorts, including a dependent chain: `deno` + `yt-dlp` (installed MacPorts first, verified, removed brew dependents first), then `radare2` and `wget`.
- Prebuilt detection, equivalent lookup, outdated parsing, index-staleness detection, batching, version relation.
- 36 package unit tests for parsing, the allow-list (including rejection of injection-like arguments), planning and batching.

Not yet proven:

- *(Resolved)* **The helper's XPC path** was verified on 2026-10-10 with a Developer ID Application build (team `89DLSNZTCX`): the helper registered through `SMAppService`, was approved once in System Settings → General → Login Items & Extensions, and then `port -N -b upgrade graphite2` ran as root with no password prompt. Two findings to carry over: (1) `SMAppService.status` returns `.notFound` for a valid daemon that has never been registered, so do not treat it as "unavailable"; (2) `register()` throws "Operation not permitted" when the user still has to approve it, even though registration succeeded; check `status == .requiresApproval` instead of reporting an error. The Apple Development and Apple Distribution certificates were present but not valid for signing on that machine; Developer ID worked.
- The MacPorts window's **install, uninstall and build-from-source buttons** were never pressed against a real port (only the identical code path through the switch was).
- **Variant selection UI** does not exist beyond a text field.
- Notarization is scripted but untested.

Known unrelated failure: `VersionParserTest.testEmptyVersionParsing` fails in this codebase independently of this work.

---

## 6. Privileged access design

- Every privileged action is a `PortAction`; nothing else can run as root. The helper re-validates with `PortAction(arguments:)`.
- The helper is a launch daemon registered through `SMAppService.daemon(plistName:)`. The plist uses `BundleProgram` and `MachServices`; the helper binary is `Contents/MacOS/com.max-langer.Latest.helper`.
- **Both directions are verified by code signature**: the helper accepts only `identifier "com.max-langer.Latest"` signed by the same team; the app connects only to `identifier "com.max-langer.Latest.helper"` by the same team (`anchor apple generic and … certificate leaf[subject.OU] = "<TEAM>"`). The team identifier is baked into the helper at build time and read from the app's own signature at run time. Builds without a team never get helper access.
- Falls back to the password prompt whenever the helper is unavailable.
- Deployment target is macOS 10.15 but `SMAppService` needs macOS 13: the code is guarded with `#available`.
- Tradeoff to state in the UI: `port` runs Portfile code as root, so even an allow-list that is "only install and uninstall" lets a user-approved port run arbitrary build scripts. The helper protects against *other apps* calling it, not against malicious ports.

---

## 7. Proposed standalone app

**Name/identity:** pick a new bundle identifier. Do not reuse `com.max-langer.Latest`.

**Structure (new repo or a new top-level folder):**

```
MacPortsKit/              Swift package, no UI. Move/port the Foundation-only files above.
  Sources/MacPortsKit/    PortAction, parsers, archive checks, version compare, switch planner, runners
  Tests/MacPortsKitTests  Move the matching tests from Tests/PackageUpdateTest.swift
MacPortsUI/               SwiftUI macOS app (macOS 13+)
MacPortsHelper/           Privileged helper tool target (proper Xcode target + Copy Files phase)
```

**Screens (priority order):**

1. **Outdated** (the most valuable screen): per row ✓ prebuilt / ⚠︎ would compile, "Upgrade All (prebuilt)", index age with a refresh button.
2. **Installed**: requested vs dependency ports, inactive versions, uninstall, "leaves" view, disk usage.
3. **Browse/Search**: categories, search, port detail (variants, dependencies, license, homepage, *prebuilt availability for this Mac*).
4. **Install flow**: variant picker (checkboxes from `port variants`, conflicts handled), preview of dependencies that will be installed or compiled, "prebuilt only" default with an explicit "build from source" escape.
5. **Activity**: queue plus live log. The current helper returns output only at the end; stream it (an XPC callback object) for long builds.
6. **Homebrew migration** (optional): the existing `PackageSwitch` planner and `HomebrewPackageChecker`.

**Design rules carried over:**

- Prebuilt by default (`-b`); compiling is always an explicit, confirmed choice.
- One administrator prompt per user action.
- Never pass `--force`/`--ignore-dependencies` equivalents. Let MacPorts refuse and show why.
- Show version relations (older/newer than what you have) before any change.

**Useful things to investigate (not verified):**

- The MacPorts ports website has an API (`ports.macports.org`) that may offer search, install statistics and build status without parsing CLI output. Confirm it exists and its terms before relying on it.
- `port` has `-q` (quiet) and other machine-friendly options; check `man port`.
- Tcl API (`macports1.0`) is richer than the CLI but heavy to embed.

---

## 8. Landscape research (web, mid-October 2026)

Treat as leads, not facts. Search results were thin and some came from aggregator sites.

- **Porticus**: Cocoa GUI, first beta June 2007; last release 1.8.1 on 2009-12-31; not compatible with Lion or MacPorts 2.0. [macports-dev thread on reviving the source](https://lists.macosforge.org/pipermail/macports-dev/2012-February/017866.html).
- **Pallet**: the "official" GUI, started as GSoC 2009; the [MacPorts GUI wiki page](https://trac.macports.org/wiki/MacPortsGUI) says it is broken and not to install it (last edited 2021). [GSoC archive](https://trac.macports.org/wiki/SummerOfCodeArchive) shows a 2015 revival attempt that still failed to compile. A `Pallet 1.1` port still exists in the ports tree.
- **PortAuthority** (Kevin Walzer, shareware): newest release found was [7.7, October 2017](https://lists.macports.org/pipermail/macports-dev/2017-October/036659.html); [7.4 published MIT source](https://lists.macports.org/pipermail/macports-dev/2016-July/033203.html) that the author said he would not support. Whether it runs on macOS 26 is unconfirmed; check `codebykevin.com/portauthority.html`.
- **BrewUI** (Homebrew's official GUI): installed on the test machine as cask `homebrew-app` 0.5.0 from `github.com/Homebrew/BrewUI`. Coverage of Homebrew 7.0.0 ([BleepingComputer](https://www.bleepingcomputer.com/news/security/homebrew-700-gets-built-in-gui-better-security-controls/), [iThinkDiff](https://www.ithinkdiff.com/homebrew-7-0-0-intel-tier-3-brewui/)) also describes Intel support being reduced. Read brew.sh for the primary statement and exact dates.

---

## 9. Distribution checklist

- Apple Developer account: available to the project owner.
- Signing identity: create one in Xcode → Settings → Accounts → Manage Certificates. **Developer ID Application** is what worked for the helper test (`SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/build-release.sh`).
- Notarization: `xcrun notarytool store-credentials <profile>` once, then `NOTARY_PROFILE=<profile> scripts/build-release.sh`.
- Hardened runtime on, sandbox **off** (the app runs `port` and talks to a root helper).
- Sparkle or another updater for the new app's own updates; remember that in this fork the upstream Sparkle feed was removed on purpose.

---

## 10. Suggested first steps for the new session

1. Create the repository and a `MacPortsKit` Swift package; move the Foundation-only files and their tests; get `swift test` green.
2. Re-create the helper as a proper Xcode target with the same design (section 6); the first real XPC run is already proven with the scripted build.
3. Build the **Outdated** and **Installed** screens in SwiftUI on `MacPortsKit`.
4. Add Browse/Install with the variant picker and live log streaming.
5. Decide whether Latest depends on `MacPortsKit` (preferred) or keeps its copy; remove duplication either way.

### Testing safely

- Use ports that nothing else on the machine needs, such as `radare2` or `wget`. Avoid tools other tools rely on, such as `gh` (keychain access) or `bash` (shebang paths).
- Always install with `-b` first.
- After any switch, verify with `port installed NAME`, `brew list --formula | grep NAME`, `which -a NAME` and running the binary.
