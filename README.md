# mysql-host-aliases

Resolve short host aliases for the MySQL client `-h` / `--host` flag — define them
once in your `.my.cnf`, then use them with any MySQL client tool, with bash & zsh
autocomplete.

```sh
# Instead of this:
mysql -h prod.cluster-abc123xyz.eu-central-1.rds.amazonaws.com -u admin

# just type this:
mysql -h prod -u admin
```

---

## The idea

A database host is often long, hard to remember, or easy to mistype. The classic
example is an Amazon Aurora / RDS endpoint:

```
prod.cluster-abc123xyz.eu-central-1.rds.amazonaws.com
```

But the same friction shows up everywhere:

- **Plain IP addresses** — `10.20.30.40`, `192.168.1.50`, an IPv6 address.
- **Internal DNS names** — `db-primary.svc.internal`, a Kubernetes service, a
  Docker Compose service name.
- **SSH tunnels / port-forwards** — you connect through `127.0.0.1` on some local
  port and can never remember which host it maps to.
- **Any other managed database** — Google Cloud SQL, Azure Database for MySQL,
  PlanetScale, a self-hosted box, etc.

You usually connect to a handful of these — `dev`, `qa`, `staging`, `prod`, maybe a
couple of one-offs — so you want to refer to them by a short, memorable name and
have the real host filled in for you. You also want this to work with the tools you
already use (`mysql`, `mysqldump`, `mysqlsh`, Percona toolkit, …) **without changing
how you call them** — you still type `-h <name>`.

The MySQL client tools can't do this themselves: they only read a fixed set of
option groups from `.my.cnf` (`[client]`, `[mysql]`, …) and have no concept of a
host alias. So the resolution has to happen *around* the tools, before the real
binary runs.

## The solution

`mysql-host-aliases` is a single shell script you **source** from your `.bashrc`
and/or `.zshrc`. It:

1. Reads a mapping of `alias = real-host` from a dedicated group in a mysql config
   file (default group `[endpoints]`, default file `~/.my.cnf`).
2. Defines thin wrapper functions for a configurable list of tools. Each wrapper
   inspects the arguments, and if it finds a `-h` / `--host` whose value is a known
   alias, it rewrites that value to the real host before handing off to the real
   binary.
3. Registers tab-completion so pressing <kbd>Tab</kbd> after `-h` / `--host`
   offers your alias names.

The real host is a **plain string substitution**, so the target can be anything a
tool accepts after `-h`: an RDS endpoint, a DNS name, an IPv4/IPv6 address, or a
tunnel target like `127.0.0.1`.

Define the mapping in `~/.my.cnf`:

```ini
[endpoints]
# alias  = anything you'd normally put after -h
dev      = dev.cluster-abc123xyz.eu-central-1.rds.amazonaws.com   # RDS/Aurora endpoint
prod     = prod.cluster-abc123xyz.eu-central-1.rds.amazonaws.com  # RDS/Aurora endpoint
db1      = 10.20.30.40                                            # plain IPv4
internal = db-primary.svc.internal                                # internal DNS name
tunnel   = 127.0.0.1                                              # SSH port-forward target
gcp      = 34.123.45.67                                           # Cloud SQL public IP
```

Now every wrapped tool understands the aliases:

```bash
mysql -h prod -u admin
mysqldump --host=db1 mydb > db1-dump.sql
mysqlsh -h internal --sql
mysql -h tunnel -P 3307              # connect over an SSH tunnel by name
pt-online-schema-change -h staging ...
```

> The `[endpoints]` group is ignored by the real mysql tools (they only read the
> groups they ask for), so it lives happily alongside your existing `[client]` /
> `[mysql]` settings in the same file.

## How it works

### Host detection

The resolver recognizes a host in all four standard forms and rewrites only the
value:

| You type              | Becomes                               |
| --------------------- | ------------------------------------- |
| `-h prod`             | `-h prod.cluster-….rds.amazonaws.com` |
| `-hprod`              | `-hprod.cluster-….rds.amazonaws.com`  |
| `--host prod`         | `--host prod.cluster-….rds…`          |
| `--host=prod`         | `--host=prod.cluster-….rds…`          |

The target can equally be an IP or any other host:

| You type     | With `db1 = 10.20.30.40` | Becomes              |
| ------------ | ------------------------ | -------------------- |
| `-h db1`     |                          | `-h 10.20.30.40`     |
| `--host=db1` |                          | `--host=10.20.30.40` |

### Resolution rules

- **Known alias → substituted** with the real host.
- **Unknown value → passed through unchanged** (so real hostnames, IPs, and
  `localhost` still work exactly as before).
