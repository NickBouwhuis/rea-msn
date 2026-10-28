#!/bin/bash
# Stores the macOS signing and notarization credentials as GitHub Actions
# secrets, so the release workflow signs Messenger.app with your Developer ID
# and notarizes it. Run it yourself: it never prints a secret, and the
# certificate password is read from the terminal, not the command line.
#
#   Messenger/scripts/set-signing-secrets.sh DeveloperID.p12 AuthKey_KEYID.p8 KEY_ID ISSUER_ID
#
# DeveloperID.p12: in Keychain Access, right-click your "Developer ID
#   Application: …" certificate › Export, as .p12 with a password. (Create the
#   certificate first if you have none: Xcode › Settings › Accounts › Manage
#   Certificates › + › Developer ID Application; it needs the Account Holder.)
# AuthKey_KEYID.p8, KEY_ID, ISSUER_ID: App Store Connect › Users and Access ›
#   Integrations › Team Keys › +, with Developer access. The .p8 downloads once.
set -euo pipefail
P12="${1:?usage: $0 DeveloperID.p12 AuthKey_KEYID.p8 KEY_ID ISSUER_ID}"
P8="${2:?usage: $0 DeveloperID.p12 AuthKey_KEYID.p8 KEY_ID ISSUER_ID}"
KEY_ID="${3:?usage: $0 DeveloperID.p12 AuthKey_KEYID.p8 KEY_ID ISSUER_ID}"
ISSUER="${4:?usage: $0 DeveloperID.p12 AuthKey_KEYID.p8 KEY_ID ISSUER_ID}"
REPO="${REPO:-NickBouwhuis/rea-msn}"

IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)"
if [ -z "$IDENTITY" ]; then
	echo "No \"Developer ID Application\" certificate in your keychain; see the comment at the top of this script." >&2
	exit 1
fi
read -r -s -p "Password of $(basename "$P12"): " P12_PASSWORD
echo

base64 -i "$P12" | gh secret set MACOS_CERTIFICATE --repo "$REPO"
printf %s "$P12_PASSWORD" | gh secret set MACOS_CERTIFICATE_PASSWORD --repo "$REPO"
printf %s "$IDENTITY" | gh secret set MACOS_SIGN_IDENTITY --repo "$REPO"
base64 -i "$P8" | gh secret set NOTARY_KEY --repo "$REPO"
printf %s "$KEY_ID" | gh secret set NOTARY_KEY_ID --repo "$REPO"
printf %s "$ISSUER" | gh secret set NOTARY_ISSUER --repo "$REPO"
echo "Stored the signing secrets for \"$IDENTITY\" in $REPO. The next v* tag builds a signed, notarized DMG."
