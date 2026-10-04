//! Durable, host-local authorization for read-only GitHub review. The daemon
//! must verify the current account, repository and canonical folder before
//! granting or using a binding. This record grants no command/merge authority.
use super::*;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProjectGitHubReviewBinding {
    pub project_id: String,
    pub root_id: String,
    pub roots_revision: i64,
    pub account_id: i64,
    pub repository_id: i64,
    /// Canonical GitHub owner/name from the verified repository response.
    pub repository: String,
    pub authorized_at: String,
}

fn valid_repository(value: &str) -> bool {
    let Some((owner, name)) = value.split_once('/') else {
        return false;
    };
    !owner.is_empty()
        && owner.len() <= 100
        && owner
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-')
        && !name.is_empty()
        && name.len() <= 100
        && name != "."
        && name != ".."
        && name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
}

impl Store {
    /// Capture this revision with the owner consent request. It fences delayed
    /// authorization after revocation, exclusion or another grant.
    pub async fn project_github_review_authorization_revision(
        &self,
        project_id: &str,
    ) -> Result<Option<i64>, sqlx::Error> {
        sqlx::query_scalar(
            "SELECT github_review_revision FROM projects WHERE id=? AND is_included=1",
        )
        .bind(project_id)
        .fetch_optional(&self.pool)
        .await
    }

    /// Called only after explicit owner authorization and verified upstream
    /// identity. Stale editors cannot grant access to replacement folders.
    pub async fn authorize_project_github_review(
        &self,
        binding: &ProjectGitHubReviewBinding,
        expected_authorization_revision: i64,
    ) -> Result<(), sqlx::Error> {
        if binding.account_id <= 0
            || binding.repository_id <= 0
            || binding.roots_revision <= 0
            || !valid_repository(&binding.repository)
            || binding.authorized_at.is_empty()
        {
            return Err(sqlx::Error::Protocol(
                "Invalid GitHub review identity".into(),
            ));
        }
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let updated = sqlx::query(
            "UPDATE projects SET github_review_revision=github_review_revision+1
             WHERE id=? AND is_included=1 AND roots_revision=? AND github_review_revision=?
             AND EXISTS(SELECT 1 FROM project_roots r WHERE r.project_id=projects.id AND r.id=?)",
        )
        .bind(&binding.project_id)
        .bind(binding.roots_revision)
        .bind(expected_authorization_revision)
        .bind(&binding.root_id)
        .execute(&mut *tx)
        .await?;
        if updated.rows_affected() == 0 {
            return Err(sqlx::Error::Protocol(
                "Project folders, inclusion or review authorization changed".into(),
            ));
        }
        sqlx::query(
            "INSERT INTO project_github_review_bindings
             (project_id,root_id,roots_revision,account_id,repository_id,repository,authorized_at)
             VALUES(?,?,?,?,?,?,?) ON CONFLICT(project_id,root_id) DO UPDATE SET
             roots_revision=excluded.roots_revision,account_id=excluded.account_id,
             repository_id=excluded.repository_id,repository=excluded.repository,
             authorized_at=excluded.authorized_at",
        )
        .bind(&binding.project_id)
        .bind(&binding.root_id)
        .bind(binding.roots_revision)
        .bind(binding.account_id)
        .bind(binding.repository_id)
        .bind(&binding.repository)
        .bind(&binding.authorized_at)
        .execute(&mut *tx)
        .await?;
        tx.commit().await
    }

