# Default rule chain used by generated client configs.
# Priority order (top to bottom):
# 1) LAN/private traffic -> DIRECT
# 2) CN domain/IP -> DIRECT
# 3) Custom reject list -> REJECT/BLOCK
# 4) Custom direct list -> DIRECT
# 5) Custom proxy list -> PROXY
# 6) Other traffic -> PROXY
rule_chain:
  - RULE-SET,lan,DIRECT
  - GEOIP,CN,DIRECT,no-resolve
  - GEOSITE,CN,DIRECT
  - RULE-SET,custom_reject,REJECT
  - RULE-SET,custom_direct,DIRECT
  - RULE-SET,custom_proxy,PROXY
  - MATCH,PROXY
