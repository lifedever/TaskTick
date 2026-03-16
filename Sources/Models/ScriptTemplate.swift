import Foundation

struct ScriptTemplate: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var category: String
    var notes: String
    var scriptBody: String
    var shell: String
    var workingDirectory: String
    var isBuiltIn: Bool
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, category: String = "", notes: String = "", scriptBody: String, shell: String = "/bin/zsh", workingDirectory: String = "", isBuiltIn: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.category = category
        self.notes = notes
        self.scriptBody = scriptBody
        self.shell = shell
        self.workingDirectory = workingDirectory
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Support decoding old templates without new fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        scriptBody = try container.decode(String.self, forKey: .scriptBody)
        shell = try container.decode(String.self, forKey: .shell)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

// MARK: - Default Templates (seeded once on first launch)

enum DefaultTemplates {
    /// Create localized default templates. Called once on first launch.
    static func seed() -> [ScriptTemplate] {
        [
            ScriptTemplate(
                name: L10n.tr("default_template.mysql_backup.name"),
                category: L10n.tr("default_template.category.database"),
                notes: L10n.tr("default_template.mysql_backup.notes"),
                scriptBody: """
                    #!/bin/zsh
                    # MySQL Database Backup
                    DB_HOST="localhost"
                    DB_USER="root"
                    DB_PASS="your_password"
                    DB_NAME="your_database"
                    BACKUP_DIR="$HOME/backups/mysql"
                    DATE=$(date +%Y%m%d_%H%M%S)

                    mkdir -p "$BACKUP_DIR"
                    mysqldump -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" | gzip > "$BACKUP_DIR/${DB_NAME}_${DATE}.sql.gz"

                    # Remove backups older than 7 days
                    find "$BACKUP_DIR" -name "*.sql.gz" -mtime +7 -delete
                    echo "Backup completed: ${DB_NAME}_${DATE}.sql.gz"
                    """
            ),
            ScriptTemplate(
                name: L10n.tr("default_template.pg_backup.name"),
                category: L10n.tr("default_template.category.database"),
                notes: L10n.tr("default_template.pg_backup.notes"),
                scriptBody: """
                    #!/bin/zsh
                    # PostgreSQL Database Backup
                    DB_HOST="localhost"
                    DB_USER="postgres"
                    DB_NAME="your_database"
                    BACKUP_DIR="$HOME/backups/postgres"
                    DATE=$(date +%Y%m%d_%H%M%S)

                    mkdir -p "$BACKUP_DIR"
                    pg_dump -h "$DB_HOST" -U "$DB_USER" "$DB_NAME" | gzip > "$BACKUP_DIR/${DB_NAME}_${DATE}.sql.gz"

                    # Remove backups older than 7 days
                    find "$BACKUP_DIR" -name "*.sql.gz" -mtime +7 -delete
                    echo "Backup completed: ${DB_NAME}_${DATE}.sql.gz"
                    """
            ),
            ScriptTemplate(
                name: L10n.tr("default_template.git_sync.name"),
                category: L10n.tr("default_template.category.git"),
                notes: L10n.tr("default_template.git_sync.notes"),
                scriptBody: """
                    #!/bin/zsh
                    # Git repository sync
                    REPO_DIR="$HOME/Projects/your-repo"

                    cd "$REPO_DIR" || exit 1
                    echo "Syncing repository: $(basename "$REPO_DIR")"

                    git fetch --all --prune
                    git pull --rebase origin main

                    echo "Repository synced at $(date)"
                    """
            ),
            ScriptTemplate(
                name: L10n.tr("default_template.health_check.name"),
                category: L10n.tr("default_template.category.health"),
                notes: L10n.tr("default_template.health_check.notes"),
                scriptBody: """
                    #!/bin/zsh
                    # HTTP endpoint health check
                    URL="https://example.com/health"
                    TIMEOUT=10

                    STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time $TIMEOUT "$URL")

                    if [ "$STATUS" -eq 200 ]; then
                        echo "✓ $URL is healthy (HTTP $STATUS)"
                    else
                        echo "✗ $URL is down (HTTP $STATUS)"
                        exit 1
                    fi
                    """
            ),
            ScriptTemplate(
                name: L10n.tr("default_template.disk_monitor.name"),
                category: L10n.tr("default_template.category.file_watch"),
                notes: L10n.tr("default_template.disk_monitor.notes"),
                scriptBody: """
                    #!/bin/zsh
                    # Monitor disk usage and alert if above threshold
                    THRESHOLD=80

                    USAGE=$(df -h / | awk 'NR==2 {gsub(/%/,""); print $5}')

                    if [ "$USAGE" -gt "$THRESHOLD" ]; then
                        echo "⚠ Disk usage is at ${USAGE}% (threshold: ${THRESHOLD}%)"
                        exit 1
                    else
                        echo "✓ Disk usage is at ${USAGE}%"
                    fi
                    """
            ),
            ScriptTemplate(
                name: L10n.tr("default_template.docker_cleanup.name"),
                category: L10n.tr("default_template.category.docker"),
                notes: L10n.tr("default_template.docker_cleanup.notes"),
                scriptBody: """
                    #!/bin/zsh
                    # Clean up unused Docker resources
                    # ⚠ This removes stopped containers, dangling images, unused volumes and networks

                    if ! command -v docker &>/dev/null; then
                        echo "Docker is not installed, skipping."
                        exit 0
                    fi

                    echo "=== Before cleanup ==="
                    docker system df

                    echo "\\nRemoving stopped containers..."
                    docker container prune -f

                    echo "Removing dangling images..."
                    docker image prune -f

                    echo "Removing unused networks..."
                    docker network prune -f

                    # Uncomment the next line to also remove unused volumes (may delete data!)
                    # docker volume prune -f

                    echo "\\n=== After cleanup ==="
                    docker system df
                    """
            ),
            // -- Backup --
            ScriptTemplate(
                name: L10n.tr("default_template.dir_backup.name"),
                category: L10n.tr("default_template.category.backup"),
                notes: L10n.tr("default_template.dir_backup.notes"),
                scriptBody: """
                    #!/bin/zsh
                    # Directory backup with tar
                    SOURCE_DIR="$HOME/Documents"
                    BACKUP_DIR="$HOME/backups/dirs"
                    DATE=$(date +%Y%m%d_%H%M%S)
                    NAME=$(basename "$SOURCE_DIR")

                    mkdir -p "$BACKUP_DIR"
                    tar -czf "$BACKUP_DIR/${NAME}_${DATE}.tar.gz" -C "$(dirname "$SOURCE_DIR")" "$NAME"

                    # Remove backups older than 30 days
                    find "$BACKUP_DIR" -name "*.tar.gz" -mtime +30 -delete
                    echo "Backup completed: ${NAME}_${DATE}.tar.gz"
                    """
            ),
            ScriptTemplate(
                name: L10n.tr("default_template.redis_backup.name"),
                category: L10n.tr("default_template.category.database"),
                notes: L10n.tr("default_template.redis_backup.notes"),
                scriptBody: """
                    #!/bin/zsh
                    # Redis RDB backup
                    REDIS_HOST="127.0.0.1"
                    REDIS_PORT=6379
                    BACKUP_DIR="$HOME/backups/redis"
                    DATE=$(date +%Y%m%d_%H%M%S)

                    mkdir -p "$BACKUP_DIR"
                    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" BGSAVE
                    sleep 2

                    DUMP_FILE=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" CONFIG GET dir | tail -1)/dump.rdb
                    cp "$DUMP_FILE" "$BACKUP_DIR/dump_${DATE}.rdb"

                    find "$BACKUP_DIR" -name "*.rdb" -mtime +7 -delete
                    echo "Redis backup completed: dump_${DATE}.rdb"
                    """
            ),
            ScriptTemplate(
                name: L10n.tr("default_template.mongodb_backup.name"),
                category: L10n.tr("default_template.category.database"),
                notes: L10n.tr("default_template.mongodb_backup.notes"),
                scriptBody: """
                    #!/bin/zsh
                    # MongoDB backup
                    MONGO_HOST="localhost"
                    MONGO_PORT=27017
                    DB_NAME="your_database"
                    BACKUP_DIR="$HOME/backups/mongodb"
                    DATE=$(date +%Y%m%d_%H%M%S)

                    mkdir -p "$BACKUP_DIR"
                    mongodump --host "$MONGO_HOST" --port "$MONGO_PORT" --db "$DB_NAME" --out "$BACKUP_DIR/${DB_NAME}_${DATE}"
                    tar -czf "$BACKUP_DIR/${DB_NAME}_${DATE}.tar.gz" -C "$BACKUP_DIR" "${DB_NAME}_${DATE}"
                    rm -rf "$BACKUP_DIR/${DB_NAME}_${DATE}"

                    find "$BACKUP_DIR" -name "*.tar.gz" -mtime +7 -delete
                    echo "MongoDB backup completed: ${DB_NAME}_${DATE}.tar.gz"
                    """
            ),
            // -- Monitoring --
            ScriptTemplate(
                name: L10n.tr("default_template.ssl_check.name"),
                category: L10n.tr("default_template.category.health"),
                notes: L10n.tr("default_template.ssl_check.notes"),
                scriptBody: """
                    #!/bin/zsh
                    # Check SSL certificate expiry
                    DOMAIN="example.com"
                    WARN_DAYS=30

                    EXPIRY=$(echo | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN":443 2>/dev/null | openssl x509 -noout -enddate | cut -d= -f2)
                    EXPIRY_EPOCH=$(date -j -f "%b %d %T %Y %Z" "$EXPIRY" +%s 2>/dev/null || date -d "$EXPIRY" +%s)
                    NOW_EPOCH=$(date +%s)
                    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

                    if [ "$DAYS_LEFT" -le "$WARN_DAYS" ]; then
                        echo "⚠ SSL certificate for $DOMAIN expires in $DAYS_LEFT days ($EXPIRY)"
                        exit 1
                    else
                        echo "✓ SSL certificate for $DOMAIN is valid for $DAYS_LEFT more days"
                    fi
                    """
            ),
            ScriptTemplate(
                name: L10n.tr("default_template.process_monitor.name"),
                category: L10n.tr("default_template.category.health"),
                notes: L10n.tr("default_template.process_monitor.notes"),
                scriptBody: """
                    #!/bin/zsh
                    # Check if a process is running
                    PROCESS_NAME="nginx"

                    if pgrep -x "$PROCESS_NAME" > /dev/null; then
                        echo "✓ $PROCESS_NAME is running (PID: $(pgrep -x "$PROCESS_NAME" | head -1))"
                    else
                        echo "✗ $PROCESS_NAME is NOT running!"
                        exit 1
                    fi
                    """
            ),
            ScriptTemplate(
                name: L10n.tr("default_template.port_check.name"),
                category: L10n.tr("default_template.category.health"),
                notes: L10n.tr("default_template.port_check.notes"),
                scriptBody: """
                    #!/bin/zsh
                    # Check if a port is open
                    HOST="localhost"
                    PORT=3000
                    TIMEOUT=5

                    if nc -z -w "$TIMEOUT" "$HOST" "$PORT" 2>/dev/null; then
                        echo "✓ $HOST:$PORT is open"
                    else
                        echo "✗ $HOST:$PORT is not reachable"
                        exit 1
                    fi
                    """
            ),
            ScriptTemplate(
                name: L10n.tr("default_template.memory_monitor.name"),
                category: L10n.tr("default_template.category.file_watch"),
                notes: L10n.tr("default_template.memory_monitor.notes"),
                scriptBody: """
                    #!/bin/zsh
                    # Monitor memory usage on macOS
                    THRESHOLD=80

                    MEM_INFO=$(vm_stat | awk '
                        /Pages free/ {free=$3}
                        /Pages active/ {active=$3}
                        /Pages inactive/ {inactive=$3}
                        /Pages speculative/ {spec=$3}
                        /Pages wired/ {wired=$3}
                        END {
                            gsub(/\\./,"",free); gsub(/\\./,"",active); gsub(/\\./,"",inactive); gsub(/\\./,"",spec); gsub(/\\./,"",wired)
                            total=free+active+inactive+spec+wired
                            used=active+wired
                            printf "%.0f", (used/total)*100
                        }
                    ')

                    if [ "$MEM_INFO" -gt "$THRESHOLD" ]; then
                        echo "⚠ Memory usage is at ${MEM_INFO}% (threshold: ${THRESHOLD}%)"
                        exit 1
                    else
                        echo "✓ Memory usage is at ${MEM_INFO}%"
                    fi
                    """
            ),
            // -- Sync & Cleanup --
            ScriptTemplate(
                name: L10n.tr("default_template.rsync.name"),
                category: L10n.tr("default_template.category.backup"),
                notes: L10n.tr("default_template.rsync.notes"),
                scriptBody: """
                    #!/bin/zsh
                    # Rsync directory sync
                    # ⚠ Verify SOURCE and DEST paths before running
                    SOURCE="$HOME/Projects/"
                    DEST="$HOME/backups/projects/"

                    if [ ! -d "$SOURCE" ]; then
                        echo "Source directory $SOURCE does not exist!"
                        exit 1
                    fi

                    mkdir -p "$DEST"
                    rsync -avz --progress "$SOURCE" "$DEST"
                    echo "Sync completed at $(date)"
                    """
            ),
            // -- Notification / Webhook --
            ScriptTemplate(
                name: L10n.tr("default_template.webhook.name"),
                category: L10n.tr("default_template.category.notification"),
                notes: L10n.tr("default_template.webhook.notes"),
                scriptBody: """
                    #!/bin/zsh
                    # Send a webhook notification
                    WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
                    MESSAGE="Scheduled task completed at $(date)"

                    curl -s -X POST -H 'Content-type: application/json' \\
                        --data "{\\\"text\\\":\\\"$MESSAGE\\\"}" \\
                        "$WEBHOOK_URL"

                    echo "Webhook sent."
                    """
            ),
        ]
    }
}

