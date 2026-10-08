//! Owner-selected source-folder projects and their native provider sessions.
//! Paths are validated by the daemon; this module keeps identity invariants.
use super::*;

pub const EXECUTION_SCOPE_BOTS: &str = "bots";
pub const EXECUTION_SCOPE_PROJECTS: &str = "projects";
pub const MAX_PROJECT_ROOTS: usize = 16;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProjectRootInput {
    pub path: String,
    pub canonical_path: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredProjectRoot {
    pub id: String,
    pub path: String,
    pub canonical_path: String,
    pub ordinal: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredProject {
    pub id: String,
    pub name: String,
    pub is_included: bool,
    pub pin_order: Option<i64>,
    pub primary_root_id: String,
    pub roots_revision: i64,
    pub last_family: Option<AgentFamily>,
    pub created_at: String,
    pub updated_at: String,
    pub last_used_at: Option<String>,
    pub roots: Vec<StoredProjectRoot>,
}

impl StoredProject {
    pub fn primary_root(&self) -> &StoredProjectRoot {
        self.roots
            .iter()
            .find(|root| root.id == self.primary_root_id)
            .unwrap_or(&self.roots[0])
    }
    /// Exact membership, never string-prefix matching.
    pub fn root_for(&self, path: &str) -> Option<&StoredProjectRoot> {
        self.roots
            .iter()
            .find(|root| root.path == path || root.canonical_path == path)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProjectCreate {
    Created(StoredProject),
    Existing(StoredProject),
    Conflict,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredProjectConversation {
    pub conversation_id: String,
    pub project_id: String,
    pub family: AgentFamily,
    pub provider_store: String,
    pub native_session_id: Option<String>,
    pub cwd: String,
    pub roots_revision: i64,
    pub title: String,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub service_tier: Option<String>,
    pub access_mode: String,
    /// How a Claude thread asks before acting; always `ask` for Codex threads.
    pub claude_approval: String,
    pub plan_mode: bool,
    /// The newest native turn made outside Wonder whose settings this thread
    /// already took, so a later change on the phone wins until the desktop
    /// app runs another turn.
    pub native_settings_turn: Option<String>,
    pub is_pinned: bool,
    pub has_unread: bool,
    pub creation_request_id: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub last_activity_at: String,
}

#[derive(Clone, Debug)]
pub struct ProjectConversationInsert<'a> {
    pub conversation_id: &'a str,
    pub project_id: &'a str,
    pub family: AgentFamily,
    pub provider_store: &'a str,
    pub native_session_id: Option<&'a str>,
    pub cwd: &'a str,
    pub roots_revision: i64,
    pub title: &'a str,
    pub model: Option<&'a str>,
    pub effort: Option<&'a str>,
    pub service_tier: Option<&'a str>,
    pub access_mode: &'a str,
    pub claude_approval: &'a str,
    pub plan_mode: bool,
    pub creation_request_id: Option<&'a str>,
    pub now: &'a str,
}

/// Fields a PATCH may change; `None` leaves a field as it is.
#[derive(Clone, Debug, Default)]
pub struct ProjectConversationPatch<'a> {
    pub title: Option<&'a str>,
    pub pinned: Option<bool>,
    pub unread: Option<bool>,
    pub model: Option<&'a str>,
    /// Omitted preserves the current effort; `Some(None)` clears it.
    pub effort: Option<Option<&'a str>>,
    /// Omitted preserves speed; `Some(None)` returns to Standard.
    pub service_tier: Option<Option<&'a str>>,
    pub access_mode: Option<&'a str>,
    pub claude_approval: Option<&'a str>,
    pub plan_mode: Option<bool>,
    pub native_settings_turn: Option<&'a str>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProjectConversationCreate {
    Created(StoredProjectConversation),
    Existing(StoredProjectConversation),
}

fn project_creation_payload(
    insert: &ProjectConversationInsert<'_>,
    request_digest: Option<&str>,
) -> serde_json::Value {
    let mut payload = serde_json::json!([
        insert.project_id,
        insert.family.as_str(),
        insert.provider_store,
        insert.cwd,
        insert.roots_revision,
        insert.model,
        insert.effort,
        insert.access_mode,
        insert.claude_approval,
        i64::from(insert.plan_mode)
    ]);
    // Migration 0080 and existing requests use ten fields when speed is omitted.
    if let Some(tier) = insert.service_tier {
        payload
            .as_array_mut()
            .unwrap()
            .push(serde_json::json!(tier));
    }
    match request_digest {
        Some(digest) => serde_json::json!({
            "version": 2,
            "resolved": payload,
            "requestDigest": digest,
        }),
        None => payload,
    }
}

fn matching_project_creation(
    row: &sqlx::sqlite::SqliteRow,
    payload: &serde_json::Value,
) -> Result<StoredProjectConversation, sqlx::Error> {
    let original: Option<String> = row.get("creation_payload");
    let original =
        original.and_then(|value| serde_json::from_str::<serde_json::Value>(&value).ok());
    if original.as_ref() != Some(payload) {
        return Err(invalid("creation_request_conflict"));
    }
    project_conversation(row)
}

fn invalid(message: &str) -> sqlx::Error {
    sqlx::Error::Protocol(message.into())
}

pub(crate) fn project_conversation(
    row: &sqlx::sqlite::SqliteRow,
) -> Result<StoredProjectConversation, sqlx::Error> {
    Ok(StoredProjectConversation {
        conversation_id: row.get("conversation_id"),
        project_id: row.get("project_id"),
        family: family(row.get("agent_family"))?,
        provider_store: row.get("provider_store"),
        native_session_id: row.get("native_session_id"),
        cwd: row.get("cwd"),
        roots_revision: row.get("roots_revision"),
        title: row.get("title"),
        model: row.get("model"),
        effort: row.get("effort"),
        service_tier: row.get("service_tier"),
        access_mode: row.get("access_mode"),
        claude_approval: row.get("claude_approval"),
        plan_mode: row.get::<i64, _>("plan_mode") != 0,
        // Absent before migration 0091, which upgrade tests read through.
        native_settings_turn: row.try_get("native_settings_turn").unwrap_or(None),
        is_pinned: row.get::<i64, _>("is_pinned") != 0,
        has_unread: row.get::<i64, _>("has_unread") != 0,
        creation_request_id: row.get("creation_request_id"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
        last_activity_at: row.get("last_activity_at"),
    })
}

fn family(value: &str) -> Result<AgentFamily, sqlx::Error> {
    match value {
        "codex" => Ok(AgentFamily::Codex),
        "claude" => Ok(AgentFamily::Claude),
        _ => Err(invalid("Unknown agent family")),
    }
}

fn validate_roots(roots: &[ProjectRootInput], primary: usize) -> Result<(), sqlx::Error> {
    if roots.is_empty() || roots.len() > MAX_PROJECT_ROOTS || primary >= roots.len() {
        return Err(invalid("A project needs between one and sixteen folders"));
    }
    let mut seen = std::collections::HashSet::new();
    for root in roots {
        if !root.path.starts_with('/')
            || !root.canonical_path.starts_with('/')
            || root.path.len() > 4096
            || root.canonical_path.len() > 4096
            || !seen.insert(root.canonical_path.as_str())
        {
            return Err(invalid("Project folders must be distinct absolute paths"));
        }
    }
    Ok(())
}

const ACCESS_MODES: [&str; 3] = ["read_only", "workspace", "full_access"];

impl Store {
    async fn load_project(
        &self,
        executor: &mut sqlx::SqliteConnection,
        id: &str,
    ) -> Result<Option<StoredProject>, sqlx::Error> {
        let Some(row) = sqlx::query("SELECT * FROM projects WHERE id=?")
            .bind(id)
            .fetch_optional(&mut *executor)
            .await?
        else {
            return Ok(None);
        };
        let roots = sqlx::query("SELECT id,path,canonical_path,ordinal FROM project_roots WHERE project_id=? ORDER BY ordinal")
            .bind(id)
            .fetch_all(&mut *executor)
            .await?
            .iter()
            .map(|root| StoredProjectRoot {
                id: root.get("id"),
                path: root.get("path"),
                canonical_path: root.get("canonical_path"),
                ordinal: root.get("ordinal"),
            })
            .collect::<Vec<_>>();
        if roots.is_empty() {
            return Err(invalid("Project has no folders"));
        }
        Ok(Some(StoredProject {
            id: row.get("id"),
            name: row.get("name"),
            is_included: row.get::<i64, _>("is_included") != 0,
            pin_order: row.get("pin_order"),
            primary_root_id: row.get("primary_root_id"),
            roots_revision: row.get("roots_revision"),
            last_family: row
                .get::<Option<String>, _>("last_family")
                .as_deref()
                .map(family)
                .transpose()?,
            created_at: row.get("created_at"),
            updated_at: row.get("updated_at"),
            last_used_at: row.get("last_used_at"),
            roots,
        }))
    }

    async fn insert_roots(
        tx: &mut sqlx::SqliteConnection,
        project: &str,
        roots: &[ProjectRootInput],
    ) -> Result<Vec<String>, sqlx::Error> {
        let mut ids = Vec::with_capacity(roots.len());
        for (ordinal, root) in roots.iter().enumerate() {
            let id = uuid::Uuid::new_v4().to_string();
            sqlx::query("INSERT INTO project_roots(id,project_id,path,canonical_path,ordinal) VALUES(?,?,?,?,?)")
                .bind(&id).bind(project).bind(&root.path).bind(&root.canonical_path).bind(ordinal as i64)
                .execute(&mut *tx).await?;
            ids.push(id);
        }
        Ok(ids)
    }

    /// Metadata-only and idempotent by request ID; a changed payload conflicts.
    #[allow(clippy::too_many_arguments)]
    pub async fn create_project(
        &self,
        id: &str,
        request_id: &str,
        payload_sha256: &str,
        name: &str,
        roots: &[ProjectRootInput],
        primary: usize,
        now: &str,
    ) -> Result<ProjectCreate, sqlx::Error> {
        validate_roots(roots, primary)?;
        let name = name.trim();
        if name.is_empty() || name.chars().count() > 120 {
            return Err(invalid(
                "Project names must be between 1 and 120 characters",
            ));
        }
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        if let Some(row) = sqlx::query(
            "SELECT id,creation_payload_sha256 FROM projects WHERE creation_request_id=?",
        )
        .bind(request_id)
        .fetch_optional(&mut *tx)
        .await?
        {
            if row
                .get::<Option<String>, _>("creation_payload_sha256")
                .as_deref()
                != Some(payload_sha256)
            {
                return Ok(ProjectCreate::Conflict);
            }
            let existing: String = row.get("id");
            let project = self
                .load_project(&mut tx, &existing)
                .await?
                .ok_or_else(|| invalid("missing project"))?;
            tx.commit().await?;
            return Ok(ProjectCreate::Existing(project));
        }
        // The primary root ID is known only after insert; the row is completed
        // before commit so no reader can observe a project without a primary.
        sqlx::query("INSERT INTO projects(id,name,primary_root_id,creation_request_id,creation_payload_sha256,created_at,updated_at) VALUES(?,?,'',?,?,?,?)")
            .bind(id).bind(name).bind(request_id).bind(payload_sha256).bind(now).bind(now)
            .execute(&mut *tx).await?;
        let ids = Self::insert_roots(&mut tx, id, roots).await?;
        sqlx::query("UPDATE projects SET primary_root_id=? WHERE id=?")
            .bind(&ids[primary])
            .bind(id)
            .execute(&mut *tx)
            .await?;
        let project = self
            .load_project(&mut tx, id)
            .await?
            .ok_or_else(|| invalid("missing project"))?;
        tx.commit().await?;
        Ok(ProjectCreate::Created(project))
    }

    pub async fn project(&self, id: &str) -> Result<Option<StoredProject>, sqlx::Error> {
        let mut connection = self.pool.acquire().await?;
        self.load_project(&mut connection, id).await
    }

    pub async fn list_projects(&self) -> Result<Vec<StoredProject>, sqlx::Error> {
        let mut connection = self.pool.acquire().await?;
        let ids: Vec<String> = sqlx::query_scalar("SELECT id FROM projects ORDER BY pin_order IS NULL, pin_order, COALESCE(last_used_at, created_at) DESC, id")
            .fetch_all(&mut *connection)
            .await?;
        let mut projects = Vec::with_capacity(ids.len());
        for id in ids {
            if let Some(project) = self.load_project(&mut connection, &id).await? {
                projects.push(project);
            }
        }
        Ok(projects)
    }

    /// Name, visibility and pin changes never touch folders or provider state.
    pub async fn update_project_metadata(
        &self,
        id: &str,
        name: Option<&str>,
        included: Option<bool>,
        pinned: Option<bool>,
        now: &str,
    ) -> Result<Option<StoredProject>, sqlx::Error> {
        if let Some(name) = name {
            let name = name.trim();
            if name.is_empty() || name.chars().count() > 120 {
                return Err(invalid(
                    "Project names must be between 1 and 120 characters",
                ));
            }
        }
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let updated = sqlx::query("UPDATE projects SET name=COALESCE(?,name), is_included=COALESCE(?,is_included), updated_at=? WHERE id=?")
            .bind(name.map(str::trim)).bind(included.map(i64::from)).bind(now).bind(id)
            .execute(&mut *tx).await?;
        if updated.rows_affected() == 0 {
            return Ok(None);
        }
        match pinned {
            Some(true) => {
                sqlx::query("UPDATE projects SET pin_order=(SELECT COALESCE(MAX(pin_order),0)+1 FROM projects) WHERE id=? AND pin_order IS NULL")
                    .bind(id).execute(&mut *tx).await?;
            }
            Some(false) => {
                sqlx::query("UPDATE projects SET pin_order=NULL WHERE id=?")
                    .bind(id)
                    .execute(&mut *tx)
                    .await?;
            }
            None => {}
        }
        let project = self.load_project(&mut tx, id).await?;
        tx.commit().await?;
        Ok(project)
    }

    /// Replaces folders when the caller saw the current revision. Existing
    /// conversations keep their recorded cwd; dispatch revalidates membership.
    pub async fn update_project_roots(
        &self,
        id: &str,
        expected_revision: i64,
        roots: &[ProjectRootInput],
        primary: usize,
        now: &str,
    ) -> Result<Option<StoredProject>, sqlx::Error> {
        validate_roots(roots, primary)?;
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let Some(current) = self.load_project(&mut tx, id).await? else {
            return Ok(None);
        };
        if current.roots_revision != expected_revision {
            return Err(invalid("roots_revision_changed"));
        }
        // Keep IDs for unchanged folders so references remain stable.
        let mut ids = Vec::with_capacity(roots.len());
        sqlx::query("UPDATE project_roots SET ordinal=-1-ordinal WHERE project_id=?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        for (ordinal, root) in roots.iter().enumerate() {
            let existing = current
                .roots
                .iter()
                .find(|r| r.canonical_path == root.canonical_path);
            let root_id = existing
                .map(|r| r.id.clone())
                .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
            if existing.is_some() {
                sqlx::query("UPDATE project_roots SET path=?,ordinal=? WHERE id=?")
                    .bind(&root.path)
                    .bind(ordinal as i64)
                    .bind(&root_id)
                    .execute(&mut *tx)
                    .await?;
            } else {
                sqlx::query("INSERT INTO project_roots(id,project_id,path,canonical_path,ordinal) VALUES(?,?,?,?,?)")
                    .bind(&root_id).bind(id).bind(&root.path).bind(&root.canonical_path).bind(ordinal as i64)
                    .execute(&mut *tx).await?;
            }
            ids.push(root_id);
        }
        sqlx::query("DELETE FROM project_roots WHERE project_id=? AND ordinal<0")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE projects SET primary_root_id=?,roots_revision=roots_revision+1,updated_at=? WHERE id=?")
            .bind(&ids[primary]).bind(now).bind(id).execute(&mut *tx).await?;
        let project = self.load_project(&mut tx, id).await?;
        tx.commit().await?;
        Ok(project)
    }

    pub async fn touch_project(
        &self,
        id: &str,
        family: AgentFamily,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE projects SET last_family=?,last_used_at=? WHERE id=?")
            .bind(family.as_str())
            .bind(now)
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn project_provider_ref(
        &self,
        project: &str,
        family: AgentFamily,
        store: &str,
    ) -> Result<Option<String>, sqlx::Error> {
        sqlx::query_scalar("SELECT provider_project_id FROM project_provider_refs WHERE project_id=? AND agent_family=? AND provider_store=?")
            .bind(project).bind(family.as_str()).bind(store)
            .fetch_optional(&self.pool).await
    }

    /// First writer wins so a late duplicate creation cannot retarget a project.
    pub async fn set_project_provider_ref(
        &self,
        project: &str,
        family: AgentFamily,
        store: &str,
        provider_project_id: &str,
    ) -> Result<String, sqlx::Error> {
        sqlx::query("INSERT INTO project_provider_refs(project_id,agent_family,provider_store,provider_project_id) VALUES(?,?,?,?) ON CONFLICT DO NOTHING")
            .bind(project).bind(family.as_str()).bind(store).bind(provider_project_id)
            .execute(&self.pool).await?;
        self.project_provider_ref(project, family, store)
            .await?
            .ok_or_else(|| invalid("missing provider project"))
    }

    /// Replace only the stale reference this caller checked. A concurrent
    /// repair keeps its choice; callers must validate the returned winner.
    pub async fn replace_project_provider_ref(
        &self,
        project: &str,
        family: AgentFamily,
        store: &str,
        expected: &str,
        provider_project_id: &str,
    ) -> Result<String, sqlx::Error> {
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        sqlx::query("UPDATE project_provider_refs SET provider_project_id=? WHERE project_id=? AND agent_family=? AND provider_store=? AND provider_project_id=?")
            .bind(provider_project_id).bind(project).bind(family.as_str()).bind(store).bind(expected)
            .execute(&mut *tx).await?;
        let winner = sqlx::query_scalar("SELECT provider_project_id FROM project_provider_refs WHERE project_id=? AND agent_family=? AND provider_store=?")
            .bind(project).bind(family.as_str()).bind(store).fetch_one(&mut *tx).await?;
        tx.commit().await?;
        Ok(winner)
    }

    /// Check an existing creation before validating today's runtime catalog.
    /// A retry must recover the original thread even if its model disappeared.
    pub async fn existing_project_creation(
        &self,
        insert: &ProjectConversationInsert<'_>,
    ) -> Result<Option<StoredProjectConversation>, sqlx::Error> {
        let Some(request) = insert.creation_request_id else {
            return Ok(None);
        };
        let row = sqlx::query("SELECT * FROM project_conversations WHERE creation_request_id=?")
            .persistent(false)
            .bind(request)
            .fetch_optional(&self.pool)
            .await?;
        row.as_ref()
            .map(|row| matching_project_creation(row, &project_creation_payload(insert, None)))
            .transpose()
    }

    /// The immutable request payload is read before current runtime/folder
    /// gates so an already accepted creation can replay its original receipt.
    pub async fn project_creation_by_request(
        &self,
        request_id: &str,
    ) -> Result<Option<(StoredProjectConversation, serde_json::Value)>, sqlx::Error> {
        let row = sqlx::query("SELECT * FROM project_conversations WHERE creation_request_id=?")
            .persistent(false)
            .bind(request_id)
            .fetch_optional(&self.pool)
            .await?;
        row.map(|row| {
            let payload: Option<String> = row.get("creation_payload");
            let payload = payload
                .and_then(|value| serde_json::from_str(&value).ok())
                .ok_or_else(|| invalid("creation_payload_unavailable"))?;
            Ok((project_conversation(&row)?, payload))
        })
        .transpose()
    }

    /// Idempotent by creation request and by native identity: rediscovering a
    /// session returns its existing conversation instead of a duplicate.
    pub async fn create_project_conversation(
        &self,
        insert: ProjectConversationInsert<'_>,
    ) -> Result<ProjectConversationCreate, sqlx::Error> {
        self.create_project_conversation_inner(insert, None).await
    }

    pub async fn create_project_conversation_with_request_digest(
        &self,
        insert: ProjectConversationInsert<'_>,
        request_digest: &str,
    ) -> Result<ProjectConversationCreate, sqlx::Error> {
        self.create_project_conversation_inner(insert, Some(request_digest))
            .await
    }

    async fn create_project_conversation_inner(
        &self,
        insert: ProjectConversationInsert<'_>,
        request_digest: Option<&str>,
    ) -> Result<ProjectConversationCreate, sqlx::Error> {
        if !ACCESS_MODES.contains(&insert.access_mode) {
            return Err(invalid("Unknown project access mode"));
        }
        if !AgentFamily::is_known_approval_mode(insert.claude_approval) {
            return Err(invalid("Unknown Claude approval mode"));
        }
        if !insert.family.allows_approval_choice()
            && insert.claude_approval != insert.family.provider().default_approval
        {
            return Err(invalid("Claude approval applies only to Claude threads"));
        }
        if insert.title.trim().is_empty() || insert.title.len() > 400 {
            return Err(invalid("Invalid conversation title"));
        }
        let creation_payload = project_creation_payload(&insert, request_digest);
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        if let Some(request) = insert.creation_request_id {
            if let Some(row) =
                sqlx::query("SELECT * FROM project_conversations WHERE creation_request_id=?")
                    .persistent(false)
                    .bind(request)
                    .fetch_optional(&mut *tx)
                    .await?
            {
                // Compare the original request, never settings changed by PATCH.
                let existing = matching_project_creation(&row, &creation_payload)?;
                tx.commit().await?;
                return Ok(ProjectConversationCreate::Existing(existing));
            }
        }
        if let Some(native) = insert.native_session_id {
            if let Some(row) = sqlx::query("SELECT * FROM project_conversations WHERE agent_family=? AND provider_store=? AND native_session_id=?")
                .bind(insert.family.as_str()).bind(insert.provider_store).bind(native)
                .fetch_optional(&mut *tx).await?
            {
                tx.commit().await?;
                return Ok(ProjectConversationCreate::Existing(project_conversation(&row)?));
            }
        }
        let owned: i64 = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM conversation_metadata WHERE id=?) OR EXISTS(SELECT 1 FROM runtime_bindings WHERE conversation_id=?)")
            .bind(insert.conversation_id).bind(insert.conversation_id).fetch_one(&mut *tx).await?;
        if owned != 0 {
            return Err(invalid("conversation_already_owned"));
        }
        sqlx::query("INSERT INTO conversations(id,codex_thread_id,session_id,created_at) VALUES(?,NULL,NULL,?)")
            .bind(insert.conversation_id).bind(insert.now).execute(&mut *tx).await?;
        sqlx::query("INSERT INTO project_conversations(conversation_id,project_id,agent_family,provider_store,native_session_id,cwd,roots_revision,title,model,effort,service_tier,access_mode,claude_approval,plan_mode,creation_request_id,creation_payload,created_at,updated_at,last_activity_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
            .bind(insert.conversation_id).bind(insert.project_id).bind(insert.family.as_str())
            .bind(insert.provider_store).bind(insert.native_session_id).bind(insert.cwd)
            .bind(insert.roots_revision).bind(insert.title.trim()).bind(insert.model).bind(insert.effort).bind(insert.service_tier)
            .bind(insert.access_mode).bind(insert.claude_approval).bind(i64::from(insert.plan_mode))
            .bind(insert.creation_request_id).bind(insert.creation_request_id.map(|_| creation_payload.to_string()))
            .bind(insert.now).bind(insert.now).bind(insert.now)
            .execute(&mut *tx).await?;
        let row = sqlx::query("SELECT * FROM project_conversations WHERE conversation_id=?")
            .bind(insert.conversation_id)
            .fetch_one(&mut *tx)
            .await?;
        let created = project_conversation(&row)?;
        tx.commit().await?;
        Ok(ProjectConversationCreate::Created(created))
    }

    pub async fn project_conversation(
        &self,
        conversation: &str,
    ) -> Result<Option<StoredProjectConversation>, sqlx::Error> {
        sqlx::query("SELECT * FROM project_conversations WHERE conversation_id=?")
            .bind(conversation)
            .fetch_optional(&self.pool)
            .await?
            .as_ref()
            .map(project_conversation)
            .transpose()
    }

    pub async fn project_conversation_by_native(
        &self,
        family: AgentFamily,
        store: &str,
        native: &str,
    ) -> Result<Option<StoredProjectConversation>, sqlx::Error> {
        sqlx::query("SELECT * FROM project_conversations WHERE agent_family=? AND provider_store=? AND native_session_id=?")
            .bind(family.as_str()).bind(store).bind(native)
            .fetch_optional(&self.pool).await?
            .as_ref().map(project_conversation).transpose()
    }

    pub async fn project_conversations(
        &self,
        project: &str,
    ) -> Result<Vec<StoredProjectConversation>, sqlx::Error> {
        sqlx::query("SELECT * FROM project_conversations WHERE project_id=? ORDER BY is_pinned DESC, last_activity_at DESC, conversation_id")
            .bind(project)
            .fetch_all(&self.pool)
            .await?
            .iter()
            .map(project_conversation)
            .collect()
    }

    /// Remembers which conversation a fork was copied from and where it was cut.
    pub async fn record_project_fork(
        &self,
        conversation: &str,
        source: &str,
        at_turn: Option<&str>,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT INTO project_conversation_forks(conversation_id,forked_from,forked_at_turn) VALUES(?,?,?)")
            .bind(conversation).bind(source).bind(at_turn)
            .execute(&self.pool).await?;
        Ok(())
    }

    /// The conversation a fork came from and the turn it was cut at.
    pub async fn project_fork_source(
        &self,
        conversation: &str,
    ) -> Result<Option<(String, Option<String>)>, sqlx::Error> {
        let row = sqlx::query("SELECT forked_from,forked_at_turn FROM project_conversation_forks WHERE conversation_id=?")
            .bind(conversation).fetch_optional(&self.pool).await?;
        Ok(row.map(|row| (row.get("forked_from"), row.get("forked_at_turn"))))
    }

    /// Records the provider's actual session exactly once.
    pub async fn set_project_native_session(
        &self,
        conversation: &str,
        native: &str,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        let updated = sqlx::query("UPDATE project_conversations SET native_session_id=?,updated_at=? WHERE conversation_id=? AND (native_session_id IS NULL OR native_session_id=?)")
            .bind(native).bind(now).bind(conversation).bind(native)
            .execute(&self.pool).await?;
        if updated.rows_affected() != 1 {
            return Err(invalid(
                "The conversation already has another native session",
            ));
        }
        Ok(())
    }

    pub async fn update_project_conversation(
        &self,
        conversation: &str,
        patch: ProjectConversationPatch<'_>,
        now: &str,
    ) -> Result<Option<StoredProjectConversation>, sqlx::Error> {
        self.update_project_conversation_with_expected_settings(conversation, patch, None, now)
            .await
    }

    /// Reject a settings PATCH if another device changed model, effort, or
    /// speed after the caller validated their combined values.
    pub async fn update_project_conversation_if_settings_match(
        &self,
        conversation: &str,
        patch: ProjectConversationPatch<'_>,
        expected_model: Option<&str>,
        expected_effort: Option<&str>,
        expected_tier: Option<&str>,
        now: &str,
    ) -> Result<Option<StoredProjectConversation>, sqlx::Error> {
        self.update_project_conversation_with_expected_settings(
            conversation,
            patch,
            Some((expected_model, expected_effort, expected_tier)),
            now,
        )
        .await
    }

    async fn update_project_conversation_with_expected_settings(
        &self,
        conversation: &str,
        patch: ProjectConversationPatch<'_>,
        expected: Option<(Option<&str>, Option<&str>, Option<&str>)>,
        now: &str,
    ) -> Result<Option<StoredProjectConversation>, sqlx::Error> {
        if patch
            .access_mode
            .is_some_and(|mode| !ACCESS_MODES.contains(&mode))
        {
            return Err(invalid("Unknown project access mode"));
        }
        if patch
            .claude_approval
            .is_some_and(|mode| !AgentFamily::is_known_approval_mode(mode))
        {
            return Err(invalid("Unknown Claude approval mode"));
        }
        if patch
            .title
            .is_some_and(|title| title.trim().is_empty() || title.len() > 400)
        {
            return Err(invalid("Invalid conversation title"));
        }
        if patch.claude_approval.is_some() {
            // A thread's family never changes, so this check cannot race.
            let family: Option<String> = sqlx::query_scalar(
                "SELECT agent_family FROM project_conversations WHERE conversation_id=?",
            )
            .bind(conversation)
            .fetch_optional(&self.pool)
            .await?;
            if family
                .as_deref()
                .map(self::family)
                .transpose()?
                .is_some_and(|family| !family.allows_approval_choice())
            {
                return Err(invalid("Claude approval applies only to Claude threads"));
            }
        }
        let updated = sqlx::query("UPDATE project_conversations SET title=COALESCE(?,title),is_pinned=COALESCE(?,is_pinned),has_unread=COALESCE(?,has_unread),model=COALESCE(?,model),effort=CASE WHEN ? THEN ? ELSE effort END,service_tier=CASE WHEN ? THEN ? ELSE service_tier END,access_mode=COALESCE(?,access_mode),claude_approval=COALESCE(?,claude_approval),plan_mode=COALESCE(?,plan_mode),native_settings_turn=COALESCE(?,native_settings_turn),updated_at=? WHERE conversation_id=? AND (?=0 OR (model IS ? AND effort IS ? AND service_tier IS ?))")
            .bind(patch.title.map(str::trim)).bind(patch.pinned.map(i64::from)).bind(patch.unread.map(i64::from))
            .bind(patch.model).bind(patch.effort.is_some()).bind(patch.effort.flatten())
            .bind(patch.service_tier.is_some()).bind(patch.service_tier.flatten()).bind(patch.access_mode)
            .bind(patch.claude_approval).bind(patch.plan_mode.map(i64::from))
            .bind(patch.native_settings_turn)
            .bind(now).bind(conversation).bind(expected.is_some())
            .bind(expected.and_then(|value| value.0))
            .bind(expected.and_then(|value| value.1))
            .bind(expected.and_then(|value| value.2))
            .execute(&self.pool).await?;
        if updated.rows_affected() == 0 {
            return if expected.is_some() && self.project_conversation(conversation).await?.is_some()
            {
                Err(invalid("project_settings_changed"))
            } else {
                Ok(None)
            };
        }
        self.project_conversation(conversation).await
    }

    /// Native turn ids Wonder itself started in this conversation.
    pub async fn wonder_turn_ids(&self, conversation: &str) -> Result<Vec<String>, sqlx::Error> {
        sqlx::query_scalar("SELECT codex_turn_id FROM messages WHERE conversation_id=? AND codex_turn_id IS NOT NULL")
            .bind(conversation).fetch_all(&self.pool).await
    }

    /// The settings accepted with this message, independent of later edits.
    /// Pre-upgrade messages without a snapshot use current thread settings.
    pub async fn project_message_execution_settings(
        &self,
        message: &str,
    ) -> Result<Option<(Option<String>, Option<String>, Option<String>)>, sqlx::Error> {
        let row = sqlx::query("SELECT model,reasoning_effort,service_tier FROM message_execution_settings WHERE message_id=?")
            .bind(message).fetch_optional(&self.pool).await?;
        Ok(row.map(|row| {
            (
                row.get("model"),
                row.get("reasoning_effort"),
                row.get("service_tier"),
            )
        }))
    }

    /// Attached, pinned conversations of included projects, newest activity first.
    pub async fn pinned_project_conversations(
        &self,
        limit: i64,
    ) -> Result<Vec<StoredProjectConversation>, sqlx::Error> {
        sqlx::query("SELECT c.* FROM project_conversations c JOIN projects p ON p.id=c.project_id WHERE c.is_pinned=1 AND p.is_included=1 ORDER BY c.last_activity_at DESC, c.conversation_id LIMIT ?")
            .bind(limit)
            .fetch_all(&self.pool)
            .await?
            .iter()
            .map(project_conversation)
            .collect()
    }

    pub async fn touch_project_conversation(
        &self,
        conversation: &str,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE project_conversations SET last_activity_at=? WHERE conversation_id=?")
            .bind(now)
            .bind(conversation)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// A project binding is created once; Bot bindings can never be adopted.
    pub async fn bind_project_runtime(
        &self,
        conversation: &str,
        family: AgentFamily,
        provider_store: &str,
        thread: &str,
        session: Option<&str>,
        now: &str,
    ) -> Result<(), sqlx::Error> {
        if thread.trim().is_empty() || thread.len() > 512 || !family.accepts_thread_id(thread) {
            return Err(invalid("Invalid provider session identity"));
        }
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let owner: Option<String> = sqlx::query_scalar(
            "SELECT agent_family FROM project_conversations WHERE conversation_id=?",
        )
        .bind(conversation)
        .fetch_optional(&mut *tx)
        .await?;
        if owner.as_deref() != Some(family.as_str()) {
            return Err(invalid(
                "The project conversation belongs to another agent family",
            ));
        }
        if let Some(existing) = sqlx::query("SELECT runtime_thread_id,execution_scope FROM runtime_bindings WHERE conversation_id=?")
            .bind(conversation).fetch_optional(&mut *tx).await?
        {
            if existing.get::<String, _>("execution_scope") != EXECUTION_SCOPE_PROJECTS
                || existing.get::<String, _>("runtime_thread_id") != thread
            {
                return Err(invalid("The project conversation is bound to another session"));
            }
        }
        let foreign: i64 = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM runtime_bindings WHERE runtime_thread_id=? AND conversation_id<>?)")
            .bind(thread).bind(conversation).fetch_one(&mut *tx).await?;
        if foreign != 0 {
            return Err(invalid(
                "The native session already belongs to another conversation",
            ));
        }
        sqlx::query("UPDATE conversations SET codex_thread_id=?,session_id=COALESCE(?,session_id) WHERE id=?")
            .bind(thread).bind(session).bind(conversation).execute(&mut *tx).await?;
        sqlx::query("INSERT INTO runtime_bindings(conversation_id,agent_family,runtime_thread_id,session_id,updated_at,execution_scope,provider_store) VALUES(?,?,?,?,?,'projects',?) ON CONFLICT(conversation_id) DO UPDATE SET session_id=COALESCE(excluded.session_id,runtime_bindings.session_id),updated_at=excluded.updated_at")
            .bind(conversation).bind(family.as_str()).bind(thread).bind(session).bind(now).bind(provider_store)
            .execute(&mut *tx).await?;
        tx.commit().await
    }

    /// Family and execution scope for a transport thread, if Wonder owns it.
    pub async fn runtime_route_for_thread(
        &self,
        thread: &str,
    ) -> Result<Option<(AgentFamily, String)>, sqlx::Error> {
        let row = sqlx::query("SELECT agent_family,execution_scope FROM runtime_bindings WHERE runtime_thread_id=? LIMIT 1")
            .bind(thread).fetch_optional(&self.pool).await?;
        row.map(|row| Ok((family(row.get("agent_family"))?, row.get("execution_scope"))))
            .transpose()
    }

    /// Whether Wonder currently owns an admitted or running turn here.
    pub async fn conversation_has_active_turn(
        &self,
        conversation: &str,
    ) -> Result<bool, sqlx::Error> {
        let active: i64 = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM messages WHERE conversation_id=? AND state IN ('accepted_by_wonder','dispatching_to_codex','accepted_by_codex','streaming'))")
            .bind(conversation).fetch_one(&self.pool).await?;
        Ok(active != 0)
    }

    pub async fn conversation_has_archive_blocking_work(
        &self,
        conversation: &str,
    ) -> Result<bool, sqlx::Error> {
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM messages WHERE conversation_id=? AND state IN ('accepted_by_wonder','dispatching_to_codex','accepted_by_codex','streaming','uncertain'))")
            .bind(conversation).fetch_one(&self.pool).await
    }

    /// Claude SDK sessions already owned by Bots, excluded from project catalogs.
    pub async fn bot_claude_sessions(&self) -> Result<Vec<String>, sqlx::Error> {
        sqlx::query_scalar("SELECT session_id FROM runtime_bindings WHERE agent_family='claude' AND execution_scope='bots' AND session_id IS NOT NULL")
            .fetch_all(&self.pool).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roots(paths: &[&str]) -> Vec<ProjectRootInput> {
        paths
            .iter()
            .map(|path| ProjectRootInput {
                path: (*path).into(),
                canonical_path: (*path).into(),
            })
            .collect()
    }

    async fn project(store: &Store, id: &str, paths: &[&str]) -> StoredProject {
        match store
            .create_project(
                id,
                &format!("request-{id}"),
                "hash",
                "App",
                &roots(paths),
                0,
                "now",
            )
            .await
            .unwrap()
        {
            ProjectCreate::Created(project) => project,
            other => panic!("{other:?}"),
        }
    }

    fn conversation<'a>(
        id: &'a str,
        project: &'a str,
        native: Option<&'a str>,
        request: Option<&'a str>,
    ) -> ProjectConversationInsert<'a> {
        ProjectConversationInsert {
            conversation_id: id,
            project_id: project,
            family: AgentFamily::Codex,
            provider_store: "codex:home",
            native_session_id: native,
            cwd: "/work/app",
            roots_revision: 1,
            title: "Fix",
            model: None,
            effort: None,
            service_tier: None,
            access_mode: "workspace",
            claude_approval: "ask",
            plan_mode: false,
            creation_request_id: request,
            now: "now",
        }
    }

    // Contract: Full access no longer keeps a command sandbox. Upgrading must
    // not widen a Claude thread that chose Full access with sandboxed commands:
    // it moves to Auto; an explicit opt-out and every other thread keep their modes.
    #[tokio::test]
    async fn sandboxed_full_access_threads_move_to_auto_on_upgrade() {
        let dir = tempfile::tempdir().unwrap();
        let url = format!(
            "sqlite://{}?mode=rwc",
            dir.path().join("prior.sqlite").display()
        );
        let pool = sqlx::SqlitePool::connect(&url).await.unwrap();
        let mut prior = sqlx::migrate!();
        prior.migrations = std::borrow::Cow::Owned(
            prior
                .migrations
                .iter()
                .filter(|m| m.version < 90)
                .cloned()
                .collect(),
        );
        prior.run(&pool).await.unwrap();
        let old = Store { pool };
        project(&old, "p1", &["/work/app"]).await;
        for (id, family, access, approval, opted_out) in [
            (
                "sandboxed",
                AgentFamily::Claude,
                "full_access",
                "ask",
                false,
            ),
            ("opted-out", AgentFamily::Claude, "full_access", "ask", true),
            ("asking", AgentFamily::Claude, "workspace", "ask", false),
            ("codex", AgentFamily::Codex, "full_access", "ask", false),
        ] {
            old.create_project_conversation(ProjectConversationInsert {
                family,
                access_mode: access,
                claude_approval: approval,
                ..conversation(id, "p1", None, None)
            })
            .await
            .unwrap();
            sqlx::query(
                "UPDATE project_conversations SET unsandboxed_commands=? WHERE conversation_id=?",
            )
            .bind(i64::from(opted_out))
            .bind(id)
            .execute(&old.pool)
            .await
            .unwrap();
        }
        sqlx::migrate!().run(&old.pool).await.unwrap();
        for (id, access, approval) in [
            ("sandboxed", "workspace", "auto"),
            ("opted-out", "full_access", "ask"),
            ("asking", "workspace", "ask"),
            ("codex", "full_access", "ask"),
        ] {
            let stored = old.project_conversation(id).await.unwrap().unwrap();
            assert_eq!(
                (stored.access_mode.as_str(), stored.claude_approval.as_str()),
                (access, approval),
                "{id}"
            );
        }
    }

    // Contract: a stale native-project repair compares the value it checked;
    // neither a duplicate insert nor a late repair can overwrite the winner.
    #[tokio::test]
    async fn provider_project_repairs_preserve_the_concurrent_winner() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        project(&store, "project", &["/work/app"]).await;
        assert_eq!(
            store
                .set_project_provider_ref("project", AgentFamily::Codex, "home", "old")
                .await
                .unwrap(),
            "old"
        );
        assert_eq!(
            store
                .set_project_provider_ref("project", AgentFamily::Codex, "home", "duplicate")
                .await
                .unwrap(),
            "old"
        );
        assert_eq!(
            store
                .replace_project_provider_ref(
                    "project",
                    AgentFamily::Codex,
                    "home",
                    "old",
                    "repaired"
                )
                .await
                .unwrap(),
            "repaired"
        );
        assert_eq!(
            store
                .replace_project_provider_ref("project", AgentFamily::Codex, "home", "old", "late")
                .await
                .unwrap(),
            "repaired"
        );
        assert_eq!(
            store
                .project_provider_ref("project", AgentFamily::Codex, "home")
                .await
                .unwrap()
                .as_deref(),
            Some("repaired")
        );
    }

    // Contract: creation retries converge on one project; a different payload
    // under the same request cannot silently replace the folders.
    #[tokio::test]
    async fn project_creation_is_idempotent_and_validates_folders() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        let created = project(&store, "p1", &["/work/app", "/work/docs"]).await;
        assert_eq!(created.primary_root().path, "/work/app");
        assert!(matches!(
            store.create_project("p2", "request-p1", "hash", "App", &roots(&["/work/app"]), 0, "now").await.unwrap(),
            ProjectCreate::Existing(p) if p.id == "p1"
        ));
        assert_eq!(
            store
                .create_project(
                    "p2",
                    "request-p1",
                    "other",
                    "App",
                    &roots(&["/x"]),
                    0,
                    "now"
                )
                .await
                .unwrap(),
            ProjectCreate::Conflict
        );
        for bad in [roots(&[]), roots(&["relative"]), roots(&["/a", "/a"])] {
            assert!(store
                .create_project("p3", "request-p3", "hash", "App", &bad, 0, "now")
                .await
                .is_err());
        }
        assert!(store
            .create_project("p3", "request-p3", "hash", "  ", &roots(&["/a"]), 0, "now")
            .await
            .is_err());
    }

    // Contract: a primary edit changes future threads only; an attached thread
    // keeps its recorded cwd, and stale editors cannot overwrite a newer set.
    #[tokio::test]
    async fn root_edits_are_revisioned_and_do_not_move_conversations() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        let created = project(&store, "p1", &["/work/app", "/work/docs"]).await;
        store
            .create_project_conversation(conversation("c1", "p1", Some("t1"), None))
            .await
            .unwrap();
        let updated = store
            .update_project_roots("p1", 1, &roots(&["/work/docs", "/work/app"]), 0, "later")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(updated.roots_revision, 2);
        assert_eq!(updated.primary_root().path, "/work/docs");
        assert_eq!(
            updated
                .roots
                .iter()
                .find(|r| r.path == "/work/app")
                .unwrap()
                .id,
            created
                .roots
                .iter()
                .find(|r| r.path == "/work/app")
                .unwrap()
                .id
        );
        assert!(store
            .update_project_roots("p1", 1, &roots(&["/work/app"]), 0, "later")
            .await
            .is_err());
        assert_eq!(
            store.project_conversation("c1").await.unwrap().unwrap().cwd,
            "/work/app"
        );
        assert!(sqlx::query(
            "UPDATE project_conversations SET cwd='/work/docs' WHERE conversation_id='c1'"
        )
        .execute(&store.pool)
        .await
        .is_err());
        assert!(updated.root_for("/work/application").is_none());
    }

    // Contract: a fork records its source and cut once; the source stays unmarked.
    #[tokio::test]
    async fn a_fork_records_its_source_once() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        project(&store, "p1", &["/work/app"]).await;
        for (id, native) in [("source", "thread"), ("fork", "thread-fork")] {
            store
                .create_project_conversation(conversation(id, "p1", Some(native), None))
                .await
                .unwrap();
        }
        assert_eq!(store.project_fork_source("fork").await.unwrap(), None);
        store
            .record_project_fork("fork", "source", Some("turn-2"))
            .await
            .unwrap();
        assert_eq!(
            store.project_fork_source("fork").await.unwrap(),
            Some(("source".into(), Some("turn-2".into())))
        );
        assert_eq!(store.project_fork_source("source").await.unwrap(), None);
        assert!(store
            .record_project_fork("fork", "other", None)
            .await
            .is_err());
    }

    // Contract: rediscovering a native session attaches the same conversation;
    // overlapping folder groups or retries never create a duplicate.
    #[tokio::test]
    async fn native_identity_attaches_once_and_is_immutable() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        project(&store, "p1", &["/work/app"]).await;
        project(&store, "p2", &["/work/app", "/work/other"]).await;
        let ProjectConversationCreate::Created(first) = store
            .create_project_conversation(conversation("c1", "p1", Some("thread"), None))
            .await
            .unwrap()
        else {
            panic!()
        };
        let ProjectConversationCreate::Existing(again) = store
            .create_project_conversation(conversation("c2", "p2", Some("thread"), None))
            .await
            .unwrap()
        else {
            panic!()
        };
        assert_eq!(again.conversation_id, first.conversation_id);
        assert!(store.conversation("c2").await.unwrap().is_none());
        // A creation retry returns the same draft conversation.
        store
            .create_project_conversation(conversation("c3", "p1", None, Some("req")))
            .await
            .unwrap();
        let ProjectConversationCreate::Existing(retry) = store
            .create_project_conversation(conversation("c4", "p1", None, Some("req")))
            .await
            .unwrap()
        else {
            panic!()
        };
        assert_eq!(retry.conversation_id, "c3");
        store
            .set_project_native_session("c3", "native-3", "now")
            .await
            .unwrap();
        assert!(store
            .set_project_native_session("c3", "native-x", "now")
            .await
            .is_err());
        assert!(store
            .update_project_conversation(
                "c1",
                ProjectConversationPatch {
                    model: Some("claude:haiku"),
                    ..Default::default()
                },
                "now"
            )
            .await
            .is_err());
    }

    // Contract: a creation request is frozen, including its modes. A retry
    // that changes access, approval or plan mode must not adopt the first
    // conversation, and Claude-only approval cannot be stored on a Codex thread.
    #[tokio::test]
    async fn creation_retries_match_modes_and_approval_is_claude_only() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        project(&store, "p1", &["/work/app"]).await;
        let claude = |id, request| ProjectConversationInsert {
            family: AgentFamily::Claude,
            provider_store: "claude:home",
            claude_approval: "accept_edits",
            plan_mode: true,
            ..conversation(id, "p1", None, request)
        };
        let ProjectConversationCreate::Created(created) = store
            .create_project_conversation(claude("m1", Some("modes")))
            .await
            .unwrap()
        else {
            panic!()
        };
        assert_eq!(
            (created.claude_approval.as_str(), created.plan_mode),
            ("accept_edits", true)
        );
        assert!(matches!(
            store.create_project_conversation(claude("m2", Some("modes"))).await.unwrap(),
            ProjectConversationCreate::Existing(c) if c.conversation_id == "m1"
        ));
        for changed in [
            ProjectConversationInsert {
                plan_mode: false,
                ..claude("m3", Some("modes"))
            },
            ProjectConversationInsert {
                claude_approval: "auto",
                ..claude("m3", Some("modes"))
            },
            ProjectConversationInsert {
                access_mode: "full_access",
                ..claude("m3", Some("modes"))
            },
            ProjectConversationInsert {
                model: Some("claude:haiku"),
                ..claude("m3", Some("modes"))
            },
            ProjectConversationInsert {
                effort: Some("high"),
                service_tier: None,
                ..claude("m3", Some("modes"))
            },
            ProjectConversationInsert {
                cwd: "/work/other",
                ..claude("m3", Some("modes"))
            },
        ] {
            assert!(store.create_project_conversation(changed).await.is_err());
        }
        assert!(store.project_conversation("m3").await.unwrap().is_none());
        for invalid in [
            ProjectConversationInsert {
                claude_approval: "yolo",
                ..claude("m4", None)
            },
            // Codex threads keep the default; the field has no meaning there.
            ProjectConversationInsert {
                family: AgentFamily::Codex,
                ..claude("m4", None)
            },
        ] {
            assert!(store.create_project_conversation(invalid).await.is_err());
        }
        store
            .create_project_conversation(conversation("codex", "p1", None, None))
            .await
            .unwrap();
        let codex_plan = store
            .update_project_conversation(
                "codex",
                ProjectConversationPatch {
                    plan_mode: Some(true),
                    ..Default::default()
                },
                "now",
            )
            .await
            .unwrap()
            .unwrap();
        assert!(codex_plan.plan_mode);
        for bad in ["auto", "yolo"] {
            assert!(store
                .update_project_conversation(
                    "codex",
                    ProjectConversationPatch {
                        claude_approval: Some(bad),
                        ..Default::default()
                    },
                    "now",
                )
                .await
                .is_err());
        }
        // Partial updates leave the other mode alone.
        let updated = store
            .update_project_conversation(
                "m1",
                ProjectConversationPatch {
                    claude_approval: Some("auto"),
                    ..Default::default()
                },
                "later",
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            (updated.claude_approval.as_str(), updated.plan_mode),
            ("auto", true)
        );
        store
            .update_project_conversation(
                "m1",
                ProjectConversationPatch {
                    model: Some("claude:haiku"),
                    effort: Some(Some("high")),
                    access_mode: Some("full_access"),
                    plan_mode: Some(false),
                    ..Default::default()
                },
                "later",
            )
            .await
            .unwrap();
        // The original request remains valid after later settings changes.
        assert!(matches!(
            store.create_project_conversation(claude("retry", Some("modes"))).await.unwrap(),
            ProjectConversationCreate::Existing(c) if c.conversation_id == "m1" && c.claude_approval == "auto"
        ));
        assert!(store
            .update_project_conversation(
                "m1",
                ProjectConversationPatch {
                    claude_approval: Some("yolo"),
                    ..Default::default()
                },
                "later",
            )
            .await
            .is_err());
        // Rows written before modes existed default to the previous behavior,
        // and the database rejects values the API would.
        sqlx::query("INSERT INTO conversations(id,codex_thread_id,session_id,created_at) VALUES('old',NULL,NULL,'now')")
            .execute(&store.pool).await.unwrap();
        sqlx::query("INSERT INTO project_conversations(conversation_id,project_id,agent_family,provider_store,cwd,roots_revision,title,created_at,updated_at,last_activity_at) VALUES('old','p1','codex','codex:home','/work/app',1,'Old','now','now','now')")
            .execute(&store.pool).await.unwrap();
        let old = store.project_conversation("old").await.unwrap().unwrap();
        assert_eq!(
            (old.claude_approval.as_str(), old.plan_mode),
            ("ask", false)
        );
        assert!(sqlx::query(
            "UPDATE project_conversations SET claude_approval='yolo' WHERE conversation_id='old'"
        )
        .execute(&store.pool)
        .await
        .is_err());
        assert!(sqlx::query(
            "UPDATE project_conversations SET plan_mode=2 WHERE conversation_id='old'"
        )
        .execute(&store.pool)
        .await
        .is_err());
    }

    // New creation rows retain the exact client folder/request identity for
    // receipt replay. Legacy rows keep their original array payload.
    #[tokio::test]
    async fn creation_request_digest_is_frozen_and_recoverable() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        project(&store, "p1", &["/work/app"]).await;
        let insert = || conversation("digest-1", "p1", None, Some("digest-request"));
        assert!(matches!(
            store
                .create_project_conversation_with_request_digest(
                    insert(),
                    "folder-id-and-settings-a"
                )
                .await
                .unwrap(),
            ProjectConversationCreate::Created(_)
        ));
        let (stored_conversation, payload) = store
            .project_creation_by_request("digest-request")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(stored_conversation.conversation_id, "digest-1");
        assert_eq!(payload["version"], 2);
        assert_eq!(payload["requestDigest"], "folder-id-and-settings-a");
        assert!(matches!(
            store.create_project_conversation_with_request_digest(insert(), "folder-id-and-settings-a").await.unwrap(),
            ProjectConversationCreate::Existing(c) if c.conversation_id == "digest-1"
        ));
        assert!(store
            .create_project_conversation_with_request_digest(insert(), "different-folder-id")
            .await
            .is_err());
        assert!(store
            .project_creation_by_request("absent")
            .await
            .unwrap()
            .is_none());

        store
            .create_project_conversation(conversation("legacy", "p1", None, Some("legacy-request")))
            .await
            .unwrap();
        let (_, legacy) = store
            .project_creation_by_request("legacy-request")
            .await
            .unwrap()
            .unwrap();
        assert!(legacy.is_array());
    }

    // Contract: omitted effort preserves it and explicit null clears it.
    // Regression: a model without effort inherits the previous model's value.
    // Owner boundary: the persistent project-conversation PATCH operation.
    #[tokio::test]
    async fn effort_patch_distinguishes_omission_value_and_clear() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        project(&store, "p1", &["/work/app"]).await;
        store
            .create_project_conversation(ProjectConversationInsert {
                effort: Some("high"),
                service_tier: None,
                ..conversation("c1", "p1", None, None)
            })
            .await
            .unwrap();
        for (patch, expected) in [
            (
                ProjectConversationPatch {
                    title: Some("Renamed"),
                    ..Default::default()
                },
                Some("high"),
            ),
            (
                ProjectConversationPatch {
                    effort: Some(Some("low")),
                    ..Default::default()
                },
                Some("low"),
            ),
            (
                ProjectConversationPatch {
                    effort: Some(None),
                    ..Default::default()
                },
                None,
            ),
        ] {
            let result = store
                .update_project_conversation("c1", patch, "later")
                .await
                .unwrap()
                .unwrap();
            assert_eq!(result.effort.as_deref(), expected);
        }
    }

    // Contract: upgrading preserves conversations and records legacy settings
    // once, so later PATCHes cannot change the creation-retry comparison.
    // Owner boundary: the actual additive migration on the pre-upgrade table.
    #[tokio::test]
    async fn creation_payload_migration_preserves_legacy_settings() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        project(&store, "p1", &["/work/app"]).await;
        let original = ProjectConversationInsert {
            family: AgentFamily::Claude,
            model: Some("claude:haiku"),
            effort: Some("high"),
            service_tier: None,
            claude_approval: "auto",
            plan_mode: true,
            ..conversation("legacy", "p1", None, Some("legacy-request"))
        };
        store
            .create_project_conversation(original.clone())
            .await
            .unwrap();
        // Removing only the new column restores the exact pre-0080 shape.
        sqlx::query("ALTER TABLE project_conversations DROP COLUMN creation_payload")
            .execute(&store.pool)
            .await
            .unwrap();
        sqlx::raw_sql(include_str!(
            "../migrations/0080_project_creation_payload.sql"
        ))
        .execute(&store.pool)
        .await
        .unwrap();
        let legacy = store.project_conversation("legacy").await.unwrap().unwrap();
        assert_eq!(legacy.effort.as_deref(), Some("high"));
        assert_eq!(
            (legacy.claude_approval.as_str(), legacy.plan_mode),
            ("auto", true)
        );
        store
            .update_project_conversation(
                "legacy",
                ProjectConversationPatch {
                    effort: Some(None),
                    plan_mode: Some(false),
                    ..Default::default()
                },
                "later",
            )
            .await
            .unwrap();
        assert!(matches!(
            store.create_project_conversation(original).await.unwrap(),
            ProjectConversationCreate::Existing(c) if c.conversation_id == "legacy" && c.effort.is_none() && !c.plan_mode
        ));
    }

    // A creation retry compares the selected tier, while accepted messages
    // keep their own settings after the thread is edited.
    #[tokio::test]
    async fn project_speed_retry_and_accepted_message_are_stable() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        store
            .upsert_owner_device("device", "Owner", "{}", "now")
            .await
            .unwrap();
        project(&store, "p1", &["/work/app"]).await;
        let selected = ProjectConversationInsert {
            model: Some("gpt-x"),
            effort: Some("high"),
            service_tier: Some("fast"),
            ..conversation("c1", "p1", None, Some("request"))
        };
        store
            .create_project_conversation(selected.clone())
            .await
            .unwrap();
        let MessageInsert::Inserted(message) = store
            .insert_dispatch_message("device", "client", "work", "hash", "c1", &[], "now", true)
            .await
            .unwrap()
        else {
            panic!("new message")
        };
        store
            .update_project_conversation(
                "c1",
                ProjectConversationPatch {
                    service_tier: Some(Some("default")),
                    ..Default::default()
                },
                "later",
            )
            .await
            .unwrap();
        assert_eq!(
            store
                .project_conversation("c1")
                .await
                .unwrap()
                .unwrap()
                .service_tier
                .as_deref(),
            Some("default")
        );
        assert_eq!(
            store
                .project_message_execution_settings(&message.id)
                .await
                .unwrap(),
            Some((
                Some("gpt-x".into()),
                Some("high".into()),
                Some("fast".into())
            ))
        );
        assert!(matches!(
            store
                .create_project_conversation(selected.clone())
                .await
                .unwrap(),
            ProjectConversationCreate::Existing(_)
        ));
        assert!(store
            .create_project_conversation(ProjectConversationInsert {
                service_tier: Some("default"),
                ..selected
            })
            .await
            .is_err());
        // Two devices can validate against the same old settings. Once the
        // model changes, the stale speed write must lose atomically.
        store
            .update_project_conversation_if_settings_match(
                "c1",
                ProjectConversationPatch {
                    model: Some("other-model"),
                    service_tier: Some(None),
                    ..Default::default()
                },
                Some("gpt-x"),
                Some("high"),
                Some("default"),
                "next",
            )
            .await
            .unwrap();
        let stale = store
            .update_project_conversation_if_settings_match(
                "c1",
                ProjectConversationPatch {
                    service_tier: Some(Some("fast")),
                    ..Default::default()
                },
                Some("gpt-x"),
                Some("high"),
                Some("default"),
                "stale",
            )
            .await;
        assert!(matches!(
            stale,
            Err(sqlx::Error::Protocol(message)) if message == "project_settings_changed"
        ));
        let current = store.project_conversation("c1").await.unwrap().unwrap();
        assert_eq!(current.model.as_deref(), Some("other-model"));
        assert_eq!(current.service_tier, None);
    }

    // Contract: only attached, pinned conversations of included projects feed
    // the cross-project Pinned list, newest activity first and bounded.
    #[tokio::test]
    async fn pinned_conversations_follow_project_visibility_and_activity() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        project(&store, "p1", &["/work/a"]).await;
        project(&store, "p2", &["/work/b"]).await;
        for (id, project, activity) in [
            ("a", "p1", "2026-01-01"),
            ("b", "p2", "2026-01-03"),
            ("c", "p1", "2026-01-02"),
            ("d", "p2", "2026-01-04"),
        ] {
            store
                .create_project_conversation(conversation(id, project, None, None))
                .await
                .unwrap();
            store
                .update_project_conversation(
                    id,
                    ProjectConversationPatch {
                        pinned: Some(id != "c"),
                        ..Default::default()
                    },
                    "now",
                )
                .await
                .unwrap();
            sqlx::query(
                "UPDATE project_conversations SET last_activity_at=? WHERE conversation_id=?",
            )
            .bind(activity)
            .bind(id)
            .execute(&store.pool)
            .await
            .unwrap();
        }
        let ids = |rows: Vec<StoredProjectConversation>| {
            rows.into_iter()
                .map(|c| c.conversation_id)
                .collect::<Vec<_>>()
        };
        assert_eq!(
            ids(store.pinned_project_conversations(50).await.unwrap()),
            ["d", "b", "a"]
        );
        assert_eq!(
            ids(store.pinned_project_conversations(2).await.unwrap()),
            ["d", "b"]
        );
        store
            .update_project_metadata("p2", None, Some(false), None, "now")
            .await
            .unwrap();
        assert_eq!(
            ids(store.pinned_project_conversations(50).await.unwrap()),
            ["a"]
        );
    }

    // Contract: Bot bindings stay in the Bot scope; a project cannot adopt a
    // Bot's runtime thread, and a project binding cannot change scope.
    #[tokio::test]
    async fn project_bindings_are_scoped_and_cannot_adopt_bot_sessions() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        project(&store, "p1", &["/work/app"]).await;
        store
            .bind_runtime(
                "bot-conversation",
                AgentFamily::Codex,
                "bot-thread",
                None,
                "now",
            )
            .await
            .unwrap();
        store
            .create_project_conversation(conversation("c1", "p1", Some("bot-thread"), None))
            .await
            .unwrap();
        assert!(store
            .bind_project_runtime(
                "c1",
                AgentFamily::Codex,
                "codex:home",
                "bot-thread",
                None,
                "now"
            )
            .await
            .is_err());
        store
            .create_project_conversation(conversation("c2", "p1", Some("own-thread"), None))
            .await
            .unwrap();
        assert!(store
            .bind_project_runtime(
                "c2",
                AgentFamily::Claude,
                "claude:home",
                "claude-x",
                None,
                "now"
            )
            .await
            .is_err());
        store
            .bind_project_runtime(
                "c2",
                AgentFamily::Codex,
                "codex:home",
                "own-thread",
                None,
                "now",
            )
            .await
            .unwrap();
        assert_eq!(
            store.runtime_route_for_thread("own-thread").await.unwrap(),
            Some((AgentFamily::Codex, EXECUTION_SCOPE_PROJECTS.to_owned()))
        );
        assert_eq!(
            store.runtime_route_for_thread("bot-thread").await.unwrap(),
            Some((AgentFamily::Codex, EXECUTION_SCOPE_BOTS.to_owned()))
        );
        assert!(sqlx::query(
            "UPDATE runtime_bindings SET execution_scope='bots' WHERE conversation_id='c2'"
        )
        .execute(&store.pool)
        .await
        .is_err());
        // Project conversations are absent from the Bot inbox, including the
        // conversation list that clients render as Bots and Group Chats.
        assert!(store.conversation("c2").await.unwrap().is_none());
        store
            .upsert_bot(
                "bot-one",
                "Bot",
                "Helper",
                "Help",
                "/tmp/bot-one",
                "profile",
                None,
                None,
                "now",
            )
            .await
            .unwrap();
        let listed: Vec<String> = store
            .list_conversation_summaries()
            .await
            .unwrap()
            .into_iter()
            .map(|c| c.conversation_id)
            .collect();
        assert!(listed.contains(&"bot-one".to_owned()));
        assert!(!listed.iter().any(|id| id == "c1" || id == "c2"));
        assert_eq!(
            store
                .conversation_execution_directory("c2")
                .await
                .unwrap()
                .as_deref(),
            Some("/work/app")
        );
    }

    // Contract: the Mac computer view opens for Bot chats, project threads of
    // included projects, and the owner's host-level view; nothing else.
    #[tokio::test]
    async fn computer_view_allows_project_threads_and_host_view_only() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        project(&store, "p1", &["/work/a"]).await;
        store
            .create_project_conversation(conversation("thread", "p1", None, None))
            .await
            .unwrap();
        store
            .upsert_bot(
                "bot-one",
                "Bot",
                "Helper",
                "Help",
                "/tmp/bot-one",
                "profile",
                None,
                None,
                "now",
            )
            .await
            .unwrap();
        store
            .ensure_conversation_metadata("bot-chat", "bot-one", "Bot", "now")
            .await
            .unwrap();
        for allowed in ["thread", "bot-chat", crate::HOST_VIEW_CONVERSATION_ID] {
            assert!(
                store.computer_conversation_allowed(allowed).await.unwrap(),
                "{allowed}"
            );
        }
        for denied in ["", "unknown", "WONDER-HOST-VIEW", "wonder-host-view "] {
            assert!(
                !store.computer_conversation_allowed(denied).await.unwrap(),
                "{denied}"
            );
        }
        store
            .update_project_metadata("p1", None, Some(false), None, "now")
            .await
            .unwrap();
        assert!(!store.computer_conversation_allowed("thread").await.unwrap());
    }

    #[tokio::test]
    async fn visibility_and_pins_are_independent_metadata() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        project(&store, "p1", &["/work/a"]).await;
        project(&store, "p2", &["/work/b"]).await;
        store
            .update_project_metadata("p2", None, None, Some(true), "now")
            .await
            .unwrap();
        let hidden = store
            .update_project_metadata("p2", None, Some(false), None, "now")
            .await
            .unwrap()
            .unwrap();
        assert!(!hidden.is_included);
        assert_eq!(hidden.pin_order, Some(1));
        assert_eq!(store.list_projects().await.unwrap()[0].id, "p2");
        let unpinned = store
            .update_project_metadata("p2", Some("B"), Some(true), Some(false), "now")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            (
                unpinned.name.as_str(),
                unpinned.pin_order,
                unpinned.is_included
            ),
            ("B", None, true)
        );
    }
}
