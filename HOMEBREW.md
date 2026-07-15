# Distributing FreeKit via Homebrew

This is the how-to for shipping FreeKit as a Homebrew **cask** (casks install
`.app` bundles; formulae are for CLI tools). It covers the one real blocker —
code signing — and the exact steps once that's decided.

## The signing reality (read this first)

`build.sh` signs the app with a **self-signed "FreeSpeech Dev"** identity and
does **not notarize** it (`codesign -dv` shows `TeamIdentifier=not set`). macOS
Gatekeeper quarantines anything downloaded from the internet, and for an
un-notarized app that means **first launch is blocked** ("can't be opened
because Apple cannot check it for malicious software").

Homebrew adds the quarantine flag to cask downloads by default, so this affects
`brew install --cask` too. There are two ways to live with it:

| Path | User experience | What it costs you |
|---|---|---|
| **A. Ship un-notarized** (now) | Works, but users must install with `--no-quarantine`, or right-click→Open once | Free |
| **B. Notarize** (proper fix) | Clean `brew install --cask freekit`, no flags, no warning | Apple Developer Program ($99/yr) + a Developer ID cert |

Everything below works today via **Path A**. The "Notarization" section at the
end is what upgrades you to Path B later — no cask changes needed except
dropping the `--no-quarantine` note.

## Which tap

- **Official `homebrew/cask`** — not an option yet. It requires the app be
  notable (stars/forks/watchers thresholds), **notarized**, and versioned with a
  stable download. Revisit only after Path B.
- **Your own tap: `cifyr/homebrew-freekit`** — the right choice for a solo
  project. Users add the tap once, then `brew` treats it like any other cask
  (install, upgrade, uninstall, zap). This is what the steps below set up.

## One-time setup

### 1. Cut a GitHub Release with the app zip

The cask downloads a zip of `FreeKit.app` (not the `install.command` share zip).
`build.sh` + the packaging step already produce it:

```bash
./build.sh                       # release build (fetches the model on first run)
( cd dist && ditto -c -k --keepParent FreeKit.app FreeKit.zip )
shasum -a 256 dist/FreeKit.zip   # copy this into the cask's sha256

VERSION=0.1.0
gh release create "v$VERSION" dist/FreeKit.zip \
  --title "FreeKit v$VERSION" \
  --notes "See README for what's included."
```

`ditto` (not `zip`) preserves the code signature and bundle structure.

### 2. Create the tap repo

A Homebrew tap is just a GitHub repo named `homebrew-<tap>` with a `Casks/` dir:

```bash
# from an empty dir
gh repo create cifyr/homebrew-freekit --public -y
git clone https://github.com/cifyr/homebrew-freekit
mkdir -p homebrew-freekit/Casks
cp packaging/freekit.rb homebrew-freekit/Casks/freekit.rb   # from this repo
# edit Casks/freekit.rb: set version + paste the sha256 from step 1
cd homebrew-freekit && git add Casks/freekit.rb \
  && git commit -m "freekit 0.1.0" && git push
```

The ready-to-copy cask lives at [`packaging/freekit.rb`](packaging/freekit.rb)
in this repo. Keep it in sync there so the source of truth is versioned with the app.

### 3. Users install

```bash
brew tap cifyr/freekit
brew install --cask --no-quarantine freekit     # --no-quarantine until notarized
```

`brew tap cifyr/freekit` resolves to `github.com/cifyr/homebrew-freekit`
automatically. Upgrades are `brew upgrade --cask freekit`; full removal is
`brew uninstall --zap --cask freekit` (the cask's `zap` stanza also clears
`~/Library/Application Support/FreeKit`, prefs, and caches).

## Cutting a new version

1. `./build.sh` → `ditto` the app → `shasum -a 256 dist/FreeKit.zip`.
2. `gh release create vX.Y.Z dist/FreeKit.zip ...`.
3. Bump `version` and `sha256` in both `packaging/freekit.rb` (this repo) and
   `Casks/freekit.rb` (the tap), commit, push the tap.

Homebrew compares the download's sha256 against the cask, so the release zip and
the cask's `sha256` must match exactly — regenerate the hash every release.

## Notarization (Path B, the proper fix)

Once you have an Apple Developer account:

1. Create a **Developer ID Application** certificate in the Apple Developer
   portal and install it in your login keychain.
2. Re-sign the app with it and the hardened runtime, replacing the self-signed
   step in `build.sh`:
   `codesign --deep --force --options runtime --timestamp \
     --sign "Developer ID Application: Your Name (TEAMID)" dist/FreeKit.app`
   (Note: on-device FoundationModels/whisper may need entitlements — audit with
   `codesign -d --entitlements :-`.)
3. Notarize and staple:
   ```bash
   ditto -c -k --keepParent dist/FreeKit.app dist/FreeKit.zip
   xcrun notarytool submit dist/FreeKit.zip \
     --apple-id you@example.com --team-id TEAMID --password <app-specific-pw> --wait
   xcrun stapler staple dist/FreeKit.app
   ```
4. Re-zip the stapled app for the release. Now drop `--no-quarantine` from the
   install instructions — the cask itself needs no change.

Until then, Path A (the `--no-quarantine` install) is the supported route.
