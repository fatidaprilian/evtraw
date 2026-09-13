#!/system/bin/sh

MODDIR=${0%/*}

until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done
sleep 10

log -p i -t RTI "Starting (aarch64)..."

if [ "$(uname -m)" != "aarch64" ]; then
    log -p e -t RTI "ERROR: Architecture $(uname -m) is not supported (aarch64 only)"
    exit 1
fi

chmod +x "$MODDIR/bin/RTI--aarch64"
"$MODDIR/bin/RTI--aarch64"

if command -v resetprop >/dev/null 2>&1; then
    resetprop windowsmgr.max_events_per_sec 200
else
    setprop windowsmgr.max_events_per_sec 200
fi

# Self-heal: retry companion app install if it failed during module flash
if [ -f "$MODDIR/.apk_pending" ] && [ -f "$MODDIR/RTIapp.apk" ]; then
    if pm install --user 0 -r "$MODDIR/RTIapp.apk" >/dev/null 2>&1 || \
       pm install -r "$MODDIR/RTIapp.apk" >/dev/null 2>&1; then
        log -p i -t RTI "Companion app installed (boot retry)."
        rm -f "$MODDIR/.apk_pending" "$MODDIR/RTIapp.apk"
    else
        log -p e -t RTI "Companion app install still failing; will retry next boot."
    fi
fi

log -p i -t RTI "Applied"
