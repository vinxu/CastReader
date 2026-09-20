# Safari host integration evidence

Baseline: 94499d29cafe118b9df75446158922daa5f977ae. Extension baseline: 33cce3e6f699a390964a64dabb09c656137d721d (1.2.44).

The restored native extension uses a dedicated `com.same.castreader.safari` keychain access group containing only an opaque server session envelope. The App's existing private group and provider credentials are not shared. Each envelope and entitlement snapshot must match the frozen region, opaque account storage ID, and login-boundary nonce. Account changes invalidate the projection before publishing a new account.

Validation on the isolated iPhone 16 Pro Max / iOS 26.5 simulator DF8A921B-A41E-40C6-8854-2E9EF569340D:

- H02SignedContracts.xcresult: 110 tests, zero failures, one explicitly opt-in live network probe skipped. Includes six Safari contract and 104 existing regional/auth transport tests.
- H02KeychainContracts.xcresult: seven Safari tests, zero failures. Adds an actual signed-simulator dedicated-keychain write/read/update-rejection/delete round trip and Global/CN isolation; fixtures restore preexisting entries.
- H02ContractsRetry.xcresult preserves the unsuccessful unsigned simulator run. The private Keychain could not persist tokens; re-running with normal simulator signing resolved all failures without weakening the existing assertions.
- Raw xcodebuild logs and JavaScript routing/sync results are in the sibling extension checkout, reports/safari-parity-20260920.

These are compilation, integration and contract results. Safari UI/native-message delivery, real device entitlements, login/account navigation, session renewal, playback and StoreKit are not yet accepted. A simulator Keychain success is not evidence of distribution-profile capability support.

No upload or App Store submission was performed. Generated Safari Resources are staged from the extension checkout and will be bound to the final candidate receipt.
