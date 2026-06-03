# Releasing ManyAgents

`Scripts/release.sh` builds, signs, notarizes, staples, packages, and
optionally publishes a downloadable DMG.

## One-time setup

1. **Install the tools** (Homebrew):

    ```sh
    brew install xcodegen create-dmg gh
    ```

    Optional but nice: `brew install xcbeautify` for prettier build logs.

2. **Confirm your signing cert is in the keychain.** The script expects
   the `AILOGY LLC (44KY89SZJD)` Developer ID — change `DEVELOPER_ID` /
   `TEAM_ID` at the top of `release.sh` if that's not you.

    ```sh
    security find-identity -v -p codesigning | grep "Developer ID Application"
    ```

3. **Stash an app-specific password for notarytool.** Generate one at
   <https://appleid.apple.com> → Sign-In and Security → App-Specific
   Passwords. Then save it to the keychain under the profile name the
   script looks for:

    ```sh
    xcrun notarytool store-credentials manyagents-notary \
        --apple-id "you@example.com" \
        --team-id  "44KY89SZJD"
    # paste the app-specific password when prompted
    ```

    That's a one-shot — the profile lives in the login keychain
    forever. Verify:

    ```sh
    xcrun notarytool history --keychain-profile manyagents-notary
    ```

4. **Authenticate `gh`** if you want `--publish` to upload to GitHub
   Releases:

    ```sh
    gh auth login
    ```

## Cutting a release

```sh
# local DMG only — useful for sanity-check before publishing
Scripts/release.sh 0.3.1

# build + tag + publish + attach DMG to a GitHub Release
Scripts/release.sh 0.3.1 --publish
```

What it does:

1. `xcodegen` regenerates the project.
2. `xcodebuild` Release build, signed with Developer ID + hardened
   runtime + secure timestamp.
3. Signature verified.
4. App zipped → notarytool submit → wait for Apple's verdict.
5. `xcrun stapler staple` so the ticket lives on the binary (works
   offline forever).
6. `create-dmg` produces `dist/ManyAgents-<version>.dmg`.
7. DMG itself signed, notarized, stapled.
8. *(if `--publish`)* tag pushed, `gh release create` uploads the DMG.

Total runtime: usually 4–8 minutes — notarization is the wait.

## After publishing

The DMG is now downloadable at

> https://github.com/stulogy/manyagents/releases/latest

Direct link to the asset:

> https://github.com/stulogy/manyagents/releases/latest/download/ManyAgents-&lt;version&gt;.dmg

The ailogy.co `/manyagents` landing page points at the `latest`
endpoint, so a new release goes live the moment `gh release create`
finishes — no website redeploy needed.

## Troubleshooting

| Symptom                                            | Fix                                                                                       |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `notarytool profile 'manyagents-notary' missing`   | Re-run step 3 above.                                                                      |
| Notarization rejected, mentions hardened runtime   | Already on — but a nested binary may need it too. Run `codesign -dvv` on each `.dylib`.   |
| Notarization rejected, mentions secure timestamp   | The script passes `--timestamp` — make sure you're online; the timestamp service is live. |
| Gatekeeper still blocks on someone else's Mac      | Check `xcrun stapler validate ManyAgents.app` returns `The validate action worked!`.      |
| `gh release create` fails with `tag already exists`| Bump the version, or delete the old tag with `git tag -d v<x> && git push --delete`.      |
