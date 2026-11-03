# Security Policy

taskviz runs a small web server on `127.0.0.1` that can run, stop, enable and disable scheduled tasks,
so security issues are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue** for security problems.
Report them privately through GitHub's
[private vulnerability reporting](https://github.com/KMYsqHRK/taskviz/security/advisories/new).

Include what you found, how to reproduce it, and the Windows / PowerShell versions you used.
You should get a first response within a week.

## Scope

In scope, for example:

- anything that lets another machine, another local user, or a web page reach or control the server
- bypassing the per-launch token, the Host header check, or the loopback-only binding
- script injection through task names, descriptions or commands shown on the page

Out of scope:

- the security check missing a particular malicious task, or flagging a legitimate one
  (please open a normal issue for these; the check is a heuristic, not an antivirus)
- actions a user deliberately takes on their own tasks through the page

## Supported versions

Only the latest commit on `main` is supported.
