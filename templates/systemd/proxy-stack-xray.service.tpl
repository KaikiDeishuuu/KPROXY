[Unit]
Description=Proxy Stack Xray Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart={{XRAY_BIN}} run -config {{XRAY_CONFIG}}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