    /// Returns only a currently included, revision-matching grant. Callers
    /// separately revalidate disk roots and upstream account/repository identity.
    pub async fn project_github_review_binding(
        &self,
        project_id: &str,
        root_id: &str,
    ) -> Result<Option<ProjectGitHubReviewBinding>, sqlx::Error> {
        let row = sqlx::query(
            "SELECT b.* FROM project_github_review_bindings b
             JOIN projects p ON p.id=b.project_id
             JOIN project_roots r ON r.project_id=b.project_id AND r.id=b.root_id
             WHERE b.project_id=? AND b.root_id=? AND p.is_included=1
             AND p.roots_revision=b.roots_revision",
        )
        .bind(project_id)
        .bind(root_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|row| ProjectGitHubReviewBinding {
            project_id: row.get("project_id"),
            root_id: row.get("root_id"),
            roots_revision: row.get("roots_revision"),
            account_id: row.get("account_id"),
            repository_id: row.get("repository_id"),
            repository: row.get("repository"),
            authorized_at: row.get("authorized_at"),
        }))
    }

    pub async fn revoke_project_github_review(
        &self,
        project_id: &str,
        root_id: &str,
    ) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        // Advance even when this root has no saved grant: an outstanding
        // consent request must not recreate it after the owner disconnects.
        sqlx::query(
            "UPDATE projects SET github_review_revision=github_review_revision+1 WHERE id=?",
        )
        .bind(project_id)
        .execute(&mut *tx)
        .await?;
        sqlx::query("DELETE FROM project_github_review_bindings WHERE project_id=? AND root_id=?")
            .bind(project_id)
            .bind(root_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Contract: local root ownership alone grants no remote access; a grant is
    // host-persistent, exact-folder/account/repo scoped, and revoked permanently
    // by inclusion/folder changes. Credible regression: a stale editor authorizes
    // a replacement root or re-inclusion silently restores old remote authority.
    #[tokio::test]
    async fn review_authorization_is_durable_scoped_and_revocable() {
        let dir = tempfile::tempdir().unwrap();
        let db = format!("sqlite:{}?mode=rwc", dir.path().join("store.db").display());
        let store = Store::connect(&db).await.unwrap();
        let roots = |path: &str| {
            vec![ProjectRootInput {
                path: path.into(),
                canonical_path: path.into(),
            }]
        };
        store
            .create_project("p", "request", "hash", "App", &roots("/app"), 0, "now")
            .await
            .unwrap();
        store
            .create_project(
                "other",
                "other-request",
                "hash",
                "Other",
                &roots("/other"),
                0,
                "now",
            )
            .await
            .unwrap();
        let project = store.project("p").await.unwrap().unwrap();
        let binding = ProjectGitHubReviewBinding {
            project_id: "p".into(),
            root_id: project.primary_root_id,
            roots_revision: 1,
            account_id: 42,
            repository_id: 123,
            repository: "owner/repo".into(),
            authorized_at: "now".into(),
        };
        assert!(store
            .project_github_review_binding("p", &binding.root_id)
            .await
            .unwrap()
            .is_none());
        store
            .authorize_project_github_review(&binding, 0)
            .await
            .unwrap();
        store.pool.close().await;
        let store = Store::connect(&db).await.unwrap();
        assert_eq!(
            store
                .project_github_review_binding("p", &binding.root_id)
                .await
                .unwrap(),
            Some(binding.clone())
        );
        let forged = ProjectGitHubReviewBinding {
            project_id: "other".into(),
            ..binding.clone()
        };
        assert!(store
            .authorize_project_github_review(&forged, 0)
            .await
            .is_err());
        // The schema itself rejects a cross-Project root, independently of
        // the method's current-membership query.
        assert!(sqlx::query("INSERT INTO project_github_review_bindings VALUES ('other',?,1,42,123,'owner/repo','now')")
            .bind(&binding.root_id).execute(&store.pool).await.is_err());
        assert!(store
            .project_github_review_binding("other", &binding.root_id)
            .await
            .unwrap()
            .is_none());
        store
            .update_project_metadata("p", None, Some(false), None, "later")
            .await
            .unwrap();
        assert!(store
            .authorize_project_github_review(&binding, 0)
            .await
            .is_err());
        store
            .update_project_metadata("p", None, Some(true), None, "later")
            .await
            .unwrap();
        assert!(store
            .project_github_review_binding("p", &binding.root_id)
            .await
            .unwrap()
            .is_none());
        // A delayed consent from before exclusion cannot restore access.
        assert!(store
            .authorize_project_github_review(&binding, 1)
            .await
            .is_err());
        assert_eq!(
            store
                .project_github_review_authorization_revision("p")
                .await
                .unwrap(),
            Some(2)
        );
        store
            .authorize_project_github_review(&binding, 2)
            .await
            .unwrap();
        store
            .update_project_roots("p", 1, &roots("/app"), 0, "later")
            .await
            .unwrap();
        assert!(store
            .project_github_review_binding("p", &binding.root_id)
            .await
            .unwrap()
            .is_none());
        assert!(store
            .authorize_project_github_review(&binding, 0)
            .await
            .is_err());
        let refreshed = ProjectGitHubReviewBinding {
            roots_revision: 2,
            ..binding.clone()
        };
        store
            .authorize_project_github_review(&refreshed, 4)
            .await
            .unwrap();
        // Concurrent consent captured at the same revision cannot replace
        // the accepted account/repository choice.
        assert!(store
            .authorize_project_github_review(&refreshed, 4)
            .await
            .is_err());
        store
            .revoke_project_github_review("other", &binding.root_id)
            .await
            .unwrap();
        assert!(store
            .project_github_review_binding("p", &binding.root_id)
            .await
            .unwrap()
            .is_some());
        store
            .revoke_project_github_review("p", &binding.root_id)
            .await
            .unwrap();
        store
            .revoke_project_github_review("p", &binding.root_id)
            .await
            .unwrap();
        assert!(store
            .project_github_review_binding("p", &binding.root_id)
            .await
            .unwrap()
            .is_none());
        assert!(store
            .authorize_project_github_review(&refreshed, 5)
            .await
            .is_err());
        assert_eq!(
            store
                .project_github_review_authorization_revision("p")
                .await
                .unwrap(),
            Some(7)
        );
        for repository in [
            "https://github.com/owner/repo",
            "owner/../repo",
            "owner/repo/extra",
            "owner/..",
            "owner/repo\n",
            "owner\\repo",
        ] {
            let invalid = ProjectGitHubReviewBinding {
                repository: repository.into(),
                ..refreshed.clone()
            };
            assert!(store
                .authorize_project_github_review(&invalid, 7)
                .await
                .is_err());
        }
    }

    #[tokio::test]
    async fn migration_preserves_existing_projects_without_granting_remote_access() {
        let dir = tempfile::tempdir().unwrap();
        let db = format!("sqlite:{}?mode=rwc", dir.path().join("prior.db").display());
        let pool = SqlitePool::connect(&db).await.unwrap();
        let mut prior = sqlx::migrate!();
        prior.migrations = std::borrow::Cow::Owned(
            prior
                .migrations
                .iter()
                .filter(|m| m.version < 87)
                .cloned()
                .collect(),
        );
        prior.run(&pool).await.unwrap();
        let old = Store { pool };
        let roots = [ProjectRootInput {
            path: "/app".into(),
            canonical_path: "/app".into(),
        }];
        old.create_project("p", "request", "hash", "App", &roots, 0, "now")
            .await
            .unwrap();
        let before = old.project("p").await.unwrap().unwrap();
        old.pool.close().await;
        let current = Store::connect(&db).await.unwrap();
        assert_eq!(current.project("p").await.unwrap(), Some(before.clone()));
        assert!(current
            .project_github_review_binding("p", &before.primary_root_id)
            .await
            .unwrap()
            .is_none());
        let binding = ProjectGitHubReviewBinding {
            project_id: "p".into(),
            root_id: before.primary_root_id,
            roots_revision: 1,
            account_id: 42,
            repository_id: 123,
            repository: "owner/repo".into(),
            authorized_at: "now".into(),
        };
        current
            .authorize_project_github_review(&binding, 0)
            .await
            .unwrap();
        current
            .update_project_roots(
                "p",
                1,
                &[ProjectRootInput {
                    path: "/new".into(),
                    canonical_path: "/new".into(),
                }],
                0,
                "later",
            )
            .await
            .unwrap();
        assert!(current
            .project_github_review_binding("p", &binding.root_id)
            .await
            .unwrap()
            .is_none());
        let remaining: i64 =
            sqlx::query_scalar("SELECT count(*) FROM project_github_review_bindings")
                .fetch_one(&current.pool)
                .await
                .unwrap();
        assert_eq!(remaining, 0);
    }
}
