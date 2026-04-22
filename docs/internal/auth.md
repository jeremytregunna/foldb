# Authentication

FoldDB uses token-based authentication. Tokens are derived offline via HMAC-SHA256; the server never stores passwords or the derivation secret at runtime.

## Auth model

### Token derivation

```
token = base64-std(HMAC-SHA256(key=auth_secret, msg=name + ":" + password))
```

`auth_secret` is a server-side pepper — a random 32-byte value, base64-encoded in the config. It is combined with the user's name and password at enrollment time to produce a bearer token. The token is what the client presents on the wire; the server stores only the token, never `auth_secret` at runtime (it is only needed during `add-user`).

### Open mode vs. enforced mode

- **Open mode** (`users` list is empty): server advertises both `None` (`0x00`) and `Token` (`0x02`) auth methods. Either is accepted; no credential is checked.
- **Enforced mode** (`users` list is non-empty): server advertises only `Token`. Clients must present a token matching an entry in the `users` list. `None` is rejected with `Error(AuthFailed, Fatal)`.

### Constant-time comparison

Token comparison uses a branchless XOR accumulator that always scans every configured user entry. This prevents timing attacks from revealing which entry matched.

### No plain-text auth

The `Plain` method (`0x01`) is removed from the wire protocol. Servers do not advertise it; clients must not send it. Token transport over non-TLS is permitted by the protocol implementation but strongly discouraged — use TLS in production to protect tokens in transit.

---

## Invariants

1. `auth_secret` is never loaded into the gateway, executor, or storage layer — only in the CLI commands `gen-secret` and `add-user`.
2. The server's `users` slice contains only pre-derived tokens; no crypto happens per-connection.
3. Failed auth closes the connection immediately with `Error(AuthFailed, Fatal)`. No partial session is possible.

---

## Operator workflow

### Generate a server secret

Run once when setting up a new node:

```sh
foldb gen-secret
```

Output:

```
Add this to your config:
  "auth_secret": "<base64-encoded 32 bytes>"

Keep auth_secret secure -- anyone with it can derive valid tokens.
```

Add the `auth_secret` value to your config JSON. Do not share it; rotate it by running `gen-secret` again and re-enrolling all users.

### Add a user

```sh
foldb add-user --config /path/to/config.json --name alice --password hunter2
```

Output:

```
Token for 'alice': <base64 token>

Add this entry to your config's "users" array:
  {"name": "alice", "token": "<base64 token>"}

Give the token to the client. It will not be shown again.
```

Steps:
1. Run the command — it reads `auth_secret` from the config and derives the token.
2. Copy the printed JSON snippet into the `users` array in your config file.
3. Give the token string to the client operator; it is the credential the client presents on the wire.
4. Restart the server (or hot-reload config, if supported) for the new entry to take effect.

The token is a one-way derivative — you cannot recover it from the config later. If a client loses their token, re-run `add-user` to derive a new one and update the config.

### Remove a user

Manual edit — there is no CLI command for removal:

1. Open the config JSON.
2. Delete the `{"name": "...", "token": "..."}` entry from the `users` array.
3. Restart the server.

The removed user's token is immediately invalid after restart. In-flight connections are not terminated; they complete normally and the client receives `AuthFailed` on the next reconnect.

### Rotate auth_secret

Rotating `auth_secret` invalidates **all existing tokens**:

1. Run `foldb gen-secret` to produce a new secret.
2. Replace `auth_secret` in the config.
3. Re-run `foldb add-user` for every user to derive new tokens.
4. Distribute the new tokens to clients.
5. Restart the server.

Plan for a maintenance window — clients with old tokens are locked out immediately after restart.

---

## Config reference

```json
{
  "auth_secret": "<base64 32-byte value from gen-secret>",
  "users": [
    {"name": "alice", "token": "<token from add-user>"},
    {"name": "bob",   "token": "<token from add-user>"}
  ]
}
```

If `auth_secret` is omitted or empty, `foldb add-user` will refuse to run. If `users` is omitted or empty, the server starts in open mode.
