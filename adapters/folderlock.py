#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Folder-Locker Extension for GNOME Files (Nautilus)
Context menu provider for folder locking.
"""

import os
import subprocess
import urllib.parse

from gi import require_version
try:
    require_version('Nautilus', '4.0')
except (ValueError, ImportError):
    try:
        require_version('Nautilus', '3.0')
    except (ValueError, ImportError):
        pass

from gi.repository import Nautilus, GObject


class FolderLockExtension(GObject.GObject, Nautilus.MenuProvider):
    def __init__(self):
        super().__init__()

    def get_file_items(self, *args):
        """Nautilus hook to generate context menu items."""
        if not args:
            return []

        files = args[-1]
        if len(files) != 1:
            return []

        file_item = files[0]
        if not file_item.is_directory():
            return []

        uri = file_item.get_uri()
        if not uri or not uri.startswith('file://'):
            return []

        path = urllib.parse.unquote(uri[7:])
        if not os.path.isdir(path):
            return []

        # Context menu action: Lock Folder
        item = Nautilus.MenuItem(
            name="FolderLock::Lock",
            label="Lock Folder",
            tip="Lock folder with password (double-click to open)",
            icon="changes-prevent"
        )
        item.connect("activate", self._on_activate, "lock", path)

        return [item]

    def _on_activate(self, menu_item, action, path):
        subprocess.Popen(["/usr/bin/folderlock", action, path])
