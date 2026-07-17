# PostgreSQL Architecture

Replication features like `pg_basebackup`, WAL, and replication slots work on the **whole cluster**, not on one 
database. This note covers how PostgreSQL is laid out so those pieces make sense later.


![PostgreSQL Architecture](./assets/1_architecture.png)

---

## 1.1 PostgreSQL Cluster
- A PostgreSQL **Cluster** is a single PostgreSQL server instance together with all of its data stored inside one data 
directory (`PGDATA`).
- Unlike Kubernetes or MongoDB, a PostgreSQL cluster **does NOT** mean multiple servers. It simply means 
**one PostgreSQL server managing multiple databases**.

Example:
```
PostgreSQL Cluster
│
├── postgres
├── db1
├── db2
├── replication
└── bookstoreDB
```
👉 All of these databases belong to the **same PostgreSQL Cluster**.

### A PostgreSQL Cluster contains:
- Multiple databases
- Roles (users)
- Tablespaces
- WAL files
- Configuration files
- System catalogs

👉 All replication operations work on the **entire cluster**, not on an individual database.

---

## 1.2 Database vs. Cluster
**‼️ One of the most common misconceptions is treating a PostgreSQL Cluster as a database.**

The relationship is:
```
PostgreSQL Cluster
│
├── Database A
├── Database B
├── Database C
└── Database D
```
👉 A **Database** is simply one logical database inside the cluster.

### When running:
```sql
CREATE DATABASE bookstore;
```

👉 PostgreSQL creates another database **inside the same cluster**.

### When using
```bash
psql -d bookstore
```

👉 Replication copies the **entire cluster**, meaning **every database, role, and system object is replicated**.

---

## 1.3 PostgreSQL Server Process
- The PostgreSQL server is **not a single process**. It is a **multi-process database server**
- When PostgreSQL starts, the operating system launches a parent process called `postgres`. This process is responsible 
for managing the entire PostgreSQL Cluster. It loads the configuration files, opens the data directory (`PGDATA`), 
listens for client connections on port 5432, and starts all required background processes.

```
                postgres (Parent Process)
                         │
      ┌──────────────────┼───────────────────┐
      │                  │                   │
      ▼                  ▼                   ▼
 Backend Process    WAL Writer        Checkpointer
(Client SQL)                             ...
```

👉 The parent process itself does not execute user SQL. Instead, it creates child processes, each with its own 
responsibility.


### Main Components

#### ✨ Parent Process (`postgres`)
- Starts the PostgreSQL server
- Reads configuration files
- Opens the PostgreSQL Cluster (`PGDATA`)
- Accepts incoming client connections
- Creates background processes
- Coordinates server shutdown

#### ✨ Backend Process
A backend process is created for each client connection.

Responsibilities:
- Executes SQL statements
- Reads and writes data
- Generates WAL records
- Returns query results to the client

Example:
```
Application
      │
      ▼
Backend Process
      │
      ▼
Execute SQL
```

#### ✨ WAL Writer
Writes WAL records to the `pg_wal` directory.

That is what makes commits durable: the change hits WAL on disk before the data files catch up.

#### ✨ Checkpointer
Periodically flushes modified pages from memory to the database files on disk.

Those checkpoints matter for crash recovery and WAL recycling.

#### ✨ WAL Sender
Runs only on the `primary`.

Reads WAL from `pg_wal` and streams it to connected `standby` servers.

Usually **one WAL Sender per connected `standby`**.

#### ✨ WAL Receiver
Runs only on the `standby`.

Receives WAL from the `primary` over the network.

#### ✨ Startup Process
Runs only on the `standby`.

Replays the received WAL and applies it to the `standby` database.


### Process Flow During Streaming Replication
```
         PRIMARY

          Client
             │
             ▼
     Backend Process
             │
             ▼
        Generate WAL
             │
             ▼
         WAL Writer
             │
             ▼
          pg_wal
             │
             ▼
        WAL Sender
             │
        TCP Network
             │
             ▼
             
             

         STANDBY

        WAL Receiver
             │
             ▼
     Startup Process
             │
             ▼
      Apply WAL Replay
             │
             ▼
      Standby Database
```

