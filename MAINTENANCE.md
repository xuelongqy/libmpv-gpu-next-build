# Maintenance policy

This repository validates source combinations for the maintained libmpv
`gpu-next` OpenGL/GLES fork. It does not publish binary releases.

## Branch invariants

- The `master` branch in each source fork is a fast-forward mirror of its
  official upstream `master` branch.
- Published maintained branches are updated with merge commits. Do not rebase
  or force-push them.
- Immutable snapshot branches preserve the original downstream work. Do not
  move or rewrite them.
- Resolve only conflicts that intersect the downstream patches. Treat an
  unrelated upstream build or test failure as a separate upstream issue.

The branch names and exact commits used by the build are declared in
`versions.env`. Run `./scripts/release-check.sh --remote` before accepting a
new source combination.

## Upstream synchronization

For mpv and libplacebo, repeat this sequence independently:

1. Fetch the official upstream and fast-forward the fork's `master` with
   `git merge --ff-only`.
2. Push the fork `master` without force.
3. Merge that `master` into the maintained branch with a merge commit.
4. Resolve only conflicts in the downstream patch surface, then push without
   force.
5. Run the complete pinned build and platform validation before changing
   `versions.env`.

The weekly compatibility workflow performs these merges in temporary detached
checkouts and builds the result. It reports compatibility only; it never
updates either fork.

## Release sequence

1. Complete the source-fork synchronization above.
2. Run libplacebo tests, the complete mpv tests, the libmpv suite, the no-GL
   build, and ASan/UBSan.
3. Validate macOS SDR, HDR10, and Dolby Vision mapping, including the
   VideoToolbox rectangle-sampler path.
4. Validate Android arm64 SDR with `gpu` and `gpu-next`, HDR10/MediaCodec PQ,
   Dolby Vision Profile 5 to SDR/PQ, and the Surface lifecycle matrix.
5. Update `versions.env` and `VALIDATION.md`, then commit and push `main`.
6. Wait for pinned-source CI and manually dispatch upstream compatibility for
   the same `main` commit.
7. Run `./scripts/release-check.sh --remote`.
8. Create and push a new annotated `gpu-next-vX.Y.Z` tag, then run
   `./scripts/release-check.sh --remote --tag gpu-next-vX.Y.Z`.

Tags lock the `versions.env` source combination. They may point behind current
`main` when later commits only extend documentation or validation records.
Never move or delete a published tag, and never attach binary artifacts.

Use a patch release for upstream synchronization or compatibility fixes that
preserve the API. Reserve a minor release for an intentional new backend or
public capability. No breaking major release is planned.

## Retiring downstream patches

Do not remove a patch merely because upstream code looks similar. Create a
temporary branch without the downstream patch and repeat the complete build,
API error-path, screenshot, HDR metadata, hardware-decoding, and lifecycle
validation. Remove it from the maintained branch and `PATCHES.md` only when
the behavior is equivalent. Keep the immutable snapshot branch unchanged.

If a release check reports a network or tooling error, retry the check. Do not
change source pins to make an unavailable remote service appear compatible.
