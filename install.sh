SKIPMOUNT=false
PROPFILE=true
POSTFSDATA=true
LATESTARTSERVICE=true
REPLACE="
"


# Detect bundled companion APK in the installation archive
if unzip -l "$ZIPFILE" 2>/dev/null | grep -qE '[[:space:]]evtraw\.apk$'; then
  APK_NAME="evtraw.apk"
  PKG="fatidaprilian.evtraw"
elif unzip -l "$ZIPFILE" 2>/dev/null | grep -qE '[[:space:]]RTIapp\.apk$'; then
  APK_NAME="RTIapp.apk"
  PKG="com.rti.idc"
else
  APK_NAME=""
  PKG=""
fi

install_apk() {
  [ -z "$APK_NAME" ] && return 0
  [ ! -f "$MODPATH/$APK_NAME" ] && return 0

  # Clean up legacy companion package if migrating to evtraw
  if [ "$PKG" = "fatidaprilian.evtraw" ]; then
    if pm list packages 2>/dev/null | grep -q "com.rti.idc"; then
      ui_print "- Migrating from legacy RTI companion..."
      pm uninstall com.rti.idc >/dev/null 2>&1 || true
    fi
  fi

  ui_print "- Installing EvtRaw companion app (LSPosed module)..."

  # Attempt direct installation/upgrade
  if pm install --user 0 -r "$MODPATH/$APK_NAME" >/dev/null 2>&1 || \
     pm install -r "$MODPATH/$APK_NAME" >/dev/null 2>&1; then
    ui_print "  -> App installed successfully."
    rm -f "$MODPATH/$APK_NAME"
  else
    # Check if failed due to signature mismatch from a previously installed build
    if [ -n "$PKG" ] && pm list packages 2>/dev/null | grep -q "$PKG"; then
      ui_print "  -> [!] Signature conflict detected with existing app."
      ui_print "  -> Clean reinstalling companion app..."
      pm uninstall "$PKG" >/dev/null 2>&1 || pm uninstall --user 0 "$PKG" >/dev/null 2>&1
      if pm install --user 0 -r "$MODPATH/$APK_NAME" >/dev/null 2>&1 || \
         pm install -r "$MODPATH/$APK_NAME" >/dev/null 2>&1; then
        ui_print "  -> App reinstalled successfully."
        rm -f "$MODPATH/$APK_NAME"
        return 0
      fi
    fi

    ui_print "  -> [!] App install deferred; will retry at boot."
    touch "$MODPATH/.apk_pending"
    # Retain APK in MODPATH so service.sh can retry at boot
  fi
}

print_modname() {
  MODNAME=`grep_prop name $TMPDIR/module.prop`
  MODVER=`grep_prop version $TMPDIR/module.prop`
  AUTHOR=`grep_prop author $TMPDIR/module.prop`
  Device=`getprop ro.product.device`
  Model=`getprop ro.product.model`
  Brand=`getprop ro.product.brand`

  ui_print "-------------------------------------"
  ui_print "- Module: $MODNAME"
  ui_print "- Author: $AUTHOR"
  ui_print "- Version: $MODVER"

  if [ "$BOOTMODE" ] && [ "$KSU" ]; then
    ui_print "- Provider: KernelSU"
    ui_print "- KernelSU: $KSU_KERNEL_VER_CODE (kernel) + $KSU_VER_CODE (ksud)"
  elif [ "$BOOTMODE" ] && [ "$MAGISK_VER_CODE" ]; then
    ui_print "- Provider: Magisk"
  elif [ "$BOOTMODE" ] && [ "$APATCH" ]; then
    ui_print "- Provider: APatch"
  else
    ui_print "*********************************************************"
    ui_print "! Install from recovery is not supported"
    ui_print "! Please install from KernelSU, Magisk, or APatch manager"
    abort    "*********************************************************"
  fi

  ui_print "-------------------------------------"
  ui_print "- Brand: $Brand"
  ui_print "- Device: $Device"
  ui_print "- Model: $Model"
  ui_print "-------------------------------------"
}

on_install() {
  ui_print "- Extracting module files..."
  unzip -o "$ZIPFILE" 'system/*' -d $MODPATH >&2
  unzip -o "$ZIPFILE" 'rti.webp' -d $MODPATH >&2
  unzip -o "$ZIPFILE" 'service.sh' -d $MODPATH >&2
  unzip -o "$ZIPFILE" 'post-fs-data.sh' -d $MODPATH >&2
  unzip -o "$ZIPFILE" 'uninstall.sh' -d $MODPATH >&2
  unzip -o "$ZIPFILE" 'bin/RTI--aarch64' -d $MODPATH >&2
  unzip -o "$ZIPFILE" 'system.prop' -d $MODPATH >&2
  unzip -o "$ZIPFILE" "$APK_NAME" -d $MODPATH >&2

  ui_print " "
  ui_print "- Architecture: aarch64"
  ui_print "- Scanning for multitouch input digitizer..."


  TOUCH_DEV=""

  for event in /dev/input/event*; do
    if getevent -il "$event" 2>/dev/null | grep -q "ABS_MT_POSITION_X"; then
      TOUCH_DEV=$(getevent -il "$event" 2>/dev/null | grep "name:" | cut -d '"' -f 2)
      break
    fi
  done

  if [ -n "$TOUCH_DEV" ]; then
    ui_print "  -> Detected touchscreen digitizer: [$TOUCH_DEV]"

    IDC_DIR="$MODPATH/system/usr/idc"
    mkdir -p "$IDC_DIR"

    # If detected device is not fts_ts, copy template to match detected device name
    if [ "$TOUCH_DEV" != "fts_ts" ]; then
      cp "$IDC_DIR/rairin_touch.idc" "$IDC_DIR/${TOUCH_DEV}.idc" 2>/dev/null || true
      ui_print "  -> Generated IDC mapping for: ${TOUCH_DEV}.idc"
    else
      ui_print "  -> Native fts_ts.idc mapping active."
    fi
  else
    ui_print "  -> [!] Multitouch device name not detected via evdev."
    ui_print "  -> Using default IDC configuration."
  fi

  ui_print " "
  install_apk
}

set_permissions() {
  set_perm_recursive $MODPATH 0 0 0755 0644
  set_perm_recursive $MODPATH/bin 0 0 0755 0755
}
