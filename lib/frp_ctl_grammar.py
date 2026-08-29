#!/usr/bin/env python3
"""Safe frpctl tokenizer, command-tree help, and context-aware completion.

No eval, no glob, no variable expansion, no command substitution.
"""
from __future__ import annotations

import json
import sys

UNQUOTED_META = set("$`;|&><*?(){}[]")
LEGACY_COMMANDS = {
    "clients",
    "client",
    "client-info",
    "client-set",
    "edit-client",
    "enroll",
    "create-client",
    "enroll-bulk",
    "enrollments",
    "enrollment-revoke",
    "revoke-client",
    "release-service",
    "release-client",
    "project-update",
    "frp-update",
    "server-update",
    "client-update",
    "backup",
    "upstream",
    "audit",
    "services",
    "manage",
    "info",
    "client-status",
    "server-status",
}
SHELL_REJECT = {"shell", "exec", "bash", "sh", "system"}


class ParseError(ValueError):
    pass


def tokenize(line):
    """Split an operator line into tokens. Quotes group; metacharacters do not expand."""
    tokens = []
    buf = []
    quote = None
    escaped = False
    i = 0
    text = line if line is not None else ""
    while i < len(text):
        ch = text[i]
        if escaped:
            buf.append(ch)
            escaped = False
            i += 1
            continue
        if quote:
            if ch == "\\" and quote == '"':
                escaped = True
                i += 1
                continue
            if ch == quote:
                quote = None
                i += 1
                continue
            buf.append(ch)
            i += 1
            continue
        if ch in " \t":
            if buf:
                tokens.append("".join(buf))
                buf = []
            i += 1
            continue
        if ch in "'\"":
            quote = ch
            i += 1
            continue
        if ch == "\\":
            escaped = True
            i += 1
            continue
        if ch == "?" and not buf:
            nxt = text[i + 1] if i + 1 < len(text) else ""
            if nxt in ("", " ", "\t"):
                tokens.append("?")
                i += 1
                continue
        if ch in UNQUOTED_META:
            raise ParseError(
                "shell metacharacters are not expanded. Quote the value or remove %r."
                % ch
            )
        buf.append(ch)
        i += 1
    if quote:
        raise ParseError("unclosed quote")
    if escaped:
        raise ParseError("trailing backslash")
    if buf:
        tokens.append("".join(buf))
    return tokens


def looks_secret(line):
    lowered = (line or "").lower()
    needles = (
        "ticket",
        "secret",
        "password",
        "passwd",
        "token",
        "private key",
        "enroll-secret",
        "bootstrap",
        "begin ",
    )
    return any(item in lowered for item in needles)


def quote_token(token):
    text = "" if token is None else str(token)
    if not text:
        return '""'
    if any(ch in text for ch in ' \t\'"'):
        return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return text


def _role_parts(role):
    role = (role or "").strip().lower()
    client = role in ("client", "both", "dual")
    server = role in ("server", "both", "dual")
    return client, server


def canonical_verbs(role):
    client, server = _role_parts(role)
    verbs = [
        "show",
        "help",
        "menu",
        "history",
        "clear",
        "exit",
        "doctor",
        "status",
        "version",
        "update",
    ]
    if server:
        verbs.extend(["set", "unset", "create", "revoke", "release", "restore"])
    if client:
        verbs.extend(["add", "enable", "disable", "apply", "discard", "set"])
    return sorted(set(verbs))


def _show_resources(role):
    client, server = _role_parts(role)
    items = ["status", "version"]
    if server:
        items.extend(["clients", "client", "enrollments", "audit", "upstream"])
    if client:
        items.extend(["services", "info"])
    return items


def _set_resources(role):
    client, server = _role_parts(role)
    items = []
    if server:
        items.extend(["client", "installer-url"])
    if client:
        items.append("service")
    return items


def _create_resources(role):
    _, server = _role_parts(role)
    if server:
        return ["enrollment", "enrollments", "backup"]
    return []


def incomplete(title, usage_lines, available=None, examples=None):
    parts = [title, "", "Usage:"]
    for line in usage_lines:
        parts.append("  %s" % line)
    if available:
        parts.extend(["", "Available:"])
        for item in available:
            parts.append("  %s" % item)
    if examples:
        parts.extend(["", "Examples:"])
        for item in examples:
            parts.append("  %s" % item)
    return {"status": "incomplete", "message": "\n".join(parts)}


