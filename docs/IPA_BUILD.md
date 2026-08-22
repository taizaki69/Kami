# Building the IPA

Kami targets sideloading first (mission §33). Two paths:

## Prerequisites (macOS)

- Xcode 15+ with an iOS SDK (`xcodebuild -version`)
- xcodegen (`brew install xcodegen`)
- For device signing: an Apple ID with a Development certificate and a
  provisioning profile that includes `app.kami.reader` (free personal teams
  work; app-signing-capable paid teams avoid the 7-day re-sign dance)

## Unsigned IPA (sign at install time)

```bash
bash scripts/bootstrap.sh          # generates Kami.xcodeproj via xcodegen
bash scripts/package_ipa.sh        # → dist/Kami.ipa (unsigned)
```

Install with Sideloadly / AltStore / SideStore / TrollStore — they apply
their own signing during installation.

## Signed IPA (development team)

```bash
bash scripts/package_ipa.sh <TEAM_ID>
# or: DEVELOPMENT_TEAM=<TEAM_ID> bash scripts/package_ipa.sh
```

`CODE_SIGN_STYLE=Automatic` + `DEVELOPMENT_TEAM` lets Xcode select the
identity/profile. No credentials are embedded in the repository; they live
in your keychain.

## Notes

- The simulator route (`bash scripts/build.sh simulator`) produces a `.app` for
  simulator use, not an installable IPA.
- No placeholder IPAs: `package_ipa.sh` fails loudly if the `.app` was not
  produced. GitHub Actions has exercised the unsigned generic-device build and
  uploaded the resulting `Kami-unsigned-ipa` artifact. A signed physical-device
  install remains intentionally user-owned.
