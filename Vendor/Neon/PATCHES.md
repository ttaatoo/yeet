# Local patches

This directory is based on Neon revision
`ce8d252c8fd53ea0b6960e02c423315eef11f141`.

Yeet keeps this package local because the pinned revision does not compile in
Swift 6 mode. The local changes are:

- Match the existing queue contract with explicit `Sendable` declarations.
  Public state changes remain main-queue checked. Parser state remains guarded
  by the package's serial queue and semaphore.
- Transfer callback values through documented `@unchecked Sendable` boxes at
  the same queue boundaries used upstream.
- Replace the deprecated `ResolvingQueryCursor` API with
  `ResolvingQueryMatchSequence`. Asynchronous prefetch still materializes raw
  matches on the worker queue; predicate resolution still runs when the
  delivered sequence is consumed.
- Mark immutable token values as `Sendable` and make the AppKit delegate's
  synchronous main-queue handoff explicit.
- Keep the seven Neon and TextKit tests. Omit the legacy TreeSitterClient test
  target because its embedded parser fixture is not compatible with Yeet's
  resolved SwiftTreeSitter 0.25 dependency.
- Remove upstream trailing whitespace so repository checks pass.

To return to the remote package, restore the URL dependency in
`Vendor/STTextView-Plugin-Neon/Package.swift`, remove this directory, and
resolve Swift packages again.
