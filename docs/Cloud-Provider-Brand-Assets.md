# Cloud provider brand assets

CastReader uses these assets only to identify the corresponding cloud-storage integration in the import UI. They are not CastReader app icons and do not imply sponsorship or endorsement. The files are kept unmodified: SwiftUI only scales them proportionally. Google Drive and OneDrive receive a neutral white tile with clear space; the official Dropbox navigation SVG already includes its vendor-supplied white tile and border. This keeps the original multicolor artwork legible in both light and dark appearances. The image is decorative beside an accessible provider-name label, so `CloudProviderIcon` is intentionally hidden from VoiceOver to avoid duplicate announcements.

Retrieved on 2026-08-10.

## Google Drive

- Local file: `CastReader/Assets.xcassets/CloudProviderGoogleDrive.imageset/google-drive-official.png`
- Official download: <https://www.gstatic.com/images/branding/productlogos/drive_2026/v2/web-512dp/logo_drive_2026_color_2x_web_512dp.png>
- Official developer guidance: <https://developers.google.com/workspace/drive/api/guides/branding>
- SHA-256: `9774523ca70f8a30f728fe49fb398d7ee1e13ba827cfaf678679ce0960f762ed`
- Usage notes followed: refer to Google Drive by its full name; use the logo to identify the Google Drive action/integration; resize only and do not alter the artwork.

Google Drive is a trademark of Google LLC. Use of this trademark is subject to Google Permissions and the Google Drive API Terms of Service.

## Dropbox

- Local file: `CastReader/Assets.xcassets/CloudProviderDropbox.imageset/dropbox-logo-nav-official.svg`
- Official download used by Dropbox's public navigation: <https://fjord.dropboxstatic.com/warp/conversion/dropbox/warp/icons/Dropbox-logo-nav.svg>
- Official developer guidance: <https://www.dropbox.com/developers/reference/branding-guide>
- Official general guidance: <https://www.dropbox.com/branding>
- SHA-256: `e2c05d2a02b18dad5859a63a72199f6a4e2650790c74013aaf9155dd9a9cd4ce`
- Usage notes followed: the glyph identifies and directs users to Dropbox functionality; it is not recolored, distorted, rotated, deconstructed, or combined with the CastReader brand.

Dropbox and the Dropbox logo are trademarks of Dropbox, Inc. CastReader is not affiliated with or otherwise sponsored by Dropbox, Inc.

## Microsoft OneDrive

- Local file: `CastReader/Assets.xcassets/CloudProviderOneDrive.imageset/onedrive-official.svg`
- Official Microsoft Office CDN download: <https://res-1.cdn.office.net/files/fabric/assets/brand-icons/product/svg/onedrive_48x1.svg>
- Official Microsoft 365 trademark/icon guidance: <https://cdn-dynmedia-1.microsoft.com/is/content/microsoftcorp/microsoft/mscle/documents/presentations/FY27_Microsoft_365_trademark_guidelines.pdf>
- Microsoft trademark guidance: <https://www.microsoft.com/legal/intellectualproperty/trademarks>
- SHA-256: `393fe3509c33de52e4dcfb7aece1a5ea41d8114ac1be0d68b13948cc28962f6a`
- Usage notes followed: preserve the full-color product icon, proportions, and vector artwork; do not crop, recolor, add effects, or use it as CastReader's app icon; keep the provider label separate and neutral.

Microsoft and OneDrive are trademarks of the Microsoft group of companies. Their use here identifies truthful interoperability only and does not imply endorsement.

## Maintenance

Before replacing any asset, re-check the linked vendor guidance, download only from the vendor's public official resource/CDN, update the retrieval date and SHA-256, and visually verify light mode, dark mode, high-contrast borders, the 20-point history treatment, and the 58-point connection treatment.