def help_text(tokens, role):
    tokens = [t for t in tokens if t and t != "help"]
    client, server = _role_parts(role)
    if not tokens:
        return _root_help(role)
    verb = tokens[0]
    if verb == "legacy":
        return _legacy_help(role)
    if verb == "show":
        return _show_help(tokens[1:], role)
    if verb == "set":
        return _set_help(tokens[1:], role)
    if verb == "unset":
        return _unset_help(role)
    if verb == "create":
        return _create_help(role)
    if verb == "update":
        return _update_help(role)
    if verb in ("revoke", "release", "restore", "add", "enable", "disable"):
        return _verb_help(verb, role)
    if verb == "doctor":
        return (
            "Doctor\n======\n\nUsage:\n  doctor\n  doctor --json\n  doctor --verbose\n"
        )
    lines = [
        "Unknown help topic: %s" % " ".join(tokens),
        "",
        "Type 'help' for the command tree, or 'help legacy' for compatibility aliases.",
    ]
    if client or server:
        pass
    return "\n".join(lines) + "\n"


def _root_help(role):
    client, server = _role_parts(role)
    lines = [
        "FRP Auto Deploy CLI",
        "===================",
        "",
        "Grammar: <verb> <resource> [target] [property] [value]",
        "",
        "Discover commands with Tab. Type 'help <verb>' for details.",
        "",
        "Show",
        "  show status",
        "  show version",
    ]
    if server:
        lines.extend(
            [
                "  show clients",
                "  show client <client>",
                "  show client <client> services",
                "  show client <client> tags",
                "  show enrollments",
                "  show audit",
                "  show upstream",
            ]
        )
    if client:
        lines.extend(["  show services", "  show info"])
    lines.extend(["", "Configure"])
    if server:
        lines.extend(
            [
                "  set client <client> label <value>",
                "  set client <client> note <value>",
                "  set client <client> tag <key>=<value>",
                "  unset client <client> label",
                "  unset client <client> note",
                "  unset client <client> tag <key>",
            ]
        )
    if client:
        lines.extend(
            [
                "  add service",
                "  set service <id> target-host <host>",
                "  set service <id> target-port <port>",
                "  set service <id> ssh-user <user>",
                "  set service <id> name <value>",
                "  enable service <id>",
                "  disable service <id>",
                "  apply",
                "  discard",
            ]
        )
    lines.extend(["", "Lifecycle"])
    if server:
        lines.extend(
            [
                "  create enrollment [--ssh --ssh-user USER --label NAME]",
                "  create enrollments --count N",
                "  create backup",
                "  revoke enrollment <id>",
                "  revoke client <client>",
                "  release service <client> <service-id>",
                "  release client <client>",
                "  restore backup <path>",
            ]
        )
    lines.extend(
        [
            "  update project [--check]",
        ]
    )
    if server:
        lines.append("  update frp [--check]")
    lines.extend(
        [
            "",
            "Other",
            "  doctor",
            "  menu                 Guided numbered menu",
            "  history              This session only (not saved to disk)",
            "  help, ?",
            "  help legacy          Compatibility aliases",
            "  clear",
            "  exit",
            "",
            "status and version remain shortcuts for show status / show version.",
        ]
    )
    return "\n".join(lines) + "\n"


def _show_help(rest, role):
    if not rest:
        avail = _show_resources(role)
        return (
            "Show information\n"
            "================\n\n"
            "Usage:\n  show <resource> ...\n\n"
            "Available:\n  " + "\n  ".join(avail) + "\n"
        )
    topic = rest[0]
    if topic == "client":
        return (
            "Show client information\n"
            "=======================\n\n"
            "Usage:\n"
            "  show client <client>\n"
            "  show client <client> services\n"
            "  show client <client> tags\n\n"
            "Examples:\n"
            "  show client aella\n"
            "  show client aella services\n"
        )
    return "Usage:\n  show %s\n" % topic


