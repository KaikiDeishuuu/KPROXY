{
  "log": {
    "loglevel": "warning",
    "access": "/opt/kprxy/runtime/log/xray-access.log",
    "error": "/opt/kprxy/runtime/log/xray-error.log",
    "dnsLog": false,
    "maskAddress": "quarter"
  },
  "inbounds": [],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    },
    {
      "tag": "dns-out",
      "protocol": "dns"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": []
  }
}
