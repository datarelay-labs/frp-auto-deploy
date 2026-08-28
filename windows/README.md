# Windows status

FRP itself supports Windows (`frpc.exe`), but this automation package
intentionally automates systemd-based Linux clients only.

Do not copy the server FRP token into a public PowerShell script. A Windows
enrollment installer should use the same short-lived enrollment API and
encrypted token delivery used by `install-client.sh`. That is out of scope
for this release.