def _set_help(rest, role):
    if rest and rest[0] == "client":
        return (
            "Set client configuration\n"
            "========================\n\n"
            "Usage:\n"
            "  set client <client> label <value>\n"
            "  set client <client> note <value>\n"
            "  set client <client> tag <key>=<value>\n\n"
            "Examples:\n"
            "  set client aella label production\n"
            "  set client aella note \"Seoul production gateway\"\n"
            "  set client aella tag env=prod\n\n"
            "To remove a setting:\n"
            "  unset client <client> ...\n"
        )
    if rest and rest[0] == "service":
        return (
            "Set service configuration\n"
            "=========================\n\n"
            "Usage:\n"
            "  set service <service-id> target-host <host>\n"
            "  set service <service-id> target-port <port>\n"
            "  set service <service-id> ssh-user <user>\n"
            "  set service <service-id> name <value>\n\n"
            "Service IDs cannot be renamed. Pending changes are live only after apply.\n"
        )
    avail = _set_resources(role)
    return (
        "Set configuration\n"
        "=================\n\n"
        "Usage:\n  set <resource> ...\n\n"
        "Available:\n  " + "\n  ".join(avail or ["(none for this host role)"]) + "\n"
    )


def _unset_help(role):
    return (
        "Unset client configuration\n"
        "==========================\n\n"
        "Usage:\n"
        "  unset client <client> label\n"
        "  unset client <client> note\n"
        "  unset client <client> tag <key>\n\n"
        "unset removes metadata only. It does not release ports or revoke identity.\n"
    )


def _create_help(role):
    return (
        "Create\n"
        "======\n\n"
        "Usage:\n"
        "  create enrollment [--one-line] [--ssh --ssh-user USER --label NAME]\n"
        "  create enrollments --count N\n"
        "  create enrollments --csv clients.csv\n"
        "  create backup [path]\n"
    )


def _update_help(role):
    _, server = _role_parts(role)
    lines = [
        "Update\n======\n\nUsage:\n  update project [--check]",
    ]
    if server:
        lines.append("  update frp [--check]")
    lines.append("\nA software update does not re-enroll clients or rotate CA/token/ports.\n")
    return "\n".join(lines)


def _verb_help(verb, role):
    mapping = {
        "revoke": (
            "Revoke\n======\n\nUsage:\n"
            "  revoke client <client>\n"
            "  revoke enrollment <ticket-id>\n\n"
            "revoke client removes management identity and keeps port reservations.\n"
        ),
        "release": (
            "Release\n=======\n\nUsage:\n"
            "  release service <client> <service-id>\n"
            "  release client <client>\n\n"
            "release returns public port reservations. It is not revoke or unset.\n"
        ),
        "restore": "Restore\n=======\n\nUsage:\n  restore backup <path>\n",
        "add": (
            "Add service\n===========\n\nUsage:\n"
            "  add service [--preset ssh|http|https|custom] [--id ID] [--name NAME]\n"
            "              [--target-host HOST] [--target-port PORT] [--ssh-user USER]\n\n"
            "Pending until apply. Does not release server-side reservations.\n"
        ),
        "enable": "Enable service\n==============\n\nUsage:\n  enable service <service-id>\n",
        "disable": (
            "Disable service\n===============\n\nUsage:\n  disable service <service-id>\n\n"
            "The public reservation remains until release service.\n"
        ),
    }
    return mapping.get(verb, "Usage:\n  %s\n" % verb)


def _legacy_help(role):
    return (
        "Compatibility aliases\n"
        "=====================\n\n"
        "These older commands still work for scripts. Tab completion and\n"
        "canonical help hide them.\n\n"
        "  clients, client, client-info, client-set, edit-client\n"
        "  enroll, create-client, enroll-bulk, enrollments, enrollment-revoke\n"
        "  revoke NAME, revoke-client, release-service, release-client\n"
        "  project-update, frp-update, server-update, client-update\n"
        "  backup, restore PATH, upstream, audit\n"
        "  services, manage, info, client-status, server-status\n"
        "  status, version, update\n"
    )


