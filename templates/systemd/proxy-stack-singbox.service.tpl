[Unit]
Description=Proxy Stack sing-box Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart={{SINGBOX_BIN}} run -c {{SINGBOX_CONFIG}}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
