# Folly and Valor

An automated reverse engineering and network interception environment designed to facilitate the recreation of the game server.

## Overview

`folly-n-valor` provides a highly controlled, reproducible, and isolated lab environment. It uses `Packer`, `Vagrant`, and `libvirt` to deploy a Windows 10 LTSC guest, which is then monitored and intercepted via a custom Go-based mock gateway (`server/`).

The environment is specifically architected to capture network traffic (DNS, HTTP, etc.) and allow for deep instrumentation of the game client using Frida, all while maintaining strict network isolation to prevent any external communication.

## Mission & Objectives

The primary objective of this project is to reverse engineer the networking protocol of original game to facilitate the development of a compatible, private game server. 

To achieve this, the project focuses on:

- **Automated Lab Provisioning:** Rapidly deploying consistent, clean Windows environments.
- **Network Interception:** Capturing and analyzing all traffic between the client and its original servers.
- **Deep Instrumentation:** Using Frida to inspect client memory and function calls during gameplay.
- **Strict Isolation:** Ensuring the research is conducted in a secure, sandbox-like environment.

## Key Technologies

- **Orchestration:** Vagrant, libvirt, QEMU/KVM
- **Imaging:** Packer (Windows LTSC)
- **Instrumentation:** Frida
- **Network Mocking:** Go (custom mock gateway)
- **Analysis:** Ghidra, Wireshark/tcpdump

## Intended Use

This project is strictly intended for:

- **Educational Purposes:** Learning about network protocols, reverse engineering, and virtualization.
- **Security Research:** Analyzing game client behavior and protocol security in a controlled environment.

## License & Legal Basis

**Non-Commercial Use Only.**

This software is provided for educational and research purposes. Any use of this software for commercial gain is strictly prohibited without explicit permission from the author. 

See `LICENSE` for full terms.
