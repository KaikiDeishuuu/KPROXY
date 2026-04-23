# Initialized Rules Bundle

This directory is generated automatically with subscription/client exports.

## Files

- `lan.yaml`: local and private network traffic.
- `custom_direct.yaml`: domains you always want to access directly.
- `custom_proxy.yaml`: domains you always want to send through proxy.
- `custom_reject.yaml`: domains you always want to block.
- `default_rules.yaml`: default chain reference.

## Edit Tips

- Keep rule order in the main client config unchanged unless you know the impact.
- Add rules gradually and test after each change.
- Prefer specific rules (`DOMAIN,api.example.com`) before broad wildcards.
- Avoid aggressive wildcard patterns that may overmatch unrelated traffic.

## Wildcard Caution

Bad example:

- `DOMAIN-KEYWORD,google`

Better examples:

- `DOMAIN-SUFFIX,googlevideo.com`
- `DOMAIN,accounts.google.com`

## Engine Notes

- Clash.Meta can reference these files directly.
- Xray/sing-box exports include an embedded default routing fallback and keep these files for manual extension.
