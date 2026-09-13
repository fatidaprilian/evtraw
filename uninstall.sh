#!/system/bin/sh
settings delete secure long_press_timeout
settings delete secure multi_press_timeout
resetprop --delete windowsmgr.max_events_per_sec 2>/dev/null
pm uninstall --user 0 com.rti.idc >/dev/null 2>&1

exit 0