👉 PostgreSQL is a **multi-process** database server.

👉 The parent `postgres` process manages the PostgreSQL Cluster.

👉 Every client connection gets its own **Backend Process**.

👉 The **WAL Writer** persists WAL records.

👉 The **Checkpointer** writes dirty pages to the data files.

👉 During streaming replication:
- **WAL Sender** exists on the `primary`.
- **WAL Receiver** exists on the `standby`.
- The **Startup Process** replays WAL to keep the `standby` synchronized.

---

## 1.4 `PGDATA` (Data Directory)
`PGDATA` is the root directory where PostgreSQL stores everything.

Example:
```
/var/lib/postgresql/18/docker
```

or
```
/var/lib/postgresql/data
```

depending on the installation.

Inside this directory are:
- All databases
- WAL
- Configuration
- Roles
- Replication slots
- Transaction status
- Metadata

Losing this directory means losing the entire PostgreSQL cluster.

---

## 1.5 Database File Layout
Inside `PGDATA`:
```
PGDATA/
│
├── base/
├── global/
├── pg_wal/
├── pg_replslot/
├── pg_stat/
├── pg_multixact/
├── pg_xact/
├── pg_tblspc/
├── postgresql.conf
├── postgresql.auto.conf
└── pg_hba.conf
```

### ✨ `base/`
Contains the actual data files for every user database.

Example:
```
base/
│
├── 1/
├── 16384/
├── 24576/
```

Each directory represents one database identified by its internal OID.

Tables inside each database are stored as individual files.

### ✨ `global/`
Stores cluster-wide objects that are shared by every database.

Examples include:
- Roles (users)
- System catalogs
- Shared metadata

Unlike `base/`, these objects belong to the entire cluster.

### ‼️ `pg_wal/`
Stores all `Write-Ahead Log (WAL)` files.

These files record every database modification before the actual data files are updated.

They are used for:
- Crash recovery
- Streaming replication
- PITR (Point-in-Time Recovery)

This directory is one of the most important components of PostgreSQL.

### ‼️ `pg_replslot/`
Stores metadata for replication slots.

Each slot records **how far a replication consumer (.e.g: `standby`, ...) has progressed**.

It **does not** store WAL itself.

Example:
```
pg_replslot/
│
├── standby1/
├── analytics/
└── backup/
```
Each directory contains only metadata used to determine which WAL files must be retained.

### ✨ `pg_stat/`
Stores runtime statistics collected by PostgreSQL.

These statistics are exposed through views such as:
```sql
SELECT * FROM pg_stat_replication;
```
They are used for monitoring and diagnostics.

### ✨ `pg_multixact/`
Stores information for `MultiXact` IDs.

Used primarily when multiple transactions simultaneously lock the same row.

### ✨ `pg_xact/`
Stores transaction commit status.

It allows PostgreSQL to determine whether a transaction is committed, rolled back, or is still in progress.

### ‼️ `postgresql.conf`
The main PostgreSQL configuration file.

Contains server configuration such as:
- Memory
- WAL settings
- Checkpoints
- Logging
- Networking

Typically edited by administrators.

### ‼️ `postgresql.auto.conf`

Automatically generated by PostgreSQL.

Updated whenever:

```sql
ALTER SYSTEM ...
```

is executed.

If the same parameter exists in both files, values in `postgresql.auto.conf` override those in `postgresql.conf`.

### ‼️ `pg_hba.conf`
**Host-Based Authentication** configuration.

Controls **who is allowed to connect**.

The configuration records the following syntax:
```shell
# TYPE    DATABASE        USER            ADDRESS                 METHOD
```

- `TYPE`: Specifies how the client is connecting.
  - `local`: Matches connection attempts using Unix-domain sockets.
  - `host`: Matches any TCP/IP-based connection (plain or encrypted).
  - `hostssl`: Requires the connection to use SSL/TLS encryption.
  - `hostnossl`: Restricts connections to unencrypted TCP/IP only.

- `DATABASE`: Specifies which database names match the rule.
  - `all`: Matches all databases.
  - `replication`: **Dedicated keyword to match replication streaming connections.**
  - `db1`,`db2`: Comma-separated list of database names.
  - `/regex`: Regular expression matches if prefixed with a forward slash.

