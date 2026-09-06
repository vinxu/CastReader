# Global maintenance-release credential path

Captured at 2026-09-06T02:50:22Z. This note contains no token, refresh token, secret value, secret hash, user content, or production response body.

## Decision

The existing Vercel CLI login can authorize this one fixed release through the existing GitHub maintenance workflow after its access token is copied to the existing GitHub Production `VERCEL_TOKEN` secret through stdin. The refreshed access token expires at `2026-09-06T10:50:22Z`, giving an eight-hour lifetime at refresh. Read-only checks after refresh returned the same authenticated account and the existing `castreader/readout-web` project with Node.js 22.x.

This is a one-run credential bridge. It does not create a project-scoped CI token, establish automated rotation, or repair the long-term CI credential lifecycle. The existing OAuth grant may cover more than the legacy project; this operation neither requested nor added scope.

## Why the original GitHub workflow remains required

No repository instruction says production may only be released from GitHub Actions. The current maintenance workflow is nevertheless the only already-configured route that has every required gate and the two Voice Gift bridge secrets without exporting them locally.

Exact source `186e20b745b0b89f426d27d7f9ddb44f979dcae2` defines these controls in `.github/workflows/backend-maintenance-release.yml`:

- lines 6–27: manual full-SHA inputs, a production concurrency group, read-only repository permission, and the GitHub `production` environment;
- lines 43–83: exact protected-ref/source verification, frozen dependencies, gateway/clone/monitoring/migration/regional tests, and TypeScript checking;
- lines 85–120: live production baseline identity and Voice Clone/Voice Gift capability gates;
- lines 122–170: pinned Vercel CLI, production-environment pull and regional target audit, immutable production build, and candidate deployment without assigning the production domain;
- lines 171–267: candidate identity/auth/cron/RTDN/audio checks;
- lines 269–365: authenticated and guest Voice Gift E2E, using the GitHub Production bridge secrets and independent billing-authority fingerprint;
- lines 376–464: a second live-production CAS before promotion, alias convergence, production TTS/clone probes, and final deployment inspection;
- lines 466–534: rollback only when live still equals the candidate or captured baseline, with refusal to overwrite an unrelated release.

The fixed inputs remain:

- release SHA: `186e20b745b0b89f426d27d7f9ddb44f979dcae2`
- previous production SHA: `3ce12a7c794e3d9788a7982a66a62f70a9407678`

The repository's source guard also rejects a dirty checkout, a root `.env.local`, a SHA different from `origin/beta`, and a previous SHA that is not an ancestor. The target guard pins the existing Global Vercel organization/project, production environment, application identity, and Global service route.

## Official refresh evidence

The installed official package `/Users/xuxuheng/.npm-global/lib/node_modules/vercel/node_modules/@vercel/cli-auth/oauth.ts` defines the CLI OAuth issuer/client setup at lines 31–48, the RFC 6749 refresh request at lines 220–243, and token introspection at lines 244–272. The installed Vercel CLI's own expiry path in `/Users/xuxuheng/.npm-global/lib/node_modules/vercel/dist/chunks/chunk-QQ77K4QW.js` lines 1784–1842 uses the same refresh grant, writes the new access expiry, accepts provider refresh-token rotation, and persists the login cache.

There is no public CLI command that forces an unexpired session to refresh. The authorized early refresh therefore called that installed official OAuth implementation directly, with the CLI's existing issuer, client and scope. It did not alter the CLI code or manufacture an expiry. Old and new access tokens both passed official introspection, and the OAuth client identity remained the same. The provider returned a rotated refresh token; it was atomically stored with the new access token in the original login cache, still owned by the current user with mode `0600`.

See `cli-oauth-refresh-receipt.json` in this directory for the non-secret receipt.

## Safe one-run handoff

For this run, only the access token should be read inside a controlled local process and piped on stdin to replace the existing GitHub Production `VERCEL_TOKEN`. The refresh token must remain only in the Vercel CLI login cache. Before replacement, compare the GitHub secret's `updatedAt` with the already-reviewed value; then dispatch the unchanged workflow at `beta` with the two fixed SHAs above. No gate should be removed or reproduced locally.

The workflow's Voice Gift inputs stay in the GitHub Production environment:

- `VOICE_CLONE_WEB_BRIDGE_SECRET`
- `VOICE_GIFT_E2E_BRIDGE_SECRET`
- `EXPECTED_BILLING_AUTHORITY_FINGERPRINT`

Vercel's pulled production env deliberately redacts sensitive values, so CLI login alone cannot reproduce this E2E locally. Old local `.vercel/.env.production.local` files are neither complete nor safe authorities for these values.

## Boundary

This audit and refresh did not update a GitHub secret, dispatch a workflow, create a Vercel deployment, change a project setting, or touch production traffic. The refreshed credential only makes the original gated workflow executable for the authorized release window.
