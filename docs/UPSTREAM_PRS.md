# Upstream pull requests (drafts)

Three small, independent changes prepared against [mangerlahn/Latest](https://github.com/mangerlahn/Latest) `main` (1301cf6). The fork `joshmans/Latest` exists with these three branches, and a comment offering each of the two feature changes was posted on issues #288 and #297 (2026-10-10). Pull requests opened 2026-10-11: [#605](https://github.com/mangerlahn/Latest/pull/605) (crash fix), [#606](https://github.com/mangerlahn/Latest/pull/606) (cask matching), [#607](https://github.com/mangerlahn/Latest/pull/607) (in-app update). Each branch is based directly on upstream's `main`, builds on its own, and merges with the other two without conflicts.

| Branch | Upstream issue | Tests added |
|---|---|---|
| `pr/fix-appdatastore-unowned-crash` | none (found via test crash) | 1 (crashes the test process without the fix) |
| `pr/homebrew-cask-bundle-id-matching` | [#297](https://github.com/mangerlahn/Latest/issues/297) | 4 |
| `pr/homebrew-in-app-update` | [#288](https://github.com/mangerlahn/Latest/issues/288) | 4 |

A fourth branch, `pr/source-badges`, is prepared but **not opened** (no issue exists for it, and the README asks for an issue first): it marks App Store and Homebrew apps in the update list with their source's icon (the App Store app's own icon, and a drawn Homebrew beer mug), with the source name as tooltip. Sparkle stays unmarked. `Source.sourceIcon` already referred to "appstore" and "brew" images that are not in the asset catalog; they are still looked up first, so artwork can replace the fallbacks. 3 tests. All four branches merge together cleanly (38 tests, the one known failure).

Test status on upstream's code: 25 tests before, all new tests pass; `VersionParserTest.testEmptyVersionParsing` fails on upstream `main` already (open upstream PR #596 addresses it). The test target only builds with the private-framework search paths passed on the command line (open upstream PR #595 addresses that); see this fork's README for the command.

The changes were written with Claude's help; say so in the PRs.

## How to open them

Pull requests need a fork in the same GitHub network, and `joshmans/latest-extended` is a standalone repository. So:

```bash
gh repo fork mangerlahn/Latest --clone=false
git remote add forkpr https://github.com/<you>/Latest.git
git push forkpr pr/fix-appdatastore-unowned-crash pr/homebrew-cask-bundle-id-matching pr/homebrew-in-app-update
```

The README asks for an issue or comment first. Suggested comments are below.

## Suggested issue comments

**On #288 (Update Homebrew-based updates within Latest):**
> I have a small implementation: when Homebrew already manages the cask (its folder exists in the Caskroom), the update button runs `brew upgrade --cask --greedy <token>` as a normal update operation. Apps not installed through Homebrew keep opening the app as today, so nothing is installed over an existing app. The token is validated before it reaches brew. Would you want a PR for this? It adds `HomebrewUpdateOperation` and passes the cask token through `UpdateRepository`.

**On #297 (False positives for Homebrew Casks):**
> Some false positives come from matching by file name only (for example `Studio.app` from BrickLink matched the unrelated `wordpresscom-studio` cask). I have a change that rejects a name-only match when the cask's known bundle identifiers conflict with the app's, and falls back to bundle-identifier matching (requiring the cask's name to resemble the app's) when the file name finds nothing. It comes with tests. Happy to open a PR if that direction is useful.

## PR text

### Fix crash when an AppDataStore is released with a notification pending
The scheduler's event handler captured `self` as `unowned`, runs on a background queue and sleeps after notifying observers. If the store is released in the meantime, the handler aborts in `swift_abortRetainUnowned`. The shared store lives for the whole process, so this mostly affects tests that create short-lived stores. The handler now captures `self` weakly and returns early. Adds a regression test that crashes the test process without the change (verified three times).

### Match Homebrew casks by bundle identifier and reject implausible name matches
See the commit message. Relates to #297. Tests cover: a renamed app matched by bundle identifier, the base cask preferred over variants (`zoom` over `zoom-for-it-admins`), bundle-identifier-only matches rejected without a resembling name (Safari, an unrelated app), and a generic-name match rejected on conflicting identifiers (`Studio.app`). Could interact with #584 (empty OS version strings), which touches the same area.

### Update Homebrew-managed apps from within Latest
See the commit message. Addresses #288. The new operation has not been run against a real cask update by an automated test; the tests cover detecting managed casks and validating tokens and arguments. Decision for the maintainer: it keeps `Source.supportState` for `.homebrew` as `.limited`, since not every Homebrew-matched app can be updated this way.


### Mark App Store and Homebrew apps in the update list (not opened yet)
Apps whose update information comes from the Mac App Store or Homebrew get that source's icon after their name in the list, with the source name as tooltip. Sparkle apps stay unmarked since they are the common case. `Source.sourceIcon` already referred to `appstore` and `brew` images that are not in the asset catalog; those are still looked up first, so you can drop in artwork. Until then the App Store app's own icon and a drawn Homebrew badge are used. Decision for the maintainer: whether Sparkle should be marked too, and whether to ship real artwork. Written with Claude's help.
