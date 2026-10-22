# Sentry CLI development previews

This repository hosts the public preview website, installer and prebuilt release assets for the separate `sentry` CLI. It does not contain the Sentry app, vaults or private app source.

See [installation and usage](https://sntco.github.io/sentry-cli/) and [versioned preview releases](https://github.com/sntco/sentry-cli/releases). The CLI requires Apple silicon, macOS 27 or later and a matching Sentry development app. It is ad-hoc signed, not Developer ID signed or notarized. Production App Store communication remains separately unqualified. Installing the prebuilt CLI requires neither Swift nor Xcode; obtaining the current development app is a separate prerequisite.

`install.sh VERSION` installs or updates a preview in `~/.local/share/sentry-cli` and links it at `~/.local/bin/sentry`. `install.sh --uninstall` removes verified preview versions. The installer does not change PATH, install the app, access the vault, remove quarantine or disable Gatekeeper. There is no automatic updater yet.

SHA-256 checksums from the same HTTPS release detect download corruption; they are not independent publisher authentication. Release manifests identify source, toolchain, architecture, minimum OS and protocol. Report installation issues here without credentials, vault contents or private logs.

CLI builds, signing, tests and release preparation run on the project's approved local Mini. The owner explicitly permits GitHub Pages' built-in hosted deployment for this static site only. No public pull request is executed on the Mini through this repository.
