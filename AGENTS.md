# AudioReader repository instructions

## Versioning

- Use semantic application versions in `x.y.z` form.
- For every code or behavior fix/change, increment the patch component (`z`) exactly once before completion. Documentation-only or investigation-only work does not require a version bump.
- Keep `CFBundleShortVersionString` in the root `Info.plist` synchronized with `MARKETING_VERSION` for macOS and iPadOS Debug and Release configurations.
- Increment `CFBundleVersion` and every `CURRENT_PROJECT_VERSION` when the patch version changes.
- Run the version synchronization test and rebuild the affected app targets before reporting completion.
