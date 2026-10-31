import GRDB

enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: createInitialSchema)
        migrator.registerMigration("v2-automations", migrate: createAutomations)
        return migrator
    }

    private static func createAutomations(_ db: Database) throws {
        let statuses = AutomationRunStatus.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
        try db.execute(sql: """
            CREATE TABLE automation (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                teamId TEXT NOT NULL REFERENCES team(id) ON DELETE CASCADE,
                stateId TEXT NOT NULL REFERENCES workflowState(id) ON DELETE CASCADE,
                directory TEXT NOT NULL,
                prompt TEXT NOT NULL,
                command TEXT NOT NULL,
                enabled BOOLEAN NOT NULL DEFAULT 1,
                createdAt DATETIME NOT NULL,
                updatedAt DATETIME NOT NULL
            );
            CREATE INDEX automation_state ON automation(stateId);

            CREATE TABLE automationRun (
                id TEXT PRIMARY KEY NOT NULL,
                automationId TEXT NOT NULL REFERENCES automation(id) ON DELETE CASCADE,
                issueId TEXT NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
                status TEXT NOT NULL CHECK (status IN (\(statuses))),
                logPath TEXT NOT NULL,
                exitCode INTEGER,
                startedAt DATETIME NOT NULL,
                finishedAt DATETIME
            );
            CREATE INDEX automationRun_issue ON automationRun(issueId, startedAt);
            CREATE INDEX automationRun_status ON automationRun(status);
            """)
    }

    private static func createInitialSchema(_ db: Database) throws {
        let categories = StateCategory.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let relationTypes = RelationType.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let memberKinds = MemberKind.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let projectStatuses = ProjectStatus.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let projectHealths = ProjectHealth.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let layouts = ViewLayout.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let actions = ChangeAction.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let fields = IssueField.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")

        try db.execute(sql: """
            CREATE TABLE member (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL CHECK (kind IN (\(memberKinds))),
                name TEXT NOT NULL,
                clientName TEXT,
                createdAt DATETIME NOT NULL
            );

            CREATE TABLE team (
                id TEXT PRIMARY KEY NOT NULL,
                key TEXT NOT NULL,
                name TEXT NOT NULL,
                issueCounter INTEGER NOT NULL DEFAULT 0,
                createdAt DATETIME NOT NULL,
                updatedAt DATETIME NOT NULL,
                archivedAt DATETIME
            );
            CREATE UNIQUE INDEX team_key_active ON team(key COLLATE NOCASE) WHERE archivedAt IS NULL;

            CREATE TABLE workflowState (
                id TEXT PRIMARY KEY NOT NULL,
                teamId TEXT NOT NULL REFERENCES team(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                category TEXT NOT NULL CHECK (category IN (\(categories))),
                color TEXT NOT NULL,
                position INTEGER NOT NULL
            );
            CREATE UNIQUE INDEX workflowState_team_name ON workflowState(teamId, name COLLATE NOCASE);

            CREATE TABLE label (
                id TEXT PRIMARY KEY NOT NULL,
                teamId TEXT REFERENCES team(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                color TEXT NOT NULL,
                createdAt DATETIME NOT NULL
            );
            CREATE UNIQUE INDEX label_team_name ON label(teamId, name COLLATE NOCASE) WHERE teamId IS NOT NULL;
            CREATE UNIQUE INDEX label_global_name ON label(name COLLATE NOCASE) WHERE teamId IS NULL;

            CREATE TABLE project (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                slug TEXT NOT NULL,
                summary TEXT NOT NULL DEFAULT '',
                description TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL CHECK (status IN (\(projectStatuses))),
                health TEXT NOT NULL CHECK (health IN (\(projectHealths))),
                leadId TEXT REFERENCES member(id) ON DELETE SET NULL,
                startDate TEXT,
                targetDate TEXT,
                sortKey TEXT NOT NULL,
                createdAt DATETIME NOT NULL,
                updatedAt DATETIME NOT NULL,
                archivedAt DATETIME
            );
            CREATE UNIQUE INDEX project_slug_active ON project(slug) WHERE archivedAt IS NULL;

            CREATE TABLE milestone (
                id TEXT PRIMARY KEY NOT NULL,
                projectId TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                targetDate TEXT,
                sortKey TEXT NOT NULL,
                createdAt DATETIME NOT NULL,
                updatedAt DATETIME NOT NULL
            );
            CREATE INDEX milestone_project ON milestone(projectId, sortKey);

            CREATE TABLE cycle (
                id TEXT PRIMARY KEY NOT NULL,
                teamId TEXT NOT NULL REFERENCES team(id) ON DELETE CASCADE,
                number INTEGER NOT NULL,
                name TEXT,
                startsAt DATETIME NOT NULL,
                endsAt DATETIME NOT NULL,
                completedAt DATETIME,
                createdAt DATETIME NOT NULL,
                updatedAt DATETIME NOT NULL,
                UNIQUE (teamId, number),
                CHECK (endsAt > startsAt)
            );

            CREATE TABLE issue (
                seq INTEGER PRIMARY KEY,
                id TEXT NOT NULL UNIQUE,
                teamId TEXT NOT NULL REFERENCES team(id) ON DELETE RESTRICT,
                number INTEGER NOT NULL,
                identifier TEXT NOT NULL UNIQUE COLLATE NOCASE,
                title TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                stateId TEXT NOT NULL REFERENCES workflowState(id) ON DELETE RESTRICT,
                priority INTEGER NOT NULL DEFAULT 0 CHECK (priority BETWEEN 0 AND 4),
                estimate INTEGER CHECK (estimate >= 0),
                dueDate TEXT,
                sortKey TEXT NOT NULL,
                parentId TEXT REFERENCES issue(id) ON DELETE SET NULL,
                projectId TEXT REFERENCES project(id) ON DELETE SET NULL,
                milestoneId TEXT REFERENCES milestone(id) ON DELETE SET NULL,
                cycleId TEXT REFERENCES cycle(id) ON DELETE SET NULL,
                assigneeId TEXT REFERENCES member(id) ON DELETE SET NULL,
                creatorId TEXT NOT NULL REFERENCES member(id) ON DELETE RESTRICT,
                startedAt DATETIME,
                completedAt DATETIME,
                canceledAt DATETIME,
                stateEnteredAt DATETIME NOT NULL,
                createdAt DATETIME NOT NULL,
                updatedAt DATETIME NOT NULL,
                archivedAt DATETIME,
                version INTEGER NOT NULL DEFAULT 1,
                UNIQUE (teamId, number)
            );
            CREATE INDEX issue_column ON issue(teamId, stateId, sortKey);
            CREATE INDEX issue_parent ON issue(parentId) WHERE parentId IS NOT NULL;
            CREATE INDEX issue_project ON issue(projectId) WHERE projectId IS NOT NULL;
            CREATE INDEX issue_cycle ON issue(cycleId) WHERE cycleId IS NOT NULL;
            CREATE INDEX issue_assignee ON issue(assigneeId) WHERE assigneeId IS NOT NULL;
            CREATE INDEX issue_updated ON issue(updatedAt);

            CREATE TABLE issueAlias (
                identifier TEXT PRIMARY KEY NOT NULL COLLATE NOCASE,
                issueId TEXT NOT NULL REFERENCES issue(id) ON DELETE CASCADE
            );

            CREATE TABLE issueLabel (
                issueId TEXT NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
                labelId TEXT NOT NULL REFERENCES label(id) ON DELETE CASCADE,
                PRIMARY KEY (issueId, labelId)
            ) WITHOUT ROWID;
            CREATE INDEX issueLabel_label ON issueLabel(labelId);

            CREATE TABLE issueRelation (
                issueId TEXT NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
                relatedIssueId TEXT NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
                type TEXT NOT NULL CHECK (type IN (\(relationTypes))),
                createdAt DATETIME NOT NULL,
                PRIMARY KEY (issueId, relatedIssueId, type),
                CHECK (issueId <> relatedIssueId)
            ) WITHOUT ROWID;

            CREATE TABLE comment (
                id TEXT PRIMARY KEY NOT NULL,
                issueId TEXT NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
                authorId TEXT NOT NULL REFERENCES member(id) ON DELETE RESTRICT,
                parentId TEXT REFERENCES comment(id) ON DELETE CASCADE,
                body TEXT NOT NULL,
                createdAt DATETIME NOT NULL,
                editedAt DATETIME,
                deletedAt DATETIME
            );
            CREATE INDEX comment_issue ON comment(issueId, createdAt);

            CREATE TABLE issueActivity (
                id TEXT PRIMARY KEY NOT NULL,
                issueId TEXT NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
                memberId TEXT NOT NULL REFERENCES member(id) ON DELETE RESTRICT,
                field TEXT NOT NULL CHECK (field IN (\(fields))),
                fromValue TEXT,
                toValue TEXT,
                createdAt DATETIME NOT NULL
            );
            CREATE INDEX issueActivity_issue ON issueActivity(issueId, createdAt);

            CREATE TABLE savedView (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                filter TEXT NOT NULL DEFAULT '{}',
                layout TEXT NOT NULL CHECK (layout IN (\(layouts))),
                groupBy TEXT,
                sortKey TEXT NOT NULL,
                createdAt DATETIME NOT NULL,
                updatedAt DATETIME NOT NULL
            );

            CREATE TABLE changeLog (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                model TEXT NOT NULL,
                modelId TEXT NOT NULL,
                action TEXT NOT NULL CHECK (action IN (\(actions))),
                memberId TEXT,
                at DATETIME NOT NULL,
                payload TEXT
            );

            CREATE VIRTUAL TABLE issueSearch USING fts5(
                identifier, title, description,
                content = 'issue', content_rowid = 'seq',
                tokenize = 'unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER issue_search_insert AFTER INSERT ON issue BEGIN
                INSERT INTO issueSearch(rowid, identifier, title, description)
                VALUES (new.seq, new.identifier, new.title, new.description);
            END;
            CREATE TRIGGER issue_search_delete AFTER DELETE ON issue BEGIN
                INSERT INTO issueSearch(issueSearch, rowid, identifier, title, description)
                VALUES ('delete', old.seq, old.identifier, old.title, old.description);
            END;
            CREATE TRIGGER issue_search_update AFTER UPDATE OF identifier, title, description ON issue BEGIN
                INSERT INTO issueSearch(issueSearch, rowid, identifier, title, description)
                VALUES ('delete', old.seq, old.identifier, old.title, old.description);
                INSERT INTO issueSearch(rowid, identifier, title, description)
                VALUES (new.seq, new.identifier, new.title, new.description);
            END;
            """)
    }
}
