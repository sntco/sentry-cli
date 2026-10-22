# Sentry CLI development previews

This repository hosts the public preview website, installer and prebuilt release assets for the separate `sentry` CLI. It does not contain the Sentry app, vaults or private app source.

See [installation and usage](https://sntco.github.io/sentry-cli/) and [versioned preview releases](https://github.com/sntco/sentry-cli/releases). The CLI requires Apple silicon, macOS 27 or later and a matching Sentry development app. It is ad-hoc signed, not Developer ID signed or notarized. Production App Store communication remains separately unqualified. Installing the prebuilt CLI requires neither Swift nor Xcode; obtaining the current development app is a separate prerequisite.

Install with one command:

```sh
curl -fsSL https://sntco.github.io/sentry-cli/install.sh | bash
```

The installer selects the current signed preview, installs in `~/.local/share/sentry-cli`, links `~/.local/bin/sentry`, configures zsh/bash PATH and registers a user updater at login/daily. Open a new terminal once if the current terminal cannot find `sentry`; a child process cannot change its parent shell environment. It requires no administrator password. The app is a separate prerequisite.

Use a saved token as an environment variable:

```sh
sentry run --env 'API_TOKEN=Hosting account/password' -- /absolute/path/to/command
```

Run sudo with your current macOS user's saved password:

```sh
sentry run --stdin 'Mac admin/password' -- \
  /usr/bin/sudo -S -k /usr/bin/id -u
```

Save that user's password in the “Mac admin” item. `-S` reads the password from stdin; `-k` requests fresh authentication. The example prints `0` when authorized; your user must have sudo permission. The password is consumed by sudo, so use this pattern for commands that need no further stdin. The CLI closes stdin after the saved bytes; sudo accepts a nonempty password ending at EOF ([upstream reader](https://github.com/sudo-project/sudo/blob/v1.9.17p2/src/tgetpass.c), [Apple source](https://github.com/apple-oss-distributions/sudo/blob/main/sudo/src/tgetpass.c)). This example was source-checked, not exercised against a real administrator password.

Or send a secure note to a script through standard input:

```sh
sentry run --stdin 'Deployment notes/note' -- /absolute/path/to/custom-script
```

The script must read standard input. The CLI sends the saved UTF-8 bytes without adding a newline. Replace the fictional item titles and command paths with your own. References use literal quoted names; spaces and percent signs are literal. Use `\/` for a slash inside a name and `\\` for a backslash. Unlock Sentry and approve access normally.

The updater verifies RSA/SHA256 publisher-signed channel metadata with its pinned key, checks expiry/revision/version and binds both installer and binary hashes. It verifies the ad-hoc code signature and architecture before activation. Immutable state generations switch binary, signed metadata and updater together; running commands retain their existing version. The initial curl command trusts this HTTPS site to deliver the installer and pinned public key. This is not Apple Developer ID signing or notarization.

Uninstall with `curl -fsSL https://sntco.github.io/sentry-cli/install.sh | bash -s -- --uninstall`. It removes verified CLI/updater generations, the user LaunchAgent and exact managed PATH blocks, preserving app/vault/unrelated shell contents. Unknown or edited files are preserved for inspection. Normal command failures preserve the active generation; unverified interruption/power-loss state is not silently repaired. There is no power-loss durability qualification or background update while logged out.

Release publishers upload immutable versioned assets plus the reviewed installer, then publish a signed `current.txt`/`current.sig` pair. Renew metadata before its expiry (maximum 30 days), with a strictly newer revision and unchanged same-version artifacts. Never publish the private signing key or operational evidence. Production App Store communication, Developer ID/notarization and clean-Mac qualification remain separate gates.


CLI builds, signing, tests and release preparation run on the project's approved local Mini. The owner explicitly permits GitHub Pages' built-in hosted deployment for this static site only. No public pull request is executed on the Mini through this repository.