def match(tokens, role):
    if not tokens:
        return {"status": "empty"}
    verb = tokens[0]
    if verb.startswith("!") or verb in SHELL_REJECT:
        return {"status": "shell"}
    if verb in LEGACY_COMMANDS:
        return {"status": "legacy"}
    client, server = _role_parts(role)
    handlers = {
        "show": _match_show,
        "set": _match_set,
        "unset": _match_unset,
        "create": _match_create,
        "revoke": _match_revoke,
        "release": _match_release,
        "update": _match_update,
        "restore": _match_restore,
        "add": _match_add,
        "enable": _match_enable_disable,
        "disable": _match_enable_disable,
        "apply": lambda toks, role: {"status": "ok", "action": "apply"},
        "discard": lambda toks, role: {"status": "ok", "action": "discard"},
        "doctor": lambda toks, role: {"status": "ok", "action": "doctor", "passthrough": toks[1:]},
        "help": lambda toks, role: {"status": "ok", "action": "help", "passthrough": toks[1:]},
        "?": lambda toks, role: {"status": "ok", "action": "help", "passthrough": toks[1:]},
        "menu": lambda toks, role: {"status": "ok", "action": "menu"},
        "history": lambda toks, role: {"status": "ok", "action": "history"},
        "clear": lambda toks, role: {"status": "ok", "action": "clear"},
        "exit": lambda toks, role: {"status": "ok", "action": "exit"},
        "quit": lambda toks, role: {"status": "ok", "action": "exit"},
        "q": lambda toks, role: {"status": "ok", "action": "exit"},
        "status": lambda toks, role: {"status": "ok", "action": "show_status", "passthrough": toks[1:]},
        "version": lambda toks, role: {"status": "ok", "action": "show_version"},
    }
    fn = handlers.get(verb)
    if fn is None:
        return {"status": "unknown", "command": verb}
    if verb in ("set", "unset", "create", "revoke", "release", "restore") and not server and verb != "set":
        if verb == "set" and client:
            return fn(tokens, role)
        return {"status": "role", "need": "server", "command": verb}
    if verb in ("add", "enable", "disable", "apply", "discard") and not client:
        return {"status": "role", "need": "client", "command": verb}
    return fn(tokens, role)


def _match_show(tokens, role):
    avail = _show_resources(role)
    if len(tokens) == 1:
        return incomplete(
            "Missing resource.",
            ["show <resource>"],
            avail,
        )
    resource = tokens[1]
    if resource == "status":
        return {"status": "ok", "action": "show_status", "passthrough": tokens[2:]}
    if resource == "version":
        return {"status": "ok", "action": "show_version"}
    if resource == "clients":
        return {"status": "ok", "action": "show_clients", "passthrough": tokens[2:]}
    if resource == "enrollments":
        return {"status": "ok", "action": "show_enrollments"}
    if resource == "audit":
        return {"status": "ok", "action": "show_audit"}
    if resource == "upstream":
        return {"status": "ok", "action": "show_upstream", "passthrough": tokens[2:]}
    if resource == "services":
        return {"status": "ok", "action": "show_services"}
    if resource == "info":
        return {"status": "ok", "action": "show_info"}
    if resource == "client":
        if len(tokens) < 3:
            return incomplete(
                "Missing client.",
                [
                    "show client <client>",
                    "show client <client> services",
                    "show client <client> tags",
                ],
            )
        view = tokens[3] if len(tokens) > 3 else "info"
        if view not in ("info", "services", "tags"):
            return incomplete(
                "Unknown client view.",
                [
                    "show client <client>",
                    "show client <client> services",
                    "show client <client> tags",
                ],
                ["services", "tags"],
            )
        return {
            "status": "ok",
            "action": "show_client",
            "client": tokens[2],
            "view": "info" if view == "info" else view,
        }
    return incomplete("Unknown show resource.", ["show <resource>"], avail)


