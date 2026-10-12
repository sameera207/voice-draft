# Releasing voice-draft

Releases are cut by pushing a version tag. Everything else is automated.

1. Make sure `main` is green in CI.
2. Bump the version:

   ```sh
   echo 0.3.0 > VERSION
   git commit -am "Release 0.3.0"
   ```

3. Tag and push:

   ```sh
   git tag v0.3.0
   git push origin main v0.3.0
   ```

The `Release` workflow (`.github/workflows/release.yml`) then:

1. Fails if `VERSION` doesn't match the tag.
2. Runs the full CI suite.
3. Builds `voice-draft-<version>.tar.gz` with `git archive`.
4. Creates a GitHub Release with the tarball and generated notes.
5. Renders `packaging/homebrew/voice-draft.rb` with the version and sha256,
   and pushes it to
   [sameera207/homebrew-tap](https://github.com/sameera207/homebrew-tap).

Users get the new version on their next `voice-draft update`, or within a
day if they have `voice-draft autoupdate on`.

## One-time setup

The workflow pushes to the tap with an SSH deploy key that has write access
to `homebrew-tap` only:

- The public key is a deploy key on `sameera207/homebrew-tap`, with write
  access.
- The private key is the `TAP_DEPLOY_KEY` Actions secret on
  `sameera207/voice-draft`.

To rotate the key:

```sh
ssh-keygen -t ed25519 -N "" -C voice-draft-release -f tap_key
gh repo deploy-key add tap_key.pub --repo sameera207/homebrew-tap --allow-write --title release
gh secret set TAP_DEPLOY_KEY --repo sameera207/voice-draft < tap_key
rm tap_key tap_key.pub
```
