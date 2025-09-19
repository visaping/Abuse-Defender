#!/bin/bash

# [AUTO] حالت خودکار: با فلگ --auto یا env=ABUSE_AUTO=1 فعال می‌شود
AUTO=0
if [[ "${ABUSE_AUTO:-0}" == "1" ]]; then AUTO=1; fi
if [[ "${1:-}" == "--auto" ]]; then AUTO=1; fi

if [[ $EUID -ne 0 ]]; then
    clear
    echo "You should run this script with root!"
    echo "Use sudo -i to change user to root"
    exit 1
fi

# [AUTO] کمک‌تابع‌های ورودی
ask_yn () {
    local prompt="$1"
    if [[ $AUTO -eq 1 ]]; then
        echo "Y"
        return 0
    fi
    read -p "$prompt" ans
    echo "$ans"
}

pause_or_return_menu () {
    if [[ $AUTO -eq 1 ]]; then
        return 0
    fi
    read -p "Press enter to return to Menu" dummy
    main_menu
}

function main_menu {
    # [AUTO] اگر حالت خودکار است، مستقیم گزینه ۱ را اجرا و سپس Exit
    if [[ $AUTO -eq 1 ]]; then
        block_ips
        exit 0
    fi
    clear
    echo "----------- Abuse Defender -----------"
    echo "https://github.com/visaping/Abuse-Defender"
    echo "--------------------------------------"
    echo "Choose an option:"
    echo "1-Block Abuse IP-Ranges"
    echo "2-Whitelist an IP/IP-Ranges manually"
    echo "3-Block an IP/IP-Ranges manually"
    echo "4-View Rules"
    echo "5-Clear all rules"
    echo "6-Exit"
    read -p "Enter your choice: " choice
    case $choice in
    1) block_ips ;;
    2) whitelist_ips ;;
    3) block_custom_ips ;;
    4) view_rules ;;
    5) clear_chain ;;
    6) echo "Exiting..."; exit 0 ;;
    *) echo "Invalid option"; main_menu ;;
    esac
}

function ensure_deps {
    # [AUTO] نصب غیرتعامل apt (برای iptables-persistent هم)
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v iptables &>/dev/null; then
        apt update -y
        apt install -y iptables
    fi
    if ! dpkg -s iptables-persistent &>/dev/null; then
        # autosave v4/v6 را از قبل yes می‌کنیم
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
        apt install -y iptables-persistent
    fi
}

function block_ips {
    clear
    ensure_deps

    if ! iptables -L abuse-defender -n >/dev/null 2>&1; then
        iptables -N abuse-defender
    fi
    if ! iptables -L abuse-defender-custom -n >/dev/null 2>&1; then
        iptables -N abuse-defender-custom
    fi
    if ! iptables -L abuse-defender-whitelist -n >/dev/null 2>&1; then
        iptables -N abuse-defender-whitelist
    fi

    if ! iptables -L OUTPUT -n | awk '{print $1}' | grep -wq "^abuse-defender$"; then
        iptables -I OUTPUT -j abuse-defender
    fi
    if ! iptables -L OUTPUT -n | awk '{print $1}' | grep -wq "^abuse-defender-custom$"; then
        iptables -I OUTPUT -j abuse-defender-custom
    fi
    if ! iptables -L OUTPUT -n | awk '{print $1}' | grep -wq "^abuse-defender-whitelist$"; then
        iptables -I OUTPUT -j abuse-defender-whitelist
    fi

    clear
    confirm=$(ask_yn "Are you sure about blocking abuse IP-Ranges? [Y/N] : ")
    if [[ $confirm == [Yy]* ]]; then
        clear
        clear_rules=$(ask_yn "Do you want to delete the previous rules? [Y/N] : ")
        if [[ $clear_rules == [Yy]* ]]; then
            iptables -F abuse-defender
            iptables -F abuse-defender-custom
            iptables -F abuse-defender-whitelist
        fi

        # [AUTO] استفاده از لیست فورک خودت
        IP_LIST=$(curl -s 'https://raw.githubusercontent.com/visaping/Abuse-Defender/main/abuse-ips.ipv4')
        if [ $? -ne 0 ] || [ -z "$IP_LIST" ]; then
            echo "Failed to fetch the IP-Ranges list. Please contact @visaping"
            pause_or_return_menu
            return
        fi

        for IP in $IP_LIST; do
            iptables -A abuse-defender -d "$IP" -j DROP
        done

        # hosts hardening
        grep -q '127.0.0.1 appclick.co' /etc/hosts || echo '127.0.0.1 appclick.co' | tee -a /etc/hosts >/dev/null
        grep -q '127.0.0.1 pushnotificationws.com' /etc/hosts || echo '127.0.0.1 pushnotificationws.com' | tee -a /etc/hosts >/dev/null

        iptables-save > /etc/iptables/rules.v4

        clear
        echo "Abuse IP-Ranges blocked successfully."

        enable_update=$(ask_yn "Do you want to enable Auto-Update every 24 hours? [Y/N] : ")
        if [[ $enable_update == [Yy]* ]]; then
            setup_auto_update
            echo "Auto-Update has been enabled."
        fi

        if [[ $AUTO -eq 1 ]]; then
            # در حالت خودکار: پایان کار و خروج کامل
            exit 0
        fi
        pause_or_return_menu
    else
        echo "Cancelled."
        if [[ $AUTO -eq 1 ]]; then
            exit 0
        fi
        pause_or_return_menu
    fi
}

