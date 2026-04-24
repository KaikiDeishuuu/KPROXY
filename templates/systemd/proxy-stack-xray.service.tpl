[Unit]
Description=kprxy Xray Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
User=root
ExecStartPre=/usr/bin/test -s {{XRAY_CONFIG}}
ExecStartPre={{XRAY_BIN}} run -test -c {{XRAY_CONFIG}}
ExecStart={{XRAY_BIN}} run -config {{XRAY_CONFIG}}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