def _match_set(tokens, role):
    client, server = _role_parts(role)
    avail = _set_resources(role)
    if len(tokens) == 1:
        return incomplete("Missing resource.", ["set <resource> ..."], avail)
    resource = tokens[1]
    if resource == "client":
        if not server:
            return {"status": "role", "need": "server", "command": "set client"}
        if len(tokens) < 3:
            return incomplete(
                "Missing client.",
                [
                    "set client <client> label <value>",
                    "set client <client> note <value>",
                    "set client <client> tag <key>=<value>",
                ],
            )
        if len(tokens) < 4:
            return incomplete(
                "Missing client setting.",
                [
                    "set client <client> label <value>",
                    "set client <client> note <value>",
                    "set client <client> tag <key>=<value>",
                ],
                ["label", "note", "tag"],
            )
        prop = tokens[3]
        if prop not in ("label", "note", "tag"):
            return incomplete(
                "Unknown client setting.",
                [
                    "set client <client> label <value>",
                    "set client <client> note <value>",
                    "set client <client> tag <key>=<value>",
                ],
                ["label", "note", "tag"],
            )
        if len(tokens) < 5:
            return incomplete(
                "Missing %s value." % prop,
                ["set client <client> %s <value>" % prop],
            )
        value = tokens[4]
        if len(tokens) > 5:
            return {
                "status": "error",
                "message": "Too many arguments. Quote values that contain spaces.",
            }
        return {
            "status": "ok",
            "action": "set_client",
            "client": tokens[2],
            "property": prop,
            "value": value,
        }
    if resource == "service":
        if not client:
            return {"status": "role", "need": "client", "command": "set service"}
        props = ["target-host", "target-port", "ssh-user", "name"]
        if len(tokens) < 3:
            return incomplete("Missing service ID.", ["set service <service-id> <property> <value>"])
        if len(tokens) < 4:
            return incomplete(
                "Missing service property.",
                ["set service <service-id> <property> <value>"],
                props,
            )
        if tokens[3] not in props:
            return incomplete("Unknown service property.", ["set service <id> <property> <value>"], props)
        if len(tokens) < 5:
            return incomplete("Missing value.", ["set service <id> %s <value>" % tokens[3]])
        return {
            "status": "ok",
            "action": "set_service",
            "service": tokens[2],
            "property": tokens[3],
            "value": tokens[4],
        }
    if resource == "installer-url":
        if not server:
            return {"status": "role", "need": "server", "command": "set installer-url"}
        if len(tokens) < 3:
            return incomplete("Missing installer URL.", ["set installer-url <url>"])
        return {"status": "ok", "action": "set_installer_url", "value": tokens[2]}
    return incomplete("Unknown set resource.", ["set <resource> ..."], avail)


def _match_unset(tokens, role):
    _, server = _role_parts(role)
    if not server:
        return {"status": "role", "need": "server", "command": "unset"}
    if len(tokens) < 2:
        return incomplete("Missing resource.", ["unset client <client> <setting>"], ["client"])
    if tokens[1] != "client":
        return incomplete("Unknown unset resource.", ["unset client <client> <setting>"], ["client"])
    if len(tokens) < 3:
        return incomplete(
            "Missing client.",
            [
                "unset client <client> label",
                "unset client <client> note",
                "unset client <client> tag <key>",
            ],
        )
    if len(tokens) < 4:
        return incomplete(
            "Missing client setting.",
            [
                "unset client <client> label",
                "unset client <client> note",
                "unset client <client> tag <key>",
            ],
            ["label", "note", "tag"],
        )
    prop = tokens[3]
    if prop not in ("label", "note", "tag"):
        return incomplete("Unknown client setting.", ["unset client <client> label|note|tag"], ["label", "note", "tag"])
    if prop == "tag" and len(tokens) < 5:
        return incomplete("Missing tag key.", ["unset client <client> tag <key>"])
    return {
        "status": "ok",
        "action": "unset_client",
        "client": tokens[2],
        "property": prop,
        "value": tokens[4] if prop == "tag" else "",
    }


def _match_create(tokens, role):
    _, server = _role_parts(role)
    if not server:
        return {"status": "role", "need": "server", "command": "create"}
    avail = _create_resources(role)
    if len(tokens) == 1:
        return incomplete("Missing resource.", ["create <resource>"], avail)
    resource = tokens[1]
    if resource == "enrollment":
        return {"status": "ok", "action": "create_enrollment", "passthrough": tokens[2:]}
    if resource == "enrollments":
        return {"status": "ok", "action": "create_enrollments", "passthrough": tokens[2:]}
    if resource == "backup":
        return {"status": "ok", "action": "create_backup", "passthrough": tokens[2:]}
    return incomplete("Unknown create resource.", ["create <resource>"], avail)


