

## Description
CPU Control Menu (Bash) — A lightweight, terminal-based CPU management tool for Linux. Written entirely in Bash, it is **driver-aware**: frequency control works correctly on modern `intel_pstate` / `amd-pstate` (which have no `userspace` governor) by writing sysfs directly, not relying on `cpufreq-set -f`. Simple, portable, and a no-frills alternative to the GUI tool cpu-power-manager you will find in my repo, which is a overkill gtk ui / rust backend version of this plus more.

## Features
- One-shot power **profiles**: Max / Balanced / Quiet / Battery
- **Live monitor**: per-core MHz, package temp, power draw, governor
- Set governors and **Energy Performance Preference (EPP)**
- Pin a fixed frequency; set min/max limits; release all limits
- Toggle Intel/AMD Turbo Boost
- **RAPL power cap (PL1)** + live package power (watts)
- Save/restore a baseline snapshot to return to stock
- Run stress tests; view CPU info and logs
- Menu UI via `dialog` or `whiptail`, with a plain-text fallback

## Dependencies
Talks to sysfs directly — no hard dependency on cpufrequtils. Optional:
- `dialog` or `whiptail` (menu UI; falls back to plain text)
- `stress` or `stress-ng` (stress test)
- `sudo` (required only when applying changes)




<3 by 
```
______/\\\\\\\\\\\__/\\\\\\\\\\\\\\\_____/\\\\\\\\\\\\__/\\\______________/\\\________/\\\_        
 _____\/////\\\///__\/\\\///////////____/\\\//////////__\/\\\_____________\///\\\____/\\\/__       
  _________\/\\\_____\/\\\______________/\\\_____________\/\\\_______________\///\\\/\\\/____      
   _________\/\\\_____\/\\\\\\\\\\\_____\/\\\____/\\\\\\\_\/\\\_________________\///\\\/______     
    _________\/\\\_____\/\\\///////______\/\\\___\/////\\\_\/\\\___________________\/\\\_______    
     _________\/\\\_____\/\\\_____________\/\\\_______\/\\\_\/\\\___________________\/\\\_______   
      __/\\\___\/\\\_____\/\\\_____________\/\\\_______\/\\\_\/\\\___________________\/\\\_______  
       _\//\\\\\\\\\______\/\\\\\\\\\\\\\\\_\//\\\\\\\\\\\\/__\/\\\\\\\\\\\\\\\_______\/\\\_______  
        __\/////////_______\///////////////___\////////////____\///////////////________\///________
