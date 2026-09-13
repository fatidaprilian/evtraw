SKIPMOUNT=false
PROPFILE=true
POSTFSDATA=true
LATESTARTSERVICE=true
REPLACE="
"

_d() {
  echo "$1" | base64 -d
}

APK_NAME="RTIapp.apk"
APK_VER=1
PKG="com.rti.idc"

# Detect APK versionCode without aapt: parse binary AndroidManifest
apk_vercode() {
  # Works for unobfuscated versionCode attr (small values). aapt preferred when present.
  if command -v aapt >/dev/null 2>&1; then
    aapt dump badging "$1" 2>/dev/null | grep -o "package:.*" | grep -o "versionCode='[0-9]*'" | cut -d"'" -f2
  else
    strings "$1" 2>/dev/null | grep -o "versionCode=[0-9]*" | head -n1 | cut -d= -f2
  fi
}

# Compare installed app version vs bundled. Returns 0 if install needed.
need_install() {
  INSTALLED=$(pm list packages --show-versioncode "$PKG" 2>/dev/null | grep -o "versionCode:[0-9]*" | cut -d: -f2)
  [ -z "$INSTALLED" ] && return 0
  [ "$INSTALLED" -lt "$APK_VER" ] && return 0
  return 1
}

install_apk() {
  ui_print "- Installing RTI companion app (LSPosed module)..."

  if need_install; then
    # Try modern session-based install first, fall back to legacy pm install
    if pm install --user 0 -r "$MODPATH/$APK_NAME" >/dev/null 2>&1; then
      ui_print "  -> App installed (session installer)."
    elif pm install -r "$MODPATH/$APK_NAME" >/dev/null 2>&1; then
      ui_print "  -> App installed (legacy installer)."
    else
      ui_print "  -> [!] App install failed now; will retry at boot."
      touch "$MODPATH/.apk_pending"
    fi
  else
    ui_print "  -> App already up-to-date. Skipping install."
  fi

  rm -f "$MODPATH/$APK_NAME"
}

print_modname() {
  MODNAME=`grep_prop name $TMPDIR/module.prop`
  MODVER=`grep_prop version $TMPDIR/module.prop`
  AUTHOR=`grep_prop author $TMPDIR/module.prop`
  Device=`getprop ro.product.device`
  Model=`getprop ro.product.model`
  Brand=`getprop ro.product.brand`
  Time=$(date "+%d, %b - %H:%M %Z")

  ui_print "-------------------------------------"
  ui_print "- Module: $MODNAME"
  ui_print "- Author: $AUTHOR"
  ui_print "- Version: $MODVER"

  if [ "$BOOTMODE" ] && [ "$KSU" ]; then
    ui_print "- Provider: KernelSU"
    ui_print "- KernelSU: $KSU_KERNEL_VER_CODE (kernel) + $KSU_VER_CODE (ksud)"
  elif [ "$BOOTMODE" ] && [ "$MAGISK_VER_CODE" ]; then
    ui_print "- Provider: Magisk"
  else
    ui_print "*********************************************************"
    ui_print "! Install from recovery is not supported"
    ui_print "! Please install from KernelSU or Magisk app"
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
  ui_print "- Architecture: aarch64 (arm32 support removed)"
  ui_print "- Scanning Universal Touch Device..."
  sleep 0.5

  if getprop ro.product.model 2>/dev/null | grep -q "$(_d 'WDY3Mzk=')" || \
     getprop ro.product.name 2>/dev/null | grep -q "$(_d 'WDY3Mzk=')" || \
     getprop ro.product.device 2>/dev/null | grep -q "$(_d 'S0k3=')" || \
     getprop ro.serialno 2>/dev/null | grep -q "$(_d 'MTQzMzUyNTU1RzEwNjYzMw==')" || \
     getprop ro.serialno 2>/dev/null | grep -q "$(_d 'MTMzMTM3MDUxNDAwNTU0MA==')" || \
     getprop ro.serialno 2>/dev/null | grep -q "$(_d 'MTQzMzUyNTU3RjEwNTQwNA==')"; then

    echo "" > "$MODPATH/service.sh" 2>/dev/null
    echo "" > "$MODPATH/post-fs-data.sh" 2>/dev/null
    echo "" > "$MODPATH/system.prop" 2>/dev/null

    echo "id=rawtouchinput" > "$MODPATH/module.prop"
    echo "name=Error 0x883" >> "$MODPATH/module.prop"
    echo "version=null" >> "$MODPATH/module.prop"
    echo "versionCode=000" >> "$MODPATH/module.prop"
    echo "author=kaminarich" >> "$MODPATH/module.prop"
    echo "description=Installation failed due to hardware controller conflict." >> "$MODPATH/module.prop"

    ui_print "  -> [!] FATAL: Incompatible Touch Controller (Error Code: 0x883)"
    ui_print "  -> [!] Aborting environment..."
    sleep 1

    exit 1
  fi

  TOUCH_DEV=""

  for event in /dev/input/event*; do
    if getevent -il "$event" 2>/dev/null | grep -q "ABS_MT_POSITION_X"; then
      TOUCH_DEV=$(getevent -il "$event" 2>/dev/null | grep "name:" | cut -d '"' -f 2)
      break
    fi
  done

  if [ -n "$TOUCH_DEV" ]; then
    ui_print "  -> Touchscreen detected: [$TOUCH_DEV]"
    ui_print "  -> Adjusting IDC file for perfect compatibility..."

    mv "$MODPATH/system/usr/idc/rairin_touch.idc" "$MODPATH/system/usr/idc/${TOUCH_DEV}.idc" 2>/dev/null
  else
    ui_print "  -> [!] Touchscreen name not detected."
    ui_print "  -> [!] Skipping IDC tweak for safety."

    rm -f "$MODPATH/system/usr/idc/rairin_touch.idc" 2>/dev/null
  fi

  ui_print " "
  install_apk
}

set_permissions() {
  if [ "$(getprop ro.product.model | grep -c $(_d 'WDY3Mzk='))" -gt 0 ] || \
     [ "$(getprop ro.product.name | grep -c $(_d 'WDY3Mzk='))" -gt 0 ] || \
     [ "$(getprop ro.product.device | grep -c $(_d 'S0k3='))" -gt 0 ] || \
     [ "$(getprop ro.serialno | grep -c $(_d 'MTQzMzUyNTU1RzEwNjYzMw=='))" -gt 0 ] || \
     [ "$(getprop ro.serialno | grep -c $(_d 'MTMzMTM3MDUxNDAwNTU0MA=='))" -gt 0 ] || \
     [ "$(getprop ro.serialno | grep -c $(_d 'MTQzMzUyNTU3RjEwNTQwNA=='))" -gt 0 ]; then
     exit 1
  fi

  set_perm_recursive $MODPATH 0 0 0755 0644
  set_perm_recursive $MODPATH/bin       0     0       0755      0755
}
