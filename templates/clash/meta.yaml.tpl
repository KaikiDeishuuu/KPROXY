mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
proxies:
__PROXIES__
proxy-groups:
  - name: PROXY
    type: select
    proxies:
__PROXY_NAMES__
rule-providers:
  lan:
    type: file
    behavior: classical
    path: ./rules/lan.yaml
  custom_direct:
    type: file
    behavior: classical
    path: ./rules/custom_direct.yaml
  custom_proxy:
    type: file
    behavior: classical
    path: ./rules/custom_proxy.yaml
  custom_reject:
    type: file
    behavior: classical
    path: ./rules/custom_reject.yaml
rules:
  - RULE-SET,lan,DIRECT
  - GEOIP,CN,DIRECT,no-resolve
  - GEOSITE,CN,DIRECT
  - RULE-SET,custom_reject,REJECT
  - RULE-SET,custom_direct,DIRECT
  - RULE-SET,custom_proxy,PROXY
  - GEOSITE,GELOCATION-!CN,PROXY
  - MATCH,PROXY
