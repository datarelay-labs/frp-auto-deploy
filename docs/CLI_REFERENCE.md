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

Interactive keys:

```text
Tab   = immediately show/complete what can be entered here
?     = detailed contextual explanation
Enter = execute
↑/↓   = session history
```

Tab completes a unique match inline. When several next tokens remain, the
first Tab prints the candidate list above the prompt and restores the exact
input line for editing. A second Tab on the same unchanged line does not
reprint the list. Tab never runs the command and never clears the screen.
Type `?` (then Enter) for detailed context help when needed.

`↑` / `↓` walk this session only. History is never written to disk
(`~/.bash_history`, `~/.frpctl_history`, or `HISTFILE`).

The canonical client selector is **CLIENT ID**: the immutable short machine
identity (usually 8 hex characters; longer when that prefix is not unique).
Changing label, note, tags, or hostname never changes CLIENT ID.
`show clients` prints CLIENT ID as the first identity column. Tab completes
CLIENT ID only. Mutation commands (`set` / `unset` / `revoke` / `release`)
require CLIENT ID. A unique label or unique hostname is accepted for
`show` / `show client` only. An SSH connection string such as
`user@host:port` is not a selector. An ambiguous prefix fails closed; use a
longer CLIENT ID prefix.

`unset` removes stored metadata. `release` frees public port reservations and
keeps the client management record (`services` becomes `{}`). `revoke` removes
management identity and keeps reservations. Those three are never aliases of
each other. There is no `delete client`.

---

## show

```text
show status
show version
show clients
show client <ID>
show client <ID> services
show client <ID> tags
show enrollments
show audit
show upstream
show services
show info
```

`status` and `version` remain shortcuts for `show status` / `show version`.
Canonical help prefers the `show` form.

`show clients` reuses the existing client table. The identity columns are
CLIENT ID, LABEL, and HOSTNAME. `show client <ID>` is the overview.
`show client <ID> services` and `show client <ID> tags` print only that view.

`show enrollments` lists every issued enrollment credential that is still on
disk: manual Enrollment Code records and zero-touch bootstrap tickets. Secrets
are never printed. Zero-touch issuance that creates both an enrollment file and
a bootstrap ticket appears once (ticket ID). Lifecycle states are normalized to
`pending`, `bound`, `completed`, `expired`, or `revoked`. Completed and expired
records remain visible until existing retention/cleanup removes them
(`cleanup_expired_bootstrap_tickets` currently retains ticket metadata for
audit). Use the non-secret enrollment ID with `revoke enrollment <ID>`.

## set

Server:

```text
set client <ID> label <value>
set client <ID> note <value>
set client <ID> tag <key> <value>
```

The backend still accepts `--tag key=value`. The parser converts
`tag <key> <value>` to that form. Quoted values work
(`tag location "OCI Osaka"`). The older `tag key=value` token is still
accepted.

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
unset client <ID> label
unset client <ID> note
unset client <ID> tag <key>
```

Removes administrator metadata only. Display label falls back to hostname.
Does not change identity, hostname, machine-id, ports, or enrollment.

## create / add

```text
create zero-touch
create enrollment [--one-line] [--ssh --ssh-user USER --label NAME]
create enrollments --count N
create enrollments --csv clients.csv
create backup [path]
add service [--preset ssh|http|https|rdp|custom] ...
```

`create zero-touch` is the recommended everyday client onboarding path.
It prompts for client platform (Linux or Windows), then service shortcuts
(SSH only / RDP only / Configure services). Non-interactive issuance supports
`--platform linux|windows` and `--rdp` on `frp-create-client`.
Enrollment Code and bootstrap ticket secrets are never completed or shown by
`show` / `?` / Tab.

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
revoke client <ID>
revoke enrollment <ID>
release service <ID> <service-id>
release client <ID>
restore backup <path>
```

`release` keeps the existing confirmation, locking, and passive port recheck.
Releasing the last service (or `release client`) leaves a management-only
client record with `services: {}`; it does not delete the client.
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
?
show ?
set client <ID> ?
menu
history
clear
exit
```

Root `?` lists verbs only. Detailed syntax is under `help` / `help <verb>`
or a context `?`. `menu` is the guided numbered interface using the same
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

---

## Client lifecycle (client hosts)

Canonical command: `sudo frpctl`. Friendly alias: `sudo frpcli` (identical behavior).

```text
pause
resume
restart
test
logs [--lines N] [--follow]
support-bundle [--anonymize] [--output PATH]
uninstall [--yes]
```

- **pause** stops `frpc` and records persistent local state; identity, services, and server reservations are preserved.
- **resume** clears pause state and restores prior autostart semantics.
- **restart** is refused while paused (`Use 'frpctl resume' to reconnect.`).
- **test** is read-only; external public reachability is reported as `NOT TESTED` when it cannot be verified safely.
- **support-bundle** never includes private keys, tokens, enrollment codes, or bootstrap tickets.
- **uninstall** removes local software only. It is not `revoke client` (identity) or `release client` (ports).

Root (or Administrator on Windows) is required for mutating lifecycle commands.
