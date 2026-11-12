#!/bin/bash
# Source from build scripts; never exports certificate material or changes Keychain.
micbridge_signing_identity() {
    local identity="${MICBRIDGE_SIGNING_IDENTITY:-}"
    local available
    # Safe default: a build never discovers a personal signing identity implicitly.
    if [[ -z "$identity" || "$identity" == '-' ]]; then
        printf '%s\n' '-'
        return 0
    fi
    available="$(security find-identity -v -p codesigning)"
    if [[ ! "$identity" =~ ^[0-9A-Fa-f]{40}$ ]] || ! printf '%s\n' "$available" | grep -Fq -- "$identity"; then
        printf '%s\n' 'Set MICBRIDGE_SIGNING_IDENTITY to a valid code-signing certificate SHA-1 from: security find-identity -v -p codesigning' >&2
        printf '%s\n' 'Leave MICBRIDGE_SIGNING_IDENTITY unset or set it to - for an ad-hoc build; permissions may need granting again after updates.' >&2
        return 1
    fi
    printf '%s\n' "$identity"
}