- **Alias always wins** over a real reachable host of the same name — that's the
  whole point.
- Multiple hosts on one command line are each resolved independently.

### Config parsing

- Reads only the configured group (default `[endpoints]`), stopping at the next
  `[group]` header.
- Ignores comment lines (`#`, `;`) and strips a trailing inline comment from a
  value.
- Strips surrounding single/double quotes from a value.

### Safety

- If the config file **doesn't exist**, nothing breaks — the wrappers simply pass
  every host through untouched.
- Wrappers call the real binary via `command`, so there's no infinite recursion and
  no dependence on PATH ordering tricks.
- `awk` is resolved to an absolute path **once, when the script is sourced**, so the
  wrappers keep working even if `PATH` changes later in the session.
- Pure POSIX core: the same script sources cleanly in **bash**, **zsh**, and plain
  POSIX `sh`. Shell-specific completion code is isolated so only the active shell
  parses it.

## Requirements

- `bash` and/or `zsh` (for completion). The resolver itself is POSIX `sh`-safe.
- `awk` (preinstalled on macOS and virtually all Linux distros).
- The MySQL client tools you want to wrap.

Works on **macOS** and **Linux**.

## Install

### 1. Get the script

Clone the repo (or just download `mysql-host-aliases.sh`):

```sh
git clone https://github.com/pericajakimov/mysql-host-aliases.git
cd mysql-host-aliases
```

### 2. Install it

The script is dual-mode: **source** it for normal use, or **execute** it to run
the built-in installer. The installer copies the script to a stable location
(`~/.mysql-host-aliases.sh`) and adds a source line to your `~/.bashrc` and
`~/.zshrc`:

```sh
./mysql-host-aliases.sh --check     # dry run: show exactly what will happen
./mysql-host-aliases.sh --install   # copy the script + wire up your rc files
```

Install to a different location with `--dest`:

```sh
./mysql-host-aliases.sh --install --dest ~/.config/mysql-host-aliases.sh
```

The installer never edits your `.my.cnf`; it only writes the destination file
and your rc files, and only adds the source line if it isn't already there.
Run `./mysql-host-aliases.sh --help` for full usage, or `--version` to print
the version.

