# CI

## Workflows

- `PR`: runs a lightweight check on pull requests.
- `Main`: builds a Debian package artifact and uploads to the PPA on `main`.

## Required GitHub Secrets

Set these in your GitHub repo settings:

- `PPA_GPG_PRIVATE_KEY`: armored private key for signing the source package.
- `PPA_GPG_PASSPHRASE`: passphrase for the signing key.
- `PPA_GPG_KEY_ID`: key ID or fingerprint for the signing key.
- `PPA_SSH_PRIVATE_KEY`: SSH key registered with Launchpad.

## PPA target

Update `ppa_target` in `.github/workflows/main.yml` to match your Launchpad PPA, for example:

```
ppa:your-launchpad-id/distrodeck
```

## Notes

- The distro series is taken from `debian/changelog`. Update it before publishing.
- The workflow regenerates the man page via `make man` before building.
