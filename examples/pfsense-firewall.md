# pfSense / Firewall DNAT example

The addresses below are RFC documentation examples. Replace them with your firewall and internal FRP server addresses.

Example topology:

- Public firewall IP: `203.0.113.10`
- Internal FRP server: `192.0.2.50`
- FRP control: TCP/443
- FRP service ports: TCP/6000-6098
- Port allocator: internal TCP/6099, exposed as public TCP/80

Create three DNAT / Port Forward rules:

1. `203.0.113.10:443` -> `192.0.2.50:443`
2. `203.0.113.10:6000-6098` -> `192.0.2.50:6000-6098`
3. `203.0.113.10:80` -> `192.0.2.50:6099`

For the range rule in pfSense, set the redirect target port to the beginning of the range (`6000`). pfSense calculates the ending port automatically.

Restrict the public service-port range by source IP where practical. The enrollment endpoint uses a short-lived HMAC-authenticated enrollment code, but firewall rate limiting/source restrictions are still recommended.
