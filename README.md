# CPU Control Menu (Bash)

[![License: GPL v3](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE) [![Platform: Linux](https://img.shields.io/badge/platform-Linux-lightgrey.svg)]() [![Shell](https://img.shields.io/badge/language-Bash-green.svg)]()

## Description
CPU Control Menu (Bash) — A lightweight, terminal-based CPU management tool for Linux. Written entirely in Bash with dialog menus, it lets you set governors, adjust min/max frequencies, toggle Turbo Boost, run stress tests, and view CPU info. Simple, portable, and a no-frills alternative to the GUI tool cpu-power-manager you will find in my repo, which is a overkill gtk ui / rust backend version of this plus more.

## Features
- Set CPU governors (performance, powersave, etc.)
- Adjust fixed, minimum, and maximum frequencies
- Toggle Intel/AMD Turbo Boost
- Run stress tests with progress gauge
- View CPU info, hardware limits, and logs
- Menu-driven interface with dialog

## Installation
- Clone: `git clone https://github.com/globalcve/cpu-control-menu.git`
- Enter directory: `cd cpu-control-menu`
- Make executable: `chmod +x cpupower_2.0_bash.sh`
- Run: `./cpupower_2.0_bash.sh`

## Dependencies
The script checks for and can install missing dependencies:
- cpufrequtils
- dialog
- stress


## License
GNU GPL v3.0 

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
        __\/////////_______\///////////////___\////////////____\///////////////________\///________```
