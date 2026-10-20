#!/bin/sh
# English UI strings. Another language: copy this file to lib/i18n/<lang>.sh, translate the
# values and boot with retro.lang=<lang>. Keep the variable names; "\n" is a line break in
# dialog texts. Sourced by lib/common.sh.
# shellcheck disable=SC2034

T_BACKTITLE="retro-backup: rescue the files of an old PC (sources are read-only)"

# 10-devices.sh notes
T_DEV_ENCRYPTED="encrypted, cannot be read"
T_DEV_MOUNT_FAILED="could not be mounted read-only (damaged? use the shell: testdisk, photorec)"
T_DEV_SMART_FAILED="SMART health check FAILED: the disk may be dying, copy the most important things first"
T_DEV_NOTES_TITLE="Disk warnings"

# Scanning
T_SCAN_TITLE="Looking for your files"
T_SCAN_START="Starting the scan..."
T_SCAN_VOLUME="Scanning"
T_SCAN_FAILED="The scan failed. The log is on tty4 (Alt+F4) and in /run/retro/retro-backup.log."
T_STICK_WAIT="First boot on this pendrive: extending the RETRODATA partition to the whole stick..."
T_DEVICES_WAIT="Looking for disks and mounting them read-only..."
T_NO_VOLUMES="No readable disk was found.\n\nDisks that are damaged, encrypted or unformatted cannot be scanned. A shell is available on tty2 (Alt+F2): testdisk and photorec can rescue files from damaged disks."
T_NO_GROUPS="The disks were scanned but no user files were found."

# Overview checklist
T_LIST_TITLE="Select what to copy"
T_LIST_TEXT="Space: tick/untick. Enter: continue. Details: biggest files of the highlighted line.\nDisk Group                            Kind       Files     Size"
T_LIST_OK="Continue"
T_LIST_DETAILS="Details"
T_LIST_ALL="All/None"
T_LIST_MENU="Menu"
T_LIST_EMPTY="Nothing is ticked. Tick at least one line with the space bar."
T_CATEGORIES="photos:photos videos:videos documents:documents email:email music:music archives:archives other:other"

# Details
T_DETAILS_TITLE="Details"
T_DETAILS_PATH="Folder"
T_DETAILS_FILES="Files"
T_DETAILS_SIZE="Size"
T_DETAILS_TOP="Largest files"

# Menu
T_MENU_TITLE="Menu"
T_MENU_BACK="Back to the list"
T_MENU_RESCAN="Scan the disks again"
T_MENU_SHELL="Open a shell (type exit to come back)"
T_MENU_LOG="Show the log"
T_MENU_POWEROFF="Power off"
T_MENU_REBOOT="Reboot"

# Destination
T_DEST_TITLE="Where should the files go?"
T_DEST_TEXT="Choose the destination:"
T_DEST_RETRODATA="This pendrive (RETRODATA partition)"
T_DEST_DISK="Another USB disk or pendrive"
T_DEST_NET="Over the network to a computer running retro-helper"
T_DEST_BACK="Back to the list"
T_DEST_FREE="free"
T_DEST_PLUG="Plug in the USB disk now and wait 5 seconds, then press Enter."
T_DEST_PICK="Choose the disk to write to. Nothing will be deleted or formatted; the files go into a BACKUP folder."
T_DEST_REFRESH="(look again)"
T_DEST_NONE="No new disk found. Plug it in, wait a few seconds and choose \"look again\"."
T_DEST_MOUNT_FAILED="The disk could not be opened for writing:"
T_DEST_NTFS_HINT="An NTFS disk that Windows did not shut down cleanly (or that is hibernated) cannot be written. Use an exFAT or FAT32 disk, or the network."
T_NET_WAIT="Connecting to the network (DHCP) and looking for retro-helper..."
T_NET_NOADDR="No network address. Is the cable plugged in? Is there a router, or does retro-helper run in direct-cable mode?"
T_NET_ASK="retro-helper was not found automatically.\n\nType the address it shows on its screen (for example 192.168.1.23 or http://192.168.1.23:8080):"
T_NET_BAD="retro-helper does not answer at"
T_NET_PLAIN="Note: the network copy is plain HTTP, not encrypted. Use it on your own home network only."

# Confirm
T_CONFIRM_TITLE="Ready to copy"
T_CONFIRM_PROBE="Measuring the speed of the destination (10 seconds)..."
T_CONFIRM_GROUPS="Selected"
T_CONFIRM_GROUPS_UNIT="groups"
T_CONFIRM_FILES="files"
T_CONFIRM_FREE="Free space on the destination"
T_CONFIRM_SPEED="Speed"
T_CONFIRM_ETA="Estimated time"
T_CONFIRM_UNKNOWN="unknown"
T_CONFIRM_NOSPACE="WARNING: the selection is bigger than the free space. Untick something, or copy anyway and the rest will fail."
T_CONFIRM_START="Start copying"
T_CONFIRM_BACK="Back"

# Copy (40-copy.sh)
T_COPY_TITLE="Copying"
T_COPY_START="Starting..."
T_COPY_GROUP="Group"
T_COPY_ERRORS="errors"
T_COPY_CHECKSUMS="Computing checksums..."
T_COPY_SENT="sent"
T_COPY_FINISHING="Writing the log and flushing the disk..."

# Summary
T_SUM_TITLE="Done"
T_SUM_COPIED="Copied"
T_SUM_FAILED="Could not be copied (see the log)"
T_SUM_RENAMED="Renamed (characters not allowed on the destination)"
T_SUM_SKIPPED="Skipped (tab or newline in the name)"
T_SUM_MISMATCHED="Checksum mismatch on the helper"
T_SUM_DEST="Destination"
T_SUM_LOG="Log and list of files"
T_SUM_SAFE="The disk has been unmounted: it is safe to remove it."
T_SUM_NOTSAFE="The disk is still mounted; power off from this menu before removing it."
T_SUM_MORE="Copy more (back to the list)"

# Escape / shell
T_ESC_TITLE="Leave the menu?"
T_ESC_TEXT="Open a shell for manual work? Type exit to come back here.\n(The source disks stay mounted read-only under /mnt/src.)"
T_SHELL_HINT="retro-backup shell. Sources: /mnt/src (read-only). Destination: /mnt/dst. Type exit to return to the menu."
T_ERROR_TITLE="Error"
T_ERROR_STEP="This step failed:"
T_ERROR_RETRY="Try again"
