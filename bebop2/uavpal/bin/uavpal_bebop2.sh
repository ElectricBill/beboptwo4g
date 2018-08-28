#!/bin/sh

ulogger -s -t uavpal_bebop2 "Huawei USB device detected"
ulogger -s -t uavpal_bebop2 "=== Enabling LTE ==="

bebop2_fw_version=`grep ro.parrot.build.uid /etc/build.prop | cut -d '-' -f 3`
bebop2_fw_version_numeric=${bebop2_fw_version//.}
if [ "$bebop2_fw_version_numeric" -ge "442" ]; then
	kernel_mods="4.4.2"
else
	kernel_mods="na"
fi
ulogger -s -t uavpal_bebop2 "... detected Bebop 2 firmware version ${bebop_fw_version}, trying to use kernel modules compiled for firmware ${kernel_mods}"

ulogger -s -t uavpal_bebop2 "... loading tunnel kernel module (for zerotier)"
insmod /data/ftp/uavpal/mod/${kernel_mods}/tun.ko

ulogger -s -t uavpal_bebop2 "... loading E3372 firmware 21.x kernel modules (required for detection)"
insmod /data/ftp/uavpal/mod/${kernel_mods}/usb_wwan.ko
insmod /data/ftp/uavpal/mod/${kernel_mods}/option.ko

ulogger -s -t uavpal_bebop2 "... loading iptables kernel modules (required for security)"
insmod /data/ftp/uavpal/mod/${kernel_mods}/iptable_filter.ko

# Security: block incoming connections on the Internet interfaces (ppp* for E3372 firmware 21.x and eth1 for firmware 22.x)
# these connections should only be allowed on Wi-Fi (eth0) and via zerotier (zt*)
ulogger -s -t uavpal_bebop2 "... applying iptables security rules"
if_block='ppp+ eth1'
for i in $if_block
do
	iptables -I INPUT -p tcp -i $i --dport 21 -j DROP      # inetd (ftp:/data/ftp)
	iptables -I INPUT -p tcp -i $i --dport 23 -j DROP      # telnet
	iptables -I INPUT -p tcp -i $i --dport 51 -j DROP      # inetd (ftp:/update)
	iptables -I INPUT -p tcp -i $i --dport 61 -j DROP      # inetd (ftp:/data/ftp/internal_000/flightplans)
	iptables -I INPUT -p tcp -i $i --dport 873 -j DROP     # rsync
	iptables -I INPUT -p tcp -i $i --dport 8888 -j DROP    # dragon-prog
	iptables -I INPUT -p tcp -i $i --dport 9050 -j DROP    # adb
	iptables -I INPUT -p tcp -i $i --dport 44444 -j DROP   # dragon-prog
	iptables -I INPUT -p udp -i $i --dport 67 -j DROP      # dnsmasq
	iptables -I INPUT -p udp -i $i --dport 5353 -j DROP    # avahi-daemon
	iptables -I INPUT -p udp -i $i --dport 14551 -j DROP   # dragon-prog
done

ulogger -s -t uavpal_bebop2 "... running usb_modeswitch"
/data/ftp/uavpal/bin/usb_modeswitch -J -v 12d1 -p `lsusb |grep "ID 12d1" | cut -f 3 -d \:`

ulogger -s -t uavpal_bebop2 "... trying to detect 4G USB modem"
while true
do
	# -=-=-=-=-= Hi-Link Mode =-=-=-=-=-
	if [ -d "/proc/sys/net/ipv4/conf/eth1" ]; then
		huawei_mode="hilink"
		ulogger -s -t uavpal_bebop2 "... detected Huawei USB modem in Hi-Link mode"
		ulogger -s -t uavpal_bebop2 "... unloading E3372 firmware 21.x kernel modules (not required as Hi-Link was detected)"
		rmmod option
		rmmod usb_wwan
		ulogger -s -t uavpal_bebop2 "... bringing up Hi-Link network interface"
		ifconfig eth1 up
		ulogger -s -t uavpal_bebop2 "... requesting IP address from modem's DHCP server"
		hilink_ip=`udhcpc -i eth1 -n -t 10 2>&1 |grep obtained | awk '{ print $4 }'`
		hilink_router_ip=$(echo `echo $hilink_ip | cut -d '.' -f 1,2,3`.1)
		ulogger -s -t uavpal_bebop2 "... setting IP and route"
		ifconfig eth1 ${hilink_ip} netmask 255.255.255.0
		ip route add default via ${hilink_router_ip} dev eth1
		ulogger -s -t uavpal_bebop2 "... enabling Hi-Link DMZ mode (1:1 NAT for better zerotier performance)"
		export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/data/ftp/uavpal/lib
		sessionInfo=`/data/ftp/uavpal/bin/curl -s -X GET "http://${hilink_router_ip}/api/webserver/SesTokInfo"`
		cookie=`echo "$sessionInfo" | grep "SessionID=" | cut -b 10-147`
		token=`echo "$sessionInfo" | grep "TokInfo" | cut -b 10-41`
		/data/ftp/uavpal/bin/curl -s -X POST "http://${hilink_router_ip}/api/security/dmz" -d "<request><DmzStatus>1</DmzStatus><DmzIPAddress>${hilink_ip}</DmzIPAddress></request>" -H "Cookie: $cookie" -H "__RequestVerificationToken: $token"
		ulogger -s -t uavpal_bebop2 "... starting hilink script to inform SC2 of drone's WAN IP"
		/data/ftp/uavpal/bin/uavpal_hilink.sh ${hilink_router_ip} &
		break 1 # break out of while loop
	fi

	# -=-=-=-=-= Stick Mode =-=-=-=-=-
	if [ -c "/dev/ttyUSB0" ]; then
		huawei_mode="stick"
		ulogger -s -t uavpal_bebop2 "... detected Huawei USB modem in Stick mode"
		ulogger -s -t uavpal_bebop2 "... loading ppp kernel modules"
		insmod /data/ftp/uavpal/mod/${kernel_mods}/crc-ccitt.ko
		insmod /data/ftp/uavpal/mod/${kernel_mods}/slhc.ko
		insmod /data/ftp/uavpal/mod/${kernel_mods}/ppp_generic.ko
		insmod /data/ftp/uavpal/mod/${kernel_mods}/ppp_async.ko
		insmod /data/ftp/uavpal/mod/${kernel_mods}/ppp_deflate.ko
		insmod /data/ftp/uavpal/mod/${kernel_mods}/bsd_comp.ko
		ulogger -s -t uavpal_bebop2 "... running pppd to connect to LTE network"
		LD_PRELOAD=/data/ftp/uavpal/lib/libpam.so.0:/data/ftp/uavpal/lib/libpcap.so.0.8:/data/ftp/uavpal/lib/libaudit.so.1 /data/ftp/uavpal/bin/pppd call lte
		break 1 # break out of while loop
	fi
	sleep 1
done

ulogger -s -t uavpal_bebop2 "... setting DNS servers statically (to Google)"
echo -e 'nameserver 8.8.8.8\nnameserver 8.8.4.4' >/etc/resolv.conf

ulogger -s -t uavpal_bebop2 "... waiting for Internet connection"
while true; do
	if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
		ulogger -s -t uavpal_bebop2 "... Internet connection is up"
		break # break out of loop
	fi
done

ulogger -s -t uavpal_bebop2 "... setting date/time using ntp"
ntpd -n -d -q

ulogger -s -t uavpal_bebop2 "... starting glympse script for GPS tracking"
/data/ftp/uavpal/bin/uavpal_glympse.sh $huawei_mode &

ulogger -s -t uavpal_bebop2 "... starting zerotier daemon"
/data/ftp/uavpal/bin/zerotier-one -d

if [ ! -d "/data/lib/zerotier-one/networks.d" ]; then
	ulogger -s -t uavpal_bebop2 "... (initial-)joining zerotier network ID"
	while true
	do
		ztjoin_response=`/data/ftp/uavpal/bin/zerotier-one -q join $(head -1 /data/ftp/uavpal/conf/zt_networkid |tr -d '\r\n' |tr -d '\n')`
		if [ "`echo $ztjoin_response |head -n1 |awk '{print $1}')`" == "200" ]; then
			ulogger -s -t uavpal_bebop2 "... successfully joined zerotier network ID"
			break # break out of loop
		else
			ulogger -s -t uavpal_bebop2 "... ERROR joining zerotier network ID: $ztjoin_response - trying again"
			sleep 1
		fi
	done
fi
ulogger -s -t uavpal_bebop2 "*** idle on LTE ***"