function setup_auto_update {
    cat <<'EOF' >/root/abuse-defender-update.sh
#!/bin/bash
set -euo pipefail
IP_LIST=$(curl -s 'https://raw.githubusercontent.com/visaping/Abuse-Defender/main/abuse-ips.ipv4')
iptables -F abuse-defender
for IP in $IP_LIST; do
    iptables -A abuse-defender -d "$IP" -j DROP
done
iptables-save > /etc/iptables/rules.v4
EOF
    chmod +x /root/abuse-defender-update.sh

    # از duplicate جلوگیری کنیم
    crontab -l 2>/dev/null | grep -v "/root/abuse-defender-update.sh" | crontab -
    (crontab -l 2>/dev/null; echo "0 0 * * * /root/abuse-defender-update.sh") | crontab -
}

function whitelist_ips {
    clear
    read -p "Enter IP-Ranges to whitelist (like 192.168.1.0/24): " ip_range
    iptables -I abuse-defender-whitelist -d "$ip_range" -j ACCEPT
    iptables-save > /etc/iptables/rules.v4
    clear
    echo "$ip_range whitelisted successfully."
    pause_or_return_menu
}

function block_custom_ips {
    clear
    read -p "Enter IP-Ranges to block (like 192.168.1.0/24): " ip_range
    iptables -A abuse-defender-custom -d "$ip_range" -j DROP
    iptables-save > /etc/iptables/rules.v4
    clear
    echo "$ip_range blocked successfully."
    pause_or_return_menu
}

function view_rules {
    clear
    echo "===== abuse-defender Rules ====="
    iptables -L abuse-defender -n --line-numbers
    echo ""
    echo "===== abuse-defender-custom Rules ====="
    iptables -L abuse-defender-custom -n --line-numbers
    echo ""
    echo "===== abuse-defender-whitelist Rules ====="
    iptables -L abuse-defender-whitelist -n --line-numbers
    pause_or_return_menu
}

function clear_chain {
    clear
    iptables -F abuse-defender
    iptables -F abuse-defender-custom
    iptables -F abuse-defender-whitelist
    sed -i '/127.0.0.1 appclick.co/d' /etc/hosts
    sed -i '/127.0.0.1 pushnotificationws.com/d' /etc/hosts
    crontab -l 2>/dev/null | grep -v "/root/abuse-defender-update.sh" | crontab - || true
    iptables-save > /etc/iptables/rules.v4
    clear
    echo "All Rules cleared successfully."
    pause_or_return_menu
}

main_menu
