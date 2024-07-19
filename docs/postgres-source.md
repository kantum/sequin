# Getting started with the Postgres source

With the `postgres` source, Sequin turns the Postgres WAL into a message queue. This means you can stream creates, updates, and deletes from any table in Postgres to your app. Then, you can use Sequin's pull-based or push-based (i.e. webhook) consumption patterns.

Sequin is a great fit if LISTEN/NOTIFY's at-most-once delivery is not sufficient for your use case. It's an alternative to setting up Debezium/Kafka to consume Postgres changes.

## Setup

From the CLI, connect any Postgres table to Sequin:

```bash
sequin source postgres add
```

### Connecting a database

If connecting your first Postgres database to Sequin, select "Connect new" from the prompt:

```bash
? Choose a database or connect a new one:  [Use arrows to move, type to filter]
> Connect new database
```

And fill out the form:

```bash
Database name:
> postgres

Hostname:
> localhost

Port:
> 5432

Username:
> postgres

Password:
> ********

Give your database a name:
> mydb

[ Submit ]
```

### Setting up a replication slot and publication

To capture changes from your database, Sequin needs (1) a replication slot and (2) a publication. You have two options to set this up:

#### Automated setup

The CLI will ask permission to create a replication slot and publication for you. Setting up automatically will configure the replication slot to capture _all_ changes to all the tables you selected.

#### Manual setup

If you prefer, you can create the replication slot and publication manually. Setting up manually gives you more control over the publication. You can select whether to include `INSERT`, `UPDATE`, `DELETE`, and `TRUNCATE` events. You can also specify `WHERE` clauses to filter which rows are specified to Sequin.

> [!NOTE]
> The manual setup may be necessary if the Postgres user you've provided during the setup process doesn't have permission to create a replication slot or publication.

To create a replication slot and publication manually, run the following SQL commands:

```sql
SELECT * FROM pg_create_logical_replication_slot('sequin', 'pgoutput');
-- Create a publication for a select list of tables
CREATE PUBLICATION sequin FOR TABLE my_table, my_other_table;
-- Or, create a publication for all tables in a schema
CREATE PUBLICATION sequin FOR ALL TABLES IN SCHEMA my_schema;
-- Or, create a publication for all tables in the database
CREATE PUBLICATION sequin FOR ALL TABLES;
```

Learn more about publication and the available options [in the Postgres docs](https://www.postgresql.org/docs/current/logical-replication-publication.html).

### Select a format for keys

Sequin will capture changes to your tables and insert them into your stream as messages. The CLI will prompt you for which format you want to use for the keys:

1. `[<database>].[<schema>].[<table>].[<row-id>]`
2. `[<database>].[<schema>].[<table>].[<operation>].[<row-id>]`

Where:

- `<database>` is the name in Sequin you set for the database
- `<schema>` is the name of the schema
- `<table>` is the name of the table
- `<row-id>` is the primary key of the row
- `<operation>` is the operation type (`insert`, `update`, `delete`, `truncate`)

For example:

- `mydb.public.users.1` (format 1)
- `mydb.public.users.insert.1` (format 2)

> [!NOTE]
> More complex key and data transformations are coming soon. Please open an issue specifying your use case if this interests you.

> [!IMPORTANT]
> Truncates are not supported yet. If you need to capture truncates, please open an issue specifying your use case.

### Shape of the message

The message is stored in your stream in JSON format. It has two top-level keys, `data` and `deleted`:

```json
{
  "data": {
    "id": 1,
    "name": "Paul Atreides"
  },
  "deleted": false
}
```

### Backfilling

The CLI will next ask if you want to backfill existing rows from your tables into the stream. This will run a process to extract all existing rows from your tables and insert them into your stream. (Note that all rows will be inserted as `insert` operations.)

## Status

You can monitor the status of the `postgres` source at any time by running:

```bash
sequin source postgres info [<source>]
```

The `Last Committed Timestamp` indicates the last WAL position that Sequin has committed to the stream.