> **zsh note:** completion needs the completion system (`compinit`) initialized.
> Most zsh setups (oh-my-zsh, etc.) already do this, and if yours doesn't, the
> script will initialize it for itself when sourced in an interactive shell — so
> completion works out of the box either way. (It only steps in when `compinit`
> hasn't already run, leaving managed setups untouched.)

#### Manual install (alternative)

If you'd rather not run the installer, do the two steps it does by hand — copy
the script somewhere stable and source it:

```sh
cp mysql-host-aliases.sh ~/.mysql-host-aliases.sh
```

Then add this line to **both** `~/.bashrc` and `~/.zshrc` (whichever you use):

```sh
[ -f "$HOME/.mysql-host-aliases.sh" ] && . "$HOME/.mysql-host-aliases.sh"
```

### 3. Add your aliases

Put an `[endpoints]` group in `~/.my.cnf` (see
[`examples/my.cnf.example`](examples/my.cnf.example)):

```ini
[endpoints]
dev  = dev.cluster-….rds.amazonaws.com
prod = prod.cluster-….rds.amazonaws.com
db1  = 10.20.30.40
```

### 4. Reload

```sh
exec $SHELL          # or: source ~/.zshrc  /  source ~/.bashrc
```

Try it:

```sh
mysql -h <Tab>       # should list: dev prod db1 …
mysql -h prod -u admin
```

## Usage

```sh
mysql -h prod                       # resolved (RDS endpoint)
mysqldump --host=db1 mydb           # resolved (plain IP)
mysqlsh -h internal --sql           # resolved (internal DNS name)
mysql -h tunnel -P 3307             # resolved (SSH tunnel target)
mysql -h 10.0.0.5                   # not an alias -> passed through
mysql -h localhost                  # passed through
```

Tab-completion after the host flag:

```sh
mysqldump -h <Tab>                  # dev qa staging prod db1 …
mysql --host=pr<Tab>                # --host=prod
mysql -hd<Tab>                      # -hdev / -hdb1
```

## Configuration

Customize by editing the three variables at the top of the script
(`~/.mysql-host-aliases.sh`). No environment variables needed.

| Variable            | Default         | Purpose                                |
| ------------------- | --------------- | -------------------------------------- |
| `ENDPOINTS_FILE`    | `$HOME/.my.cnf` | Config file to read aliases from       |
| `ENDPOINTS_GROUP`   | `endpoints`     | INI group name holding the aliases     |
| `WRAPPED_TOOLS`     | see below       | Space-separated list of tools to wrap  |

For example, to keep aliases in a dedicated file and a custom group, edit the top
of `~/.mysql-host-aliases.sh`:

```sh
ENDPOINTS_FILE="$HOME/.config/mysql/endpoints.cnf"
ENDPOINTS_GROUP="aurora"
```

### Wrapped tools

`WRAPPED_TOOLS` is a whitespace-separated list. Newlines count as separators,
so you can lay it out over several lines for readability. Default value:

```sh
WRAPPED_TOOLS="
    mysql mysqldump mysqladmin mysqlimport
    mysqlcheck mysqlshow mysqlsh mysqlpump
    pt-online-schema-change pt-table-checksum
    pt-table-sync pt-query-digest pt-archiver
    mysqlmig
"
```

[**mysqlmig**](https://github.com/pericajakimov/mysqlmig) is a custom MySQL
schema/data migration helper that takes `-h`/`--host`; it's included as an
example of wrapping your own tool.

Add your own tools (anything that uses the standard `-h` / `--host` form) by
editing the list and re-sourcing:

```sh
WRAPPED_TOOLS="
    mysql mysqldump
    my-custom-db-tool
"
```

> Only wrap tools where `-h` means *host*. If one of your tools uses `-h` for
> `--help`, don't add it (or it would get a resolved value instead of help).

> **Hyphenated tool names** (like the Percona tools `pt-online-schema-change`)
> are wrapped in **bash** and **zsh**, which allow hyphenated function names.
> Plain POSIX `sh`/`dash` can't name functions with hyphens, so those tools are
> skipped there — sourcing still succeeds and all other tools work. Since the
> completion and interactive use happen in bash/zsh, this is a non-issue in
> practice.

### Using your own tools and scripts

Your own scripts work too, as long as they take the host in a standard form. Add
the script's name to `WRAPPED_TOOLS`, re-source, and the alias is resolved
before your script ever sees it:

```sh
# you type:
mydbscript -h prod

# your script actually receives:
mydbscript -h prod.cluster-abc123xyz.eu-central-1.rds.amazonaws.com
```

For this to work, your tool needs to satisfy a few conditions:

- **Callable by a bare command name on your `PATH`** (or be a shell function).
  The wrapper is a shell function of the same name that locates the real tool
  with `command -v`. Scripts you invoke by path — `./dump.sh` or
  `/opt/tools/dump.sh` — are *not* intercepted; the tool must be reachable as a
  plain command name.
- **Named with a valid function identifier.** Letters, digits, and underscores
  always work. Hyphens work in bash/zsh but are skipped under plain POSIX `sh`
  (same rule as the Percona tools above).
- **Accepts the host in one of the four standard forms** the resolver rewrites:
  `-h VAL`, `-hVAL`, `--host VAL`, `--host=VAL`. A different flag (e.g.
  `--server`, `-H`) is left untouched.
- **`-h` means host, not help** in that tool.

The substitution is purely on the host argument — your script receives the real
endpoint and uses it however it normally would (connect directly, or pass it on
to `mysql`). Unknown values are passed through unchanged, so real hostnames and
IPs still work.

## Caveats & notes

- **`mysqlsh` URI syntax is not touched.** Only the classic `-h` / `--host` form is
  resolved. `mysqlsh user@prod:3306` and `--uri` are passed through as-is by design.
- **Interactive shells only.** Because the wrappers are shell functions, resolution
  applies to commands you run in bash/zsh. Scripts that invoke `mysql` directly
  (without sourcing this file) use the real binary unchanged.
- **The alias is a plain string substitution** for the host value — it does not
  touch ports, users, or any other flag. (So a tunnel alias resolves the host; you
  still pass `-P <port>` yourself.)

## Tests

A POSIX shell test suite lives in [`tests/`](tests). It exercises the config
parsing and host-rewriting logic without needing a real `mysql` binary:

```sh
./tests/run.sh
```

## Uninstall

Remove the source line from your `~/.bashrc` / `~/.zshrc`, delete
`~/.mysql-host-aliases.sh`, and (optionally) the `[endpoints]` group from
`~/.my.cnf`. Start a new shell.

## Versioning

The version is held in the `SCRIPT_VERSION` variable at the top of
`mysql-host-aliases.sh` (currently **1.0.0**) and is the single source of truth.
Print it at any time with:

```sh
./mysql-host-aliases.sh --version        # or on an installed copy:
~/.mysql-host-aliases.sh --version
```

That lets you tell which build an installed copy corresponds to, which is handy
once new features land.

## License

[MIT](LICENSE) © Perica Jakimov
