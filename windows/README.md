# Windows status

FRP itself supports Windows (`frpc.exe`), but this v1.0 automation package intentionally automates Debian/Ubuntu Linux clients only.

Do not copy the server FRP token into a public PowerShell script. A Windows enrollment installer should use the same short-lived enrollment API and encrypted token delivery used by `install-client.sh`. This can be added as a later PowerShell implementation.
