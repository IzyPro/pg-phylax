# PostgreSQL Backup to Cloudflare R2

Periodic PostgreSQL backups to S3, Cloudflare R2 or any S3 compatible storage with Telegram notifications.

Adapted from:

- [eeshugerman/postgres-backup-s3](https://github.com/eeshugerman/postgres-backup-s3) — S3 upload via aws CLI
- [prodrigestivill/docker-postgres-backup-local](https://github.com/prodrigestivill/docker-postgres-backup-local) — retention logic

## Backup Structure in R2

``` bash
your-bucket/
└── postgres-backups/
    └── your-database/
        ├── daily/
        │   ├── yourdb_2026-06-05T02-00-00Z.sql.gz
        │   └── yourdb_2026-06-06T02-00-00Z.sql.gz
        ├── weekly/
        │   └── yourdb_2026-06-01T02-00-00Z.sql.gz  ← uploaded every Sunday
        └── monthly/
            └── yourdb_2026-06-01T02-00-00Z.sql.gz  ← uploaded on 1st of month
```

## Setup

### 1. Cloudflare R2

1. Go to Cloudflare Dashboard → R2 → Create Bucket
2. Go to R2 → Manage R2 API Tokens → Create API Token
   - Permissions: Object Read & Write
   - Scope: your backup bucket
3. Note your Account ID, Access Key ID, and Secret Access Key

### 2. Telegram Bot

1. Message @BotFather → /newbot
2. Copy the bot token
3. Add the bot to your group
4. Get the chat ID via @userinfobot

### 3. Deploy on Coolify

1. Push this repo to a private GitHub repository
2. In Coolify → New Resource → Docker Compose
3. Point to your GitHub repo
4. Add environment variables from .env.example
5. Deploy

### 4. Test the backup

After deploying, trigger a manual backup:

```bash
docker exec pgphylax /bin/sh /usr/local/bin/backup.sh
```

## Notifications

| Event | Telegram | Sound |
| --- | --- | --- |
| Backup started | ✅ | Silent |
| Backup succeeded | ✅ | Silent |
| Backup failed | ✅ | Audible alert |

## Restore

```bash
# List available backups
aws s3 ls s3://your-bucket/postgres-backups/your-db/daily/ \
  --endpoint-url https://your-account-id.r2.cloudflarestorage.com

# Download a backup
aws s3 cp s3://your-bucket/postgres-backups/your-db/daily/your-db_2026-06-05T02-00-00Z.sql.gz \
  ./restore.sql.gz \
  --endpoint-url https://your-account-id.r2.cloudflarestorage.com

# Restore
gunzip -c restore.sql.gz | psql -h your-host -U your-user your-database
```
