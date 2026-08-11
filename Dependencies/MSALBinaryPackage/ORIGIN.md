# MSAL binary provenance

- Version: `2.14.1`
- Upstream release: `https://github.com/AzureAD/microsoft-authentication-library-for-objc/releases/download/2.14.1/MSAL.zip`
- SwiftPM checksum: `0803af46b932a498d1f0d9ca46288466fa833cb3cb8d5383434de2218824f98c`
- Product: Microsoft's unmodified `MSAL.xcframework` extracted from that archive.

The checksum matches the official `Package.swift` at the `2.14.1` tag. The
framework is vendored so clean CastReader builds do not depend on cloning the
78,000-object MSAL repository or on Xcode's remote-artifact Keychain lookup.
