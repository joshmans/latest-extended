# Latest

[![Translation status][image-1]][1]

This is Latest, a small utility app for the Mac. Latest is a free and open-source app for macOS that checks if your apps are up to date. Get a quick overview of which apps changed and what changed and update them right away. Latest currently supports apps downloaded from the Mac App Store and those that use Sparkle for updates.

Latest is developed in my free time, so occasional updates may happen. Take a look at the [Issues][2] section to see what's coming. If you have an idea for a new feature, or encounter any bugs, feel free to open a new issue.
I am thankful for contributions. Check out the section below for more information.

![Latest][image-2]

## About this fork

This is a fork of [Latest](https://github.com/mangerlahn/Latest) by Max Langer, licensed under the same GPLv3. It is not affiliated with the original project. It was built for an Intel Mac where Homebrew no longer publishes prebuilt bottles for most formulae, so a plain `brew upgrade` compiles things from source. The upstream app is otherwise unchanged. What this fork adds:

**Apps**

- **Homebrew apps update in the app.** The update button for an app matched to a Homebrew cask runs `brew upgrade --cask --greedy`. Apps that were not installed through Homebrew are installed over the existing app with `brew install --cask --force`. Casks ship prebuilt apps, so nothing is compiled.
- **Better cask matching.** Latest matches an app to a cask by file name first. If that finds nothing, it falls back to matching the app's bundle identifier against the cask's cleanup lists, and only accepts a cask whose name also resembles the app. A name-only match is rejected when the cask's known identifiers conflict with the app's (for example, BrickLink's `Studio.app` is no longer matched to the unrelated WordPress.com Studio cask). Apple apps are never matched.
- **Mac App Store apps open the App Store.** The in-app App Store updater fails on current macOS ("The installation could not be started"), so the update button opens the App Store on the app's page. **Update All** also opens the App Store's Updates tab when any App Store app has an update. App Store apps stay in the default list.
- **No self-update to upstream.** The upstream Sparkle feed is removed from `Info.plist`, so this build will not replace itself with stock Latest.

**Command line packages** (File menu)

- **Package Updates** (⇧⌘P) lists outdated Homebrew formulae and MacPorts ports. Each row says whether it can be updated from a prebuilt binary or would be compiled from source. For Homebrew, that is decided from the formula's published bottles for this Mac's architecture and macOS version. For MacPorts, it is decided by whether a prebuilt archive for this Mac exists on `packages.macports.org`. Only prebuilt rows can be updated: Homebrew runs with `--force-bottle`, MacPorts with `port -b` (binary only, fails instead of compiling).
- **Prebuilt equivalents.** For a Homebrew formula that would be compiled, the window shows a prebuilt MacPorts equivalent if one exists, with its version. That version can be older than Homebrew's.
- **Switch to MacPorts** replaces Homebrew formulae with their MacPorts equivalents and keeps only the MacPorts copy. Everything that depends on a selected formula moves with it, as one group. The MacPorts ports are installed first and checked, and only then are the Homebrew formulae uninstalled, dependents first, with Homebrew's autoremove turned off so nothing unlisted is removed. A group is refused if any member has no prebuilt equivalent or if it contains more than 25 packages. If the local MacPorts index is out of date, it is refreshed first (`port selfupdate`).
- **MacPorts** (⇧⌘M) is a browser for MacPorts: search by name or description, browse by category, and list requested or all installed ports. The detail pane shows the description, license, dependencies, variants and whether a prebuilt archive exists for this Mac. You can install a prebuilt port, uninstall a port, or build one from source (behind a confirmation).

MacPorts changes need administrator rights, so the app shows the standard macOS password prompt when you install, uninstall, switch or refresh the MacPorts index.

**Limits**

- About a quarter of Homebrew casks use `version :latest`, which has no version number, so their apps cannot be checked for updates this way.
- The Package Updates and MacPorts windows only know what the local `brew` and `port` report. Run *Update Package Indexes* in the Package Updates window if the lists look stale.
- The switch was exercised end to end once (`deno` together with its dependent `yt-dlp`). The MacPorts window's install and uninstall buttons have been unit-tested for their parsing and safety checks but not run against a real port.
- Builds are not notarized. Build locally and sign ad hoc (`codesign --force --deep -s - Latest.app`).

**Building and testing**

Clone this repository and build as described below. The test target needs the private App Store framework paths passed on the command line:

```
xcodebuild -scheme Latest -derivedDataPath build CODE_SIGNING_ALLOWED=NO \
  SWIFT_INCLUDE_PATHS='$(SRCROOT)/Frameworks/CommerceKit $(SRCROOT)/Frameworks/StoreFoundation' \
  FRAMEWORK_SEARCH_PATHS='/System/Library/PrivateFrameworks $(PROJECT_DIR)/Frameworks' test
```

`VersionParserTest.testEmptyVersionParsing` fails on this codebase independently of the changes above.


## Installation

There are multiple ways to install the app.

### Download the App

The easiest way to install Latest is to [download][3] the latest release as an app. You unzip the download by double-clicking on it (if that does not happen automatically) and then move the `Latest.app` into the `Applications` folder.

If you would like to check out earlier versions, head over to the [Releases][4] page to browse the history of Latest.

### Homebrew Cask

Latest can also be installed via [Homebrew Cask][5]. If you have not installed Homebrew, follow the simple instructions [here][6].
After that, run `brew install --cask latest` to install the current version of Latest.

### Build from Source

**To build Latest, Xcode 11 and Swift 5 is required.**

You can build Latest directly on your machine. To do that, you have to download the source code by cloning the repository: `git clone --recurse-submodules git@github.com:joshmans/latest-extended.git`.

Then you can open the `Latest.xcodeproj` and hit *Build and Run*. Make sure that the `Latest` scheme is selected.

## Contribution

I am thankful for all contributions to the project. You can contribute typo-fixes, translations, code and of course suggestions, wishes, and bug reports.

### Translations

The text used in Latest is hosted by the kind people over at [Weblate][7]. If you would like to add a new language, or improve an existing one, [here][8] is your starting point.

[![Translation status][image-3]][9]

### Code

Take a look at the [Issues][10] section to see what you can do. If you have your own idea, and it does not appear in the issues list, please add it first. I don't think that I would reject any pull request, but it is useful to know about your idea earlier. Imagine two people have the same idea at the same time and both put a lot of work into that just to find out that someone else has made the same when it's too late.  

I would like to assign every issue to the person working on that particular thing, so if you would like to implement something, leave a small note in the issue. I will assign the issue to you and it's yours.

## Donation

As mentioned above, Latest is free for you to use. I work on the app in my spare time. If you would like to support the development by donating, you can do so [here][11].

[1]:	https://hosted.weblate.org/engage/latest/
[2]:	https://github.com/mangerlahn/latest/issues
[3]:	https://max.codes/latest/Latest.zip
[4]:	https://github.com/mangerlahn/Latest/releases
[5]:	https://github.com/Homebrew/homebrew-cask
[6]:	https://brew.sh
[7]:	https://weblate.org/
[8]:	https://hosted.weblate.org/engage/latest/
[9]:	https://hosted.weblate.org/engage/latest/
[10]:	https://github.com/mangerlahn/latest/issues
[11]:	https://max.codes/latest/donate

[image-1]:	https://hosted.weblate.org/widgets/latest/-/svg-badge.svg
[image-2]:	./latest.png
[image-3]:	https://hosted.weblate.org/widgets/latest/-/multi-auto.svg
