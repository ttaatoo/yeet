# Local patches

This directory is based on `STTextKitPlus` 0.3.0 at revision
`2ee74906f4d753458eeaa9a2f6d4538aacb86a1d`.

Yeet keeps this package local because version 0.3.0 does not compile when a
caller selects Swift 6 for all package targets. The local changes are:

- Make `CaretLocationOptions.allowOutside` immutable. It is an option constant,
  and no package code writes it.
- Inline `_textSelectionInsertionPointFilter`. This removes a global closure
  whose function type is not `Sendable`.
- Remove three upstream trailing whitespace sequences so repository whitespace
  checks pass when the package is added.

To return to the upstream package, restore the URL dependency in
`Vendor/STTextView/Package.swift`, remove this directory, and resolve Swift
packages again.
