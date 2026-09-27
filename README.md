# Folder-Locker 🔒

Folder-Locker is a lightweight Linux utility to lock and unlock folders with password protection via context menu and native double-click, powered by [gocryptfs](https://nuetzlich.net/gocryptfs/) and [Zenity](https://help.gnome.org/users/zenity/stable/).

Supported file managers: **Dolphin**, **Nemo**, and **Nautilus**.

---

## Features

- **Single Visible Item:** No duplicate or extra folders are shown in your file manager.
- **Double-Click to Open:** Simply double-click the locked folder to prompt for your password.
- **New Window:** Opens the decrypted files in a dedicated file manager window.
- **Auto-Lock on Close:** Automatically unmounts and re-locks the folder the moment you close its window.
- **Cascade Deletion:** Deleting the locked folder automatically removes its hidden encrypted vault, leaving no orphaned files.

---

## Installation

### Option 1: Via Launchpad PPA (Recommended)

```bash
sudo add-apt-repository ppa:danerlps/folder-locker
sudo apt update
sudo apt install folder-locker
```

### Option 2: Pre-built `.deb` Package

Download the latest release `.deb` package and install it with `apt`:

```bash
sudo apt install ./folder-locker_1.0.0-1_all.deb
```

---

## How to Use

1. **Lock a folder:**
   - Right-click any folder &rarr; select **Lock Folder**.
   - Enter and confirm your password in the single dialog.
   - The folder is locked and displays a locked folder icon.

2. **Open a locked folder:**
   - **Double-click** the locked folder.
   - Type your password when prompted.
   - A new file manager window opens with your files ready to view and edit.

3. **Re-lock the folder:**
   - Simply **close the folder window**.
   - Folder-Locker detects the closed window and locks the folder automatically.

4. **Delete a locked folder:**
   - Delete the locked folder item normally.
   - The hidden encrypted vault is automatically removed in the background.

---

## Build Package from Source

```bash
chmod +x build-deb.sh
./build-deb.sh
sudo apt install ./folder-locker_1.0.0-1_all.deb
```

---

## Uninstallation

```bash
sudo apt remove folder-locker
```
