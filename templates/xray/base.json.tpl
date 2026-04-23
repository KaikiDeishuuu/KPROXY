{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/proxy-stack/xray-access.log",
    "error": "/var/log/proxy-stack/xray-error.log",
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
