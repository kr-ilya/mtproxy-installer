# MTProxy Installer

- Install **Official MTProxy** (imilya/mtproxy) or **Telemt** (Rust-based, high performance) in Docker
- **Fake TLS** — disguise traffic as HTTPS to bypass DPI and censorship
- **Multi-user support** in Telemt with hot add/remove via API (no restart needed)
- Management menu: view links, logs, update image, restart, uninstall
- Re-running the script opens the management menu for an already installed proxy

## Quick install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kr-ilya/mtproxy-installer/main/install.sh)
```

## References

- [Official MTProxy](https://github.com/TelegramMessenger/MTProxy) — original Telegram MTProxy server
- [MTProxy Docker image](https://github.com/kr-ilya/mtproxy-docker) — Docker image used for Official MTProxy
- [Telemt](https://github.com/telemt/telemt) — Rust-based MTProxy with Fake TLS and multi-user support
