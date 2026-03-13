#!/bin/bash
set -e
apt-get update
apt-get install -y curl ca-certificates
curl -fsSL https://raw.githubusercontent.com/Gnarly-Crumb/mautic-lightsail.launch.script/main/launch-mautic-lightsail.sh -o /root/launch-mautic-lightsail.sh
chmod +x /root/launch-mautic-lightsail.sh
bash /root/launch-mautic-lightsail.sh