// MARK: - Template Store

@MainActor
final class ScriptTemplateStore: ObservableObject {
    static let shared = ScriptTemplateStore()
    private let key = "scriptTemplates"
    private let seededKey = "hasSeededDefaultTemplates"

    @Published var templates: [ScriptTemplate] = []

    /// All categories for the category picker
    var allCategories: [String] {
        Array(Set(templates.map { $0.category }).filter { !$0.isEmpty }).sorted()
    }

    /// Templates grouped by category
    var groupedTemplates: [(category: String, templates: [ScriptTemplate])] {
        let uncategorized = templates.filter { $0.category.isEmpty }
        let categorized = Dictionary(grouping: templates.filter { !$0.category.isEmpty }, by: { $0.category })
        var result: [(category: String, templates: [ScriptTemplate])] = categorized
            .sorted { $0.key < $1.key }
            .map { (category: $0.key, templates: $0.value) }
        if !uncategorized.isEmpty {
            result.append((category: "", templates: uncategorized))
        }
        return result
    }

    private init() {
        load()
        seedIfNeeded()
    }

    func save(_ template: ScriptTemplate) {
        templates.append(template)
        persist()
    }

    func delete(_ template: ScriptTemplate) {
        templates.removeAll { $0.id == template.id }
        persist()
    }

    func rename(_ template: ScriptTemplate, to newName: String) {
        guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[index].name = newName
        persist()
    }

    func update(_ template: ScriptTemplate, name: String, category: String, notes: String, scriptBody: String, shell: String, workingDirectory: String) {
        guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[index].name = name.trimmingCharacters(in: .whitespaces)
        templates[index].category = category
        templates[index].notes = notes
        templates[index].scriptBody = scriptBody
        templates[index].shell = shell
        templates[index].workingDirectory = workingDirectory
        templates[index].updatedAt = Date()
        persist()
    }

    /// Restore default templates without overwriting existing ones.
    /// Compares by name to avoid duplicates.
    func restoreDefaults() {
        let defaults = DefaultTemplates.seed()
        let existingNames = Set(templates.map { $0.name })
        var added = 0
        for template in defaults {
            if !existingNames.contains(template.name) {
                templates.append(template)
                added += 1
            }
        }
        if added > 0 {
            persist()
        }
    }

    private func seedIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        let defaults = DefaultTemplates.seed()
        templates.append(contentsOf: defaults)
        persist()
        UserDefaults.standard.set(true, forKey: seededKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ScriptTemplate].self, from: data) else { return }
        templates = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