- `USER`: Specifies which database user accounts match the rule.
  - `all`: Matches all users.
  - `username`: Matches a specific user account.
  - `@groupname`: Matches users belonging to a specific PostgreSQL role group.
  - `/regex`: Regular expression matches if prefixed with a forward slash.

- `ADDRESS`: Specifies the client machine's IP address range (omitted for local records).
  - `127.0.0.1/32`: Standard IPv4 loopback (localhost).
  - `::1/128`: Standard IPv6 loopback.
  - `192.168.1.0/24`: Subnet using CIDR block notation.
  - `all`, `samehost`, or `samenet`: Special network keywords.

- `METHOD`: Defines how the client must prove their identity.
  - `scram-sha-256`: Password-based authentication using secure cryptographic challenge-response (strongly recommended).
  - `md5`: Older, legacy password hashing option.
  - `trust`: Allows unconditional access without passwords (use only for trusted setups).
  - `reject`: Unconditionally drops matching connection attempts (useful for filtering specific subnets).
  - `peer`: Uses operating system user credentials (valid for local socket connections only).
  - `cert`, `gss`, `ldap`, `radius`: Enterprise-level protocol methods.

Example:

```shell
# TYPE    DATABASE        USER            ADDRESS                 METHOD
  host    replication     repl        172.20.0.0/16           scram-sha-256
  
  # Local Unix socket connections for the admin role
  local     all           postgres                                peer
  
  # IPv4 Local loopback connection for developers
  host      all             all        127.0.0.1/32            scram-sha-256  
```



👉 `PGDATA` contains the complete PostgreSQL cluster.

👉 `pg_wal` stores transaction logs, not table data.

👉 `pg_replslot` stores replication progress metadata, not WAL files.

👉 `postgresql.conf` defines the server configuration.

👉 `postgresql.auto.conf` stores configuration written by `ALTER SYSTEM`.

👉 `pg_hba.conf` determines which clients are allowed to connect and how they authenticate.


---


---

## References

- [Medium - PostgreSQL Architecture](https://medium.com/@sumeet.k.shukla/postgresql-architecture-6df259dc1145)

---

## Notes in this series

| #  | Note                                                                         | What it covers                                              |
|----|------------------------------------------------------------------------------|-------------------------------------------------------------|
| 1  | [1_PostgreSQL_Architecture.md](./1_PostgreSQL_Architecture.md)               | Cluster, processes, `PGDATA`, `pg_hba.conf`                 |
| 2  | [2_WAL.md](./2_WAL.md)                                                       | WAL records, segments, lifecycle, recycling, crash recovery |
| 3  | [3_Commit_Flow.md](./3_Commit_Flow.md)                                       | What happens on `INSERT` + `COMMIT`                         |
| 4  | [4_LSN.md](./4_LSN.md)                                                       | LSN, lag in bytes, row-loss accounting                      |
| 5  | [5_Checkpoint.md](./5_Checkpoint.md)                                         | Checkpoints, timeout vs `max_wal_size`, bgwriter            |
| 6  | [6_Replication_Slots.md](./6_Replication_Slots.md)                           | Slots, retention, disk risk                                 |
| 7  | [7_Base_Backup.md](./7_Base_Backup.md)                                       | `pg_basebackup`, seeding a `standby`                        |
| 8  | [8_Standby_Initialization.md](./8_Standby_Initialization.md)                 | `standby.signal`, `primary_conninfo`, recovery mode         |
| 9  | [9_Promotion.md](./9_Promotion.md)                                           | Promote `standby` → `primary`, prevent data loss            |
| 10 | [10_Replication_Failure_Scenarios.md](./10_Replication_Failure_Scenarios.md) | Partition, offline, WAL removed, rebuild                    |

---

## Still to learn (later)

- Timeline internals (deeper)
- Logical replication / CDC
- WAL archiving and PITR
- Hot Standby feedback, vacuum vs replication
- Cascading replication
- PostgreSQL on Kubernetes (StatefulSets, PVCs, Services) — project build
- HA tools for comparison: Patroni, CloudNativePG