def _match_revoke(tokens, role):
    if len(tokens) == 1:
        return incomplete(
            "Missing resource.",
            ["revoke client <client>", "revoke enrollment <ticket-id>"],
            ["client", "enrollment"],
        )
    if tokens[1] == "client":
        if len(tokens) < 3:
            return incomplete("Missing client.", ["revoke client <client>"])
        return {"status": "ok", "action": "revoke_client", "client": tokens[2], "passthrough": tokens[3:]}
    if tokens[1] == "enrollment":
        if len(tokens) < 3:
            return incomplete("Missing enrollment id.", ["revoke enrollment <ticket-id>"])
        return {"status": "ok", "action": "revoke_enrollment", "id": tokens[2]}
    # Compatibility: `revoke <client>` without the resource word.
    return {
        "status": "ok",
        "action": "revoke_client",
        "client": tokens[1],
        "passthrough": tokens[2:],
    }


def _match_release(tokens, role):
    if len(tokens) == 1:
        return incomplete(
            "Missing resource.",
            ["release service <client> <service-id>", "release client <client>"],
            ["service", "client"],
        )
    if tokens[1] == "client":
        if len(tokens) < 3:
            return incomplete("Missing client.", ["release client <client>"])
        return {"status": "ok", "action": "release_client", "client": tokens[2], "passthrough": tokens[3:]}
    if tokens[1] == "service":
        if len(tokens) < 3:
            return incomplete("Missing client.", ["release service <client> <service-id>"])
        if len(tokens) < 4:
            return incomplete("Missing service ID.", ["release service <client> <service-id>"])
        return {
            "status": "ok",
            "action": "release_service",
            "client": tokens[2],
            "service": tokens[3],
            "passthrough": tokens[4:],
        }
    return incomplete("Unknown release resource.", ["release service|client"], ["service", "client"])


def _match_update(tokens, role):
    _, server = _role_parts(role)
    if len(tokens) == 1:
        return {"status": "ok", "action": "update_default"}
    resource = tokens[1]
    if resource in ("project", "frp") or resource.startswith("-"):
        if resource.startswith("-"):
            return {"status": "ok", "action": "update_default", "passthrough": tokens[1:]}
        action = "update_project" if resource == "project" else "update_frp"
        if resource == "frp" and not server:
            return {"status": "role", "need": "server", "command": "update frp"}
        return {"status": "ok", "action": action, "passthrough": tokens[2:]}
    avail = ["project"] + (["frp"] if server else [])
    return incomplete("Unknown update target.", ["update project [--check]", "update frp [--check]"], avail)


def _match_restore(tokens, role):
    if len(tokens) == 1 or (len(tokens) == 2 and tokens[1] == "backup"):
        if len(tokens) == 1:
            return incomplete("Missing resource.", ["restore backup <path>"], ["backup"])
        return incomplete("Missing backup path.", ["restore backup <path>"])
    if tokens[1] == "backup":
        return {"status": "ok", "action": "restore_backup", "path": tokens[2], "passthrough": tokens[3:]}
    return {"status": "ok", "action": "restore_backup", "path": tokens[1], "passthrough": tokens[2:]}


def _match_add(tokens, role):
    if len(tokens) == 1 or tokens[1] != "service":
        return incomplete("Missing resource.", ["add service ..."], ["service"])
    return {"status": "ok", "action": "add_service", "passthrough": tokens[2:]}


def _match_enable_disable(tokens, role):
    verb = tokens[0]
    if len(tokens) < 2 or tokens[1] != "service":
        return incomplete("Missing resource.", ["%s service <service-id>" % verb], ["service"])
    if len(tokens) < 3:
        return incomplete("Missing service ID.", ["%s service <service-id>" % verb])
    return {"status": "ok", "action": "%s_service" % verb, "service": tokens[2]}


