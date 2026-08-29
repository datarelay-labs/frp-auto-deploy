# frpctl command reference

`frpctl` is the everyday operator CLI. It does not add new backend behavior.
Existing tools (`frp-clients`, `frp-client-set`, `frp-create-client`, …) remain
the implementation.

Grammar:

```text
<verb> <resource> [target] [property] [value]
```

Host role decides which commands appear in Tab and help. Dual-role hosts see
the union. There is no `server …` / `client …` top-level namespace.

Tab completes the next word. `help <verb>` and incomplete commands show what
can come next. `↑` / `↓` walk this session only. History is never written to
disk (`~/.bash_history`, `~/.frpctl_history`, or `HISTFILE`).

`unset` removes stored metadata. `release` returns public port reservations.
`revoke` removes management identity. Those three are never aliases of each
other. There is no `delete client`.

---

## show

```text
show status
show version
show clients
show client <client>
show client <client> services
show client <client> tags
show enrollments
show audit
show upstream
show services
show info
```

`status` and `version` remain shortcuts for `show status` / `show version`.
Canonical help prefers the `show` form.

`show clients` reuses the existing client table. `show client <client>` reuses
`frp-client-info`.

## set

Server:

```text
set client <client> label <value>
set client <client> note <value>
set client <client> tag <key>=<value>
```

Client:

```text
set service <service-id> target-host <host>
set service <service-id> target-port <port>
set service <service-id> ssh-user <user>
set service <service-id> name <value>
```

Service IDs are immutable. Pending service edits become live only after
`apply`. Disable/enable reuse the same public port. Client-side disable does
not release the server reservation.

## unset

```text
unset client <client> label
unset client <client> note
unset client <client> tag <key>
```

Removes administrator metadata only. Display name falls back to hostname.
Does not change identity, hostname, machine-id, ports, or enrollment.

## create / add

```text
create enrollment [--one-line] [--ssh --ssh-user USER --label NAME]
create enrollments --count N
create enrollments --csv clients.csv
create backup [path]
add service [--preset ssh|http|https|custom] ...
```

Enrollment Code and bootstrap ticket secrets are never completed or shown by
`show` / Tab.

## enable / disable / apply / discard

```text
enable service <service-id>
disable service <service-id>
apply
discard
```

Client-local pending changes. `apply` does not release server ports.

## revoke / release / restore

```text
revoke client <client>
revoke enrollment <ticket-id>
release service <client> <service-id>
release client <client>
restore backup <path>
```

`release` keeps the existing confirmation, locking, and passive port recheck.
`restore` keeps archive validation, snapshot, restart, doctor, and rollback.

## update

```text
update project [--check]
update frp [--check]
```

`update` with no resource keeps the previous role default (client project
tools on a client; `frp-update` on a server). Updater security is unchanged:
stable tag, verified SHA256SUMS, fail-closed, rollback, no re-enrollment, no
CA/token/port loss. FRP stays pinned at 0.70.1.

## Other

```text
doctor
help
help show
help set client
help legacy
menu
history
clear
exit
```

`?` is `help`. `menu` is the guided numbered interface using the same
vocabulary (Show / Set / Unset / Create / Update / Revoke / Release).

---

## Compatibility aliases

These still work for scripts and muscle memory. Tab and canonical help hide
them. `help legacy` lists them.

| Alias | Canonical |
| --- | --- |
| `clients` | `show clients` |
| `client` / `client-info` | `show client` |
| `client-set` / `edit-client` | `set client` / `unset client` |
| `enroll` / `create-client` | `create enrollment` |
| `enroll-bulk` | `create enrollments` |
| `enrollments` | `show enrollments` |
| `enrollment-revoke` | `revoke enrollment` |
| `revoke` / `revoke-client` | `revoke client` |
| `release-service` | `release service` |
| `release-client` | `release client` |
| `project-update` / `client-update` | `update project` |
| `frp-update` / `server-update` | `update frp` |
| `backup` | `create backup` |
| `restore PATH` | `restore backup PATH` |
| `upstream` | `show upstream` |
| `audit` | `show audit` |
| `services` / `manage` / `info` | `show services` / `add`+`set service` / `show info` |
| `status` / `version` | `show status` / `show version` |

Direct `/usr/local/sbin/frp-*` tools are unchanged.
