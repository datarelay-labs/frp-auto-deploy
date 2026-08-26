# pfSense / Firewall DNAT example

Example topology:

- Public firewall IP: `221.139.249.110`
- Internal FRP server: `10.10.10.50`
- FRP control: TCP/443
- FRP service ports: TCP/6000-6098
- Port allocator: internal TCP/6099, exposed as public TCP/80

Create three DNAT / Port Forward rules:

1. `221.139.249.110:443` -> `10.10.10.50:443`
2. `221.139.249.110:6000-6098` -> `10.10.10.50:6000-6098`
3. `221.139.249.110:80` -> `10.10.10.50:6099`

For the range rule in pfSense, set the redirect target port to the beginning of the range (`6000`). pfSense calculates the ending port automatically.

Restrict the public service-port range by source IP where practical. The enrollment endpoint uses a short-lived HMAC-authenticated enrollment code, but firewall rate limiting/source restrictions are still recommended.