def completion_candidates(line, role, names, services, local_services, trailing=None):
    try:
        tokens = tokenize(line)
    except ParseError:
        return []
    if trailing is None:
        trailing = bool(line) and line[-1] in " \t"
    if not tokens:
        return canonical_verbs(role)
    if tokens[0].startswith("!") or tokens[0] in SHELL_REJECT:
        return []
    if not trailing and len(tokens) == 1:
        prefix = tokens[0]
        return [v for v in canonical_verbs(role) if v.startswith(prefix)]
    verb = tokens[0]
    if verb in LEGACY_COMMANDS:
        return _legacy_completion(tokens, trailing, role, names, services)
    return _canonical_completion(tokens, trailing, role, names, services, local_services)


def _current_prefix(tokens, trailing):
    if trailing:
        return ""
    return tokens[-1] if tokens else ""


def _filter(items, prefix):
    return [item for item in items if item.startswith(prefix)]


def _canonical_completion(tokens, trailing, role, names, services, local_services):
    client, server = _role_parts(role)
    prefix = _current_prefix(tokens, trailing)
    filled = tokens if trailing else tokens[:-1]
    if not filled:
        return _filter(canonical_verbs(role), prefix)
    verb = filled[0]
    if verb == "help":
        topics = ["show", "set", "unset", "create", "update", "revoke", "release", "legacy"]
        if len(filled) == 1:
            return _filter(topics, prefix)
        if filled[1] == "show" and len(filled) == 2:
            return _filter(_show_resources(role), prefix)
        if filled[1] == "set" and len(filled) == 2:
            return _filter(_set_resources(role), prefix)
        return []
    if verb == "show":
        if len(filled) == 1:
            return _filter(_show_resources(role), prefix)
        if filled[1] == "client" and server:
            if len(filled) == 2:
                return _filter(names, prefix)
            if len(filled) == 3:
                return _filter(["services", "tags"], prefix)
        return []
    if verb == "set":
        if len(filled) == 1:
            return _filter(_set_resources(role), prefix)
        if filled[1] == "client" and server:
            if len(filled) == 2:
                return _filter(names, prefix)
            if len(filled) == 3:
                return _filter(["label", "note", "tag"], prefix)
        if filled[1] == "service" and client:
            if len(filled) == 2:
                return _filter(local_services, prefix)
            if len(filled) == 3:
                return _filter(["target-host", "target-port", "ssh-user", "name"], prefix)
        return []
    if verb == "unset":
        if len(filled) == 1:
            return _filter(["client"], prefix)
        if filled[1] == "client":
            if len(filled) == 2:
                return _filter(names, prefix)
            if len(filled) == 3:
                return _filter(["label", "note", "tag"], prefix)
        return []
    if verb == "create":
        if len(filled) == 1:
            return _filter(_create_resources(role), prefix)
        if filled[1] == "enrollment":
            return _filter(
                ["--one-line", "--ssh", "--ssh-user", "--ssh-port", "--ttl", "--note", "--label", "--client-name"],
                prefix,
            )
        if filled[1] == "enrollments":
            return _filter(["--count", "--csv", "--label-prefix", "--ssh-user", "--note", "--ttl"], prefix)
        return []
    if verb == "revoke":
        if len(filled) == 1:
            return _filter(["client", "enrollment"], prefix)
        if filled[1] == "client" and len(filled) == 2:
            return _filter(names, prefix)
        return []
    if verb == "release":
        if len(filled) == 1:
            return _filter(["client", "service"], prefix)
        if filled[1] == "client" and len(filled) == 2:
            return _filter(names, prefix)
        if filled[1] == "service":
            if len(filled) == 2:
                return _filter(names, prefix)
            if len(filled) == 3:
                return _filter(services.get(filled[2], []), prefix)
        return []
    if verb == "update":
        if len(filled) == 1:
            items = ["project", "--check"]
            if server:
                items.append("frp")
            return _filter(items, prefix)
        if filled[1] in ("project", "frp"):
            return _filter(["--check"], prefix)
        return []
    if verb == "restore":
        if len(filled) == 1:
            return _filter(["backup"], prefix)
        return []
    if verb in ("add", "enable", "disable"):
        if len(filled) == 1:
            return _filter(["service"], prefix)
        if verb == "add" and filled[1] == "service":
            return _filter(
                ["--preset", "--id", "--name", "--target-host", "--target-port", "--ssh-user"],
                prefix,
            )
        if verb in ("enable", "disable") and filled[1] == "service" and len(filled) == 2:
            return _filter(local_services, prefix)
        return []
    if verb == "doctor":
        return _filter(["--json", "--verbose", "--quiet"], prefix)
    return []


