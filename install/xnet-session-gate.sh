#!/usr/bin/env bash
# xnet-session-gate — refuse an SSH login that would exceed the account's
# max_login, BEFORE the session is established.
#
# Invoked by PAM from the `account` stack:
#     account  required  pam_exec.so quiet /opt/xnet/xnet-session-gate
#
# Why this exists
# ---------------
# The panel used to enforce max_login only after the fact: a monitor pass
# noticed the extra session a few seconds later and killed it. From the
# customer's side that is not a limit, it is a fault — the client connects,
# appears to work, dies, reconnects, and loops. It also forks a new sshd for
# every attempt, which on a busy node is thousands of processes an hour and a
# flooded auth.log.
#
# Refusing at authentication time turns the same rule into a clean, immediate
# "too many logins" and the client stops trying.
#
# What counts as a session
# ------------------------
# One live sshd/dropbear session process for the account = one session = one
# slot. Not one device, not one source IP: two connections from one phone spend
# two slots, which is what max_login means to the operator selling it.
#
# The count is taken from the process table rather than from the panel, so the
# gate keeps working when the panel is restarting or down. A gate that fails
# open on its own bookkeeping is better than one that locks every customer out
# because a Go service is mid-restart.
#
# PAM contract: exit 0 permits, non-zero denies. Every unexpected condition
# exits 0 — see the note at the end.

set -uo pipefail

DB="/opt/xnet/data/xnet.db"

# Denials go to syslog, not to a file of our own.
#
# A private log file would be a third thing on this host that grows without
# supervision, and this panel has already been taken down once by exactly that
# — auth.log and syslog reaching several GB and filling the disk, after which
# SQLite could not even open its database. Adding another unrotated file and
# then writing a rotation rule for it is solving a problem we do not need to
# create.
#
# syslog is better on three counts, not just tidier:
#   - journald already caps its own size, and auth.log is covered by the
#     logrotate policy the installer installs. Nothing new to manage.
#   - the denial lands in the SAME stream as the sshd auth line it refers to, in
#     order, so "why was this customer refused?" is one journalctl away instead
#     of a correlation exercise across two files with two clocks.
#   - it works when /var/log is read-only or full, which is exactly when an
#     operator is trying to find out what is happening.
#
# Read them with:  journalctl -t xnet-session-gate
gate_log() {
    if command -v logger >/dev/null 2>&1; then
        logger -t xnet-session-gate -p authpriv.notice -- "$1" 2>/dev/null || true
    fi
}

# PAM passes the account being authenticated in PAM_USER.
USER_NAME="${PAM_USER:-}"
[ -n "$USER_NAME" ] || exit 0

# Only gate accounts the panel manages. A system/admin login must never be
# refused by this, whatever the database says.
case "$USER_NAME" in
  root|""|*[!a-zA-Z0-9._-]*) exit 0 ;;
esac

command -v sqlite3 >/dev/null 2>&1 || exit 0
[ -r "$DB" ] || exit 0

# max_login for this account. Absent row, empty value or 0 means unlimited.
limit="$(sqlite3 -readonly "$DB" \
  "SELECT COALESCE(max_login,0) FROM ssh_accounts WHERE username='${USER_NAME//\'/\'\'}' LIMIT 1;" \
  2>/dev/null | head -n1)"
[[ "$limit" =~ ^[0-9]+$ ]] || exit 0
[ "$limit" -gt 0 ] || exit 0

# Count the account's live session processes.
#
# `pgrep -u <user>` covers the unprivileged per-session children OpenSSH forks,
# which is one per established connection — the same thing the panel counts.
# The process for THIS login does not exist yet at account-stage PAM, so the
# count is of sessions already established: allowing while count < limit admits
# exactly `limit` of them.
current="$(pgrep -u "$USER_NAME" -c 2>/dev/null || echo 0)"
[[ "$current" =~ ^[0-9]+$ ]] || exit 0

if [ "$current" -ge "$limit" ]; then
  # One line per refusal, and refusals are self-limiting: the client is told no
  # at authentication time and stops, instead of being admitted and killed
  # seconds later in a loop that reconnected forever. That loop is what used to
  # generate the log volume; ending it is what keeps this quiet.
  gate_log "deny user=${USER_NAME} active=${current} max_login=${limit} rhost=${PAM_RHOST:-unknown}"
  exit 1
fi

exit 0

# Every failure path above exits 0 on purpose.
#
# This script sits in the authentication path of every SSH login on the host. A
# bug in it, a missing sqlite3, an unreadable database or a malformed value must
# not be able to lock every customer out — and it would, because PAM treats a
# non-zero exit as a denial. Failing open costs at most a temporarily
# unenforced limit, which the panel's monitor still catches within one pass.
# Failing closed costs the whole service.
