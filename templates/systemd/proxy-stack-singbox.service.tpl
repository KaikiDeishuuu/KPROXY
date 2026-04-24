[Unit]
Description=kprxy sing-box Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
User=root
ExecStartPre=/usr/bin/test -s {{SINGBOX_CONFIG}}
ExecStartPre={{SINGBOX_BIN}} check -c {{SINGBOX_CONFIG}}
ExecStart={{SINGBOX_BIN}} run -c {{SINGBOX_CONFIG}}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