def _legacy_completion(tokens, trailing, role, names, services):
    prefix = _current_prefix(tokens, trailing)
    filled = tokens if trailing else tokens[:-1]
    cmd = filled[0] if filled else tokens[0]
    if cmd in ("client", "client-info", "revoke", "revoke-client", "release-client") and len(filled) == 1:
        return _filter(names, prefix)
    if cmd in ("client-set", "edit-client"):
        if len(filled) == 1:
            return _filter(names, prefix)
        return _filter(["--label", "--note", "--tag", "--remove-tag"], prefix)
    if cmd == "release-service":
        if len(filled) == 1:
            return _filter(names, prefix)
        if len(filled) == 2:
            return _filter(services.get(filled[1], []), prefix)
        return []
    if cmd in ("enroll", "create-client"):
        return _filter(
            ["--one-line", "--ssh", "--ssh-user", "--ssh-port", "--ttl", "--note", "--client-name", "--label"],
            prefix,
        )
    if cmd == "doctor":
        return _filter(["--json", "--verbose", "--quiet"], prefix)
    return []


def complete_line(line, role, names, services, local_services):
    trailing = bool(line) and line[-1:] in " \t"
    cands = completion_candidates(line, role, names, services, local_services, trailing=trailing)
    if not cands:
        return line
    if len(cands) == 1:
        return _replace_last(line, quote_token(cands[0]), add_space=True)
    shared = cands[0]
    for item in cands[1:]:
        while shared and not item.startswith(shared):
            shared = shared[:-1]
    prefix = ""
    try:
        tokens = tokenize(line)
        if tokens and not trailing:
            prefix = tokens[-1]
    except ParseError:
        prefix = ""
    if shared and shared != prefix:
        return _replace_last(line, shared, add_space=False)
    return line


def _replace_last(line, token, add_space):
    stripped = line.rstrip()
    if not stripped:
        new = token
    elif line[-1:] in " \t":
        new = stripped + " " + token
    else:
        try:
            tokens = tokenize(stripped)
        except ParseError:
            tokens = stripped.split()
        if len(tokens) <= 1:
            new = token
        else:
            head = stripped
            # Remove the last whitespace-separated raw suffix conservatively.
            idx = len(stripped)
            while idx > 0 and stripped[idx - 1] not in " \t":
                idx -= 1
            new = stripped[:idx] + token
    if add_space:
        new += " "
    return new


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        raise SystemExit("usage: frp_ctl_grammar.py tokenize|match|help|complete|complete-line ...")
    cmd = argv[0]
    if cmd == "tokenize":
        line = argv[1] if len(argv) > 1 else sys.stdin.read()
        try:
            tokens = tokenize(line)
        except ParseError as exc:
            sys.stderr.write("ERROR: %s\n" % exc)
            raise SystemExit(2)
        json.dump(tokens, sys.stdout)
        sys.stdout.write("\n")
        return 0
    payload = {}
    if not sys.stdin.isatty():
        raw = sys.stdin.read()
        if raw.strip():
            payload = json.loads(raw)
    role = payload.get("role") or (argv[2] if len(argv) > 2 else "server")
    names = payload.get("names") or []
    services = payload.get("services") or {}
    local_services = payload.get("local_services") or []
    if cmd == "match":
        tokens = payload.get("tokens") or argv[1:]
        json.dump(match(tokens, role), sys.stdout)
        sys.stdout.write("\n")
        return 0
    if cmd == "help":
        tokens = payload.get("tokens") or argv[1:]
        sys.stdout.write(help_text(tokens, role))
        return 0
    if cmd == "complete":
        line = payload.get("line") or (argv[1] if len(argv) > 1 else "")
        for item in completion_candidates(line, role, names, services, local_services):
            sys.stdout.write(item + "\n")
        return 0
    if cmd == "complete-line":
        line = payload.get("line") or (argv[1] if len(argv) > 1 else "")
        sys.stdout.write(complete_line(line, role, names, services, local_services))
        return 0
    raise SystemExit("unknown grammar action")


if __name__ == "__main__":
    raise SystemExit(main())
