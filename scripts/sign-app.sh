#!/bin/bash
# Build-time signing policy shared by every Makefile bundle consumer. Keep the
# default certificate-backed requirement: privacy grants must survive new code.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <app-bundle> <bundle-id>" >&2
    exit 1
fi

bundle="$1"
bundle_id="$2"
identity="${CODE_SIGN_IDENTITY:-}"

if [[ -z "$identity" ]]; then
    # -v lists only identities valid for code signing. Deduplicate by fingerprint
    # because the same certificate can appear in more than one keychain.
    identities="$(security find-identity -v -p codesigning)"
    for kind in 'Developer ID Application' 'Apple Development'; do
        candidates="$(printf '%s\n' "$identities" | awk -v prefix="\"$kind: " '
            length($2) == 40 && $2 ~ /^[[:xdigit:]]+$/ && index($0, prefix) {
                print $2
            }
        ' | sort -u)"
        count="$(printf '%s\n' "$candidates" | awk 'NF { n++ } END { print n+0 }')"
        if [[ "$count" -gt 1 ]]; then
            echo "Multiple usable $kind identities; set CODE_SIGN_IDENTITY to a certificate fingerprint or exact name." >&2
            echo "List choices with: security find-identity -v -p codesigning" >&2
            exit 1
        fi
        if [[ "$count" -eq 1 ]]; then
            identity="$candidates"
            break
        fi
    done
    if [[ -z "$identity" ]]; then
        echo "Warning: no usable Developer ID Application or Apple Development certificate found; falling back to ad-hoc signing." >&2
        identity='-'
    fi
fi

if [[ "$identity" == '-' ]]; then
    echo "Warning: ad-hoc signing changes Sable's identity on rebuild; macOS permissions may reset." >&2
fi

echo "-> signing $bundle with $identity"
# Local installs need no timestamp service. A selected certificate failure must
# stop the build, never silently replace that identity with an ad-hoc signature.
codesign --force --sign "$identity" --identifier "$bundle_id" --timestamp=none "$bundle"
codesign --verify --deep --strict "$bundle"
