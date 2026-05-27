' Launches the Logitech charge/low watcher hidden (no console flash) at logon.
CreateObject("WScript.Shell").Run _
  "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\Users\lskorospelov\Tools\LGSTray\charge-notify.ps1""", _
  0, False
