# Tailscale in Containers on Render

This project provides a Docker-based setup for running [Tailscale](https://tailscale.com/) inside a container on platforms like Render, which do not provide access to `/dev/net/tun` and may inject Kubernetes-related environment variables. The configuration uses Tailscale's [userspace networking mode](https://tailscale.com/kb/1112/userspace-networking), making it suitable for restricted and serverless environments.

## Overview

- **Tailscale Version:** Configurable via build argument (`TS_VERSION`).
- **Userspace Networking:** Runs Tailscale in userspace mode, so no kernel TUN device or extra Linux capabilities are required.
- **Ephemeral State:** Uses in-memory state (`--state=mem:`) for stateless operation, as recommended for containers and serverless platforms.
- **Supervisor:** Uses `supervisord` to manage both the Tailscale daemon and the `tailscale up` command.
- **Entrypoint Script:** Unsets problematic Kubernetes environment variables that may be injected by platforms like Render, preventing Tailscale from attempting to initialize in a broken Kubernetes environment.
- **Minimal Image:** Only essential packages are installed, reducing image size and attack surface.


## Usage

Set the required render environment variable:
TAILSCALE_AUTHKEY: Your Tailscale auth key (ephemeral recommended).


Note: This setup is designed for environments where you do not have access to kernel networking features.
