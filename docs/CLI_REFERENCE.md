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
Changing label, note, tags, groups, or hostname never changes CLIENT ID.
`show clients` prints CLIENT ID as the first identity column. Tab completes
CLIENT ID only. Mutation commands (`set` / `unset` / `revoke` / `release` /
`add client … group` / `remove client … group`) require CLIENT ID. A unique
label or unique hostname is accepted for `show` / `show client` only. An SSH
connection string such as `user@host:port` is not a selector. An ambiguous
prefix fails closed; use a longer CLIENT ID prefix.

Group membership uses immutable **GROUP ID** (`grp_` + 8 hex). A unique group
name is accepted as a read shortcut when unambiguous. Renaming a group does
not change GROUP ID or membership.

`unset` removes stored metadata. `release` frees public port reservations and
keeps the client management record (`services` becomes `{}`). `revoke` removes
management identity and keeps reservations. `remove` drops group membership or
deletes a group object. Those are never aliases of each other. There is no
`delete client`.

---

## show

```text
show status
show version
show clients
show clients --tag KEY=VALUE
show clients --group <GROUP>
show client <ID>
show client <ID> services
show client <ID> tags
show client <ID> groups
show groups
show group <GROUP>
show group <GROUP> clients
show enrollments
show audit
show upstream
show services
show info
```

`status` and `version` remain shortcuts for `show status` / `show version`.
Canonical help prefers the `show` form.

`show clients` reuses the existing client table. The identity columns are
CLIENT ID, LABEL, and HOSTNAME. Group membership is not expanded into extra
rows; use `show client <ID> groups` or `show group <GROUP> clients`.
`show clients --group` is a read-only filter (combinable with `--tag`).

`show enrollments` lists every issued enrollment credential that is still on
disk: manual Enrollment Code records and zero-touch bootstrap tickets. Secrets
are never printed. Zero-touch issuance that creates both an enrollment file and
a bootstrap ticket appears once (ticket ID). Lifecycle states are normalized to
`pending`, `bound`, `completed`, `expired`, or `revoked`. Terminal records
(`expired`, `completed`, `revoked`) are retained for
`enrollment_retention_days` (default 30) and then removed automatically during
enrollment issuance or allocator startup. Use `revoke enrollment <ID>` for active
(`pending`/`bound`) credentials and `purge enrollment <ID>` for terminal records.

## set

Server:

```text
set client <ID> label <value>
set client <ID> note <value>
set client <ID> tag <key> <value>
set group <GROUP> name <new-name>
set group <GROUP> description <value>
```

The backend still accepts `--tag key=value`. The parser converts
`tag <key> <value>` to that form. Quoted values work
(`tag location "OCI Osaka"`). The older `tag key=value` token is still
accepted.

`set group … name` renames a group without changing GROUP ID or membership.

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

## create / add / remove

```text
create zero-touch
create enrollment [--one-line] [--ssh --ssh-user USER --label NAME]
create enrollments --count N
create enrollments --csv clients.csv
create group <name> [--description VALUE]
create backup [path]
add client <ID> group <GROUP>
add service [--preset ssh|http|https|rdp|custom] ...
remove client <ID> group <GROUP>
remove group <GROUP>
```

`create group` allocates an immutable GROUP ID (`grp_…`). Names `all` and
`ungrouped` are reserved for future system groups. Multiple group membership
is supported. `remove group` deletes the group object and clears membership
references only; it never changes CLIENT ID, management identity, services, or
ports.

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

## revoke / purge / release / restore

```text
revoke client <ID>
revoke enrollment <ID>
purge enrollment <ID>
purge enrollments --older-than <days>
release service <ID> <service-id>
release client <ID>
restore backup <path>
```

`revoke enrollment` prevents a pending or bound enrollment credential from being
used. It does not apply to terminal records (`expired`, `completed`, `revoked`).

`purge enrollment` permanently removes terminal enrollment metadata. Active
pending or bound enrollments must be revoked first. Bulk purge matches terminal
records whose terminal timestamp is older than the requested threshold.

Terminal enrollment JSON retention and audit log retention are separate.
Purging enrollment metadata does not delete audit events.

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
