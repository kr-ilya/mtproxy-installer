# MTProxy Installer

- Install **Official MTProxy** (imilya/mtproxy) or **Telemt** (Rust-based, high performance) in Docker
- **Fake TLS** — disguise traffic as HTTPS to bypass DPI and censorship
- **Multi-user support** in Telemt with hot add/remove via API (no restart needed)
- Management menu: view links, logs, update image, restart, uninstall
- Re-running the script opens the management menu for an already installed proxy

## Quick install

```bash
curl -O https://raw.githubusercontent.com/kr-ilya/mtproxy-installer/main/install.sh
chmod +x install.sh
./install.sh
```

## Preview

Startup menu  

<img width="428" height="130" alt="hello" src="https://github.com/user-attachments/assets/6c6dbefe-ab20-4a9a-8551-bd2eece7d8b6" />

Manage menu  

<img width="261" height="172" alt="manage" src="https://github.com/user-attachments/assets/b0e6386b-bd3c-4b5f-870e-734178fbd475" />


## References

- [Official MTProxy](https://github.com/TelegramMessenger/MTProxy) — original Telegram MTProxy server
- [MTProxy Docker image](https://github.com/kr-ilya/mtproxy-docker) — Docker image used for Official MTProxy
- [Telemt](https://github.com/telemt/telemt) — Rust-based MTProxy with Fake TLS and multi-user support
