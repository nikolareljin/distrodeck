# CI

## Workflows

- `PR`: runs a lightweight check on pull requests.
- `Main`: builds Debian + RPM artifacts, optionally publishes PPA and Homebrew.

## Required GitHub Secrets

Set these in your GitHub repo settings:

- `PPA_GPG_PRIVATE_KEY`: armored private key for signing the source package.
- `PPA_GPG_PASSPHRASE`: passphrase for the signing key.
- `PPA_SSH_PRIVATE_KEY`: SSH key registered with Launchpad.
- `HOMEBREW_TAP_TOKEN`: GitHub token with push access to the tap repo.

## Required GitHub Variables

- `PPA_GPG_KEY_ID`: key ID or fingerprint for the signing key.
- `PPA_PUBLISH_ENABLED`: set to `true` to enable the PPA publish job.
- `HOMEBREW_PUBLISH_ENABLED`: set to `true` to enable Homebrew publishing.
- `HOMEBREW_TAP_REPO`: target tap repo (e.g., `nikolareljin/homebrew-tap`).
- `HOMEBREW_TAP_BRANCH`: optional (default `main`).

## PPA target

Update `ppa_target` in `.github/workflows/main.yml` to match your Launchpad PPA, for example:

```
ppa:your-launchpad-id/distrodeck
```

## Notes

- The distro series is taken from `debian/changelog`. Update it before publishing.
- The workflow regenerates the man page via `tools/gen-man.sh` before building.
- RPM and Homebrew artifacts use reusable `ci-helpers` workflows backed by `script-helpers`.
- CI invokes bootstrap wrapper scripts under `vendor/script-helpers` (from `ci-helpers`) which set up the actual `scripts/script-helpers` submodule.
