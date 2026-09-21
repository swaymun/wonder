//! Durable ASR jobs. Terminal state changes use compare-and-set so cancellation wins once committed.
use super::*;

#[derive(Clone, Debug)]
pub struct AsrJob {
    pub transcription: StoredTranscription,
    pub client_request_id: Option<String>,
    pub request_sha256: Option<String>,
    pub model_id: String,
    pub language: String,
    pub audio_mime: Option<String>,
}

pub struct NewAsrJob<'a> {
    pub id: &'a str,
    pub device_id: &'a str,
    pub request_id: &'a str,
    pub request_sha256: &'a str,
    pub model_id: &'a str,
    pub language: &'a str,
    pub duration_ms: u64,
    pub audio_mime: &'a str,
    pub audio: &'a [u8],
    pub now_ms: u64,
}

fn asr_job(row: sqlx::sqlite::SqliteRow) -> AsrJob {
    AsrJob {
        transcription: StoredTranscription {
            id: row.get("id"),
            state: row.get("state"),
            source_device_id: row.get("source_device_id"),
            duration_ms: row.get::<i64, _>("duration_ms") as u64,
            transcript_text: row.get("transcript_text"),
            word_timestamps_json: row.get("word_timestamps_json"),
            confidence: row.get("confidence"),
            retry_expires_at_ms: row
                .get::<Option<i64>, _>("retry_expires_at_ms")
                .map(|n| n as u64),
            error_category: row.get("error_category"),
        },
        client_request_id: row.get("client_request_id"),
        request_sha256: row.get("request_sha256"),
        model_id: row.get("model_id"),
        language: row.get("language"),
        audio_mime: row.get("audio_mime"),
    }
}

impl Store {
    pub async fn asr_request_cancelled(
        &self,
        device: &str,
        request: &str,
    ) -> Result<bool, sqlx::Error> {
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM asr_cancelled_requests WHERE device_id=? AND client_request_id=?)")
            .bind(device).bind(request).fetch_one(&self.pool).await
    }

    /// One transaction fences future uploads and cancels any already accepted job.
    pub async fn cancel_asr_request(
        &self,
        device: &str,
        request: &str,
        now: u64,
    ) -> Result<Option<String>, sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("INSERT OR IGNORE INTO asr_cancelled_requests(device_id,client_request_id,created_at) VALUES (?,?,?)")
            .bind(device).bind(request).bind(now.to_string()).execute(&mut *tx).await?;
        let id: Option<String> = sqlx::query_scalar(
            "SELECT id FROM transcriptions WHERE source_device_id=? AND client_request_id=?",
        )
        .bind(device)
        .bind(request)
        .fetch_optional(&mut *tx)
        .await?;
        sqlx::query("UPDATE transcriptions SET state='cancelled',audio_bytes=NULL,transcript_text=NULL,word_timestamps_json=NULL,confidence=NULL,retry_expires_at_ms=NULL,error_category=NULL,updated_at=? WHERE source_device_id=? AND client_request_id=? AND state IN ('queued','processing','failed','completed')")
            .bind(now.to_string()).bind(device).bind(request).execute(&mut *tx).await?;
        tx.commit().await?;
        Ok(id)
    }

    pub async fn retained_asr_audio_bytes(&self) -> Result<i64, sqlx::Error> {
        sqlx::query_scalar("SELECT COALESCE(SUM(length(audio_bytes)),0) FROM transcriptions")
            .fetch_one(&self.pool)
            .await
    }

    pub async fn create_asr_job(&self, job: NewAsrJob<'_>) -> Result<bool, sqlx::Error> {
        Ok(sqlx::query("INSERT INTO transcriptions(id,state,source_device_id,client_request_id,request_sha256,model_id,language,duration_ms,audio_mime,audio_bytes,created_at,updated_at) SELECT ?,'queued',?,?,?,?,?,?,?,?,?,? WHERE NOT EXISTS(SELECT 1 FROM asr_cancelled_requests WHERE device_id=? AND client_request_id=?) ON CONFLICT(source_device_id,client_request_id) DO NOTHING")
            .bind(job.id).bind(job.device_id).bind(job.request_id).bind(job.request_sha256).bind(job.model_id).bind(job.language).bind(job.duration_ms as i64).bind(job.audio_mime).bind(job.audio).bind(job.now_ms.to_string()).bind(job.now_ms.to_string()).bind(job.device_id).bind(job.request_id).execute(&self.pool).await?.rows_affected()==1)
    }
    pub async fn asr_job_by_request(
        &self,
        device: &str,
        request: &str,
    ) -> Result<Option<AsrJob>, sqlx::Error> {
        Ok(sqlx::query(
            "SELECT * FROM transcriptions WHERE source_device_id=? AND client_request_id=?",
        )
        .bind(device)
        .bind(request)
        .fetch_optional(&self.pool)
        .await?
        .map(asr_job))
    }
    pub async fn asr_job_for_device(
        &self,
        id: &str,
        device: &str,
    ) -> Result<Option<AsrJob>, sqlx::Error> {
        Ok(
            sqlx::query("SELECT * FROM transcriptions WHERE id=? AND source_device_id=?")
                .bind(id)
                .bind(device)
                .fetch_optional(&self.pool)
                .await?
                .map(asr_job),
        )
    }
    pub async fn asr_job_audio(&self, id: &str) -> Result<Option<Vec<u8>>, sqlx::Error> {
        sqlx::query_scalar("SELECT audio_bytes FROM transcriptions WHERE id=? AND state IN ('queued','processing')").bind(id).fetch_optional(&self.pool).await.map(Option::flatten)
    }
    pub async fn claim_asr_job(&self, id: &str, now: u64) -> Result<bool, sqlx::Error> {
        Ok(sqlx::query("UPDATE transcriptions SET state='processing',updated_at=? WHERE id=? AND state='queued'").bind(now.to_string()).bind(id).execute(&self.pool).await?.rows_affected()==1)
    }
    #[allow(clippy::too_many_arguments)]
    pub async fn finish_asr_job(
        &self,
        id: &str,
        text: Option<&str>,
        words: Option<&str>,
        confidence: Option<f32>,
        error: Option<&str>,
        duration: u64,
        now: u64,
    ) -> Result<bool, sqlx::Error> {
        Ok(sqlx::query("UPDATE transcriptions SET state=?, transcript_text=?,word_timestamps_json=?,confidence=?,error_category=?,duration_ms=?,retry_expires_at_ms=?,audio_bytes=CASE WHEN ? IS NULL THEN NULL ELSE audio_bytes END,updated_at=? WHERE id=? AND state='processing'")
            .bind(if error.is_some(){"failed"}else{"completed"}).bind(text).bind(words).bind(confidence).bind(error).bind(duration as i64).bind(error.map(|_|now.saturating_add(120_000) as i64)).bind(error).bind(now.to_string()).bind(id).execute(&self.pool).await?.rows_affected()==1)
    }
    pub async fn cancel_asr_job(
        &self,
        id: &str,
        device: &str,
        now: u64,
    ) -> Result<bool, sqlx::Error> {
        Ok(sqlx::query("UPDATE transcriptions SET state='cancelled',audio_bytes=NULL,transcript_text=NULL,word_timestamps_json=NULL,confidence=NULL,retry_expires_at_ms=NULL,error_category=NULL,updated_at=? WHERE id=? AND source_device_id=? AND state IN ('queued','processing','failed')").bind(now.to_string()).bind(id).bind(device).execute(&self.pool).await?.rows_affected()==1)
    }
    pub async fn retry_asr_job(
        &self,
        id: &str,
        device: &str,
        now: u64,
    ) -> Result<bool, sqlx::Error> {
        Ok(sqlx::query("UPDATE transcriptions SET state='queued',error_category=NULL,retry_expires_at_ms=NULL,updated_at=? WHERE id=? AND source_device_id=? AND state='failed' AND retry_expires_at_ms>? AND audio_bytes IS NOT NULL").bind(now.to_string()).bind(id).bind(device).bind(now as i64).execute(&self.pool).await?.rows_affected()==1)
    }
    /// Never automatically replay an interrupted runtime submission.
    pub async fn recover_asr_jobs(&self, now: u64) -> Result<u64, sqlx::Error> {
        let count=sqlx::query("UPDATE transcriptions SET state='failed',error_category='interrupted',retry_expires_at_ms=CASE WHEN audio_bytes IS NULL THEN NULL ELSE ? END,updated_at=? WHERE state IN ('queued','processing')").bind(now.saturating_add(120_000) as i64).bind(now.to_string()).execute(&self.pool).await?.rows_affected();
        self.expire_asr_audio(now).await?;
        Ok(count)
    }
    pub async fn expire_asr_audio(&self, now: u64) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE transcriptions SET audio_bytes=NULL,retry_expires_at_ms=NULL WHERE (audio_bytes IS NOT NULL OR retry_expires_at_ms IS NOT NULL) AND (state IN ('completed','cancelled') OR (state='failed' AND (retry_expires_at_ms IS NULL OR retry_expires_at_ms<=?)))").bind(now as i64).execute(&self.pool).await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn asr_request_cancellation_survives_reopen_and_fences_late_upload() {
        let dir = tempfile::tempdir().unwrap();
        let url = format!(
            "sqlite://{}?mode=rwc",
            dir.path().join("cancel.sqlite3").display()
        );
        let store = Store::connect(&url).await.unwrap();
        assert_eq!(
            store
                .cancel_asr_request("phone-a", "request", 1)
                .await
                .unwrap(),
            None
        );
        drop(store);
        let store = Store::connect(&url).await.unwrap();
        assert!(store
            .asr_request_cancelled("phone-a", "request")
            .await
            .unwrap());
        assert!(!store
            .asr_request_cancelled("phone-b", "request")
            .await
            .unwrap());
        let job = |id, device| NewAsrJob {
            id,
            device_id: device,
            request_id: "request",
            request_sha256: "hash",
            model_id: "model",
            language: "auto",
            duration_ms: 1000,
            audio_mime: "audio/wav",
            audio: b"audio",
            now_ms: 2,
        };
        assert!(!store.create_asr_job(job("late", "phone-a")).await.unwrap());
        assert!(store.create_asr_job(job("other", "phone-b")).await.unwrap());
        assert!(store.claim_asr_job("other", 3).await.unwrap());
        assert_eq!(
            store
                .cancel_asr_request("phone-b", "request", 4)
                .await
                .unwrap()
                .as_deref(),
            Some("other")
        );
        assert!(!store
            .finish_asr_job("other", Some("late result"), None, None, None, 1000, 5)
            .await
            .unwrap());
        assert!(store.asr_job_audio("other").await.unwrap().is_none());
        // Cancel also suppresses a result completed before the phone received it.
        assert!(store
            .create_asr_job(job("completed", "phone-c"))
            .await
            .unwrap());
        assert!(store.claim_asr_job("completed", 6).await.unwrap());
        assert!(store
            .finish_asr_job(
                "completed",
                Some("unconsumed result"),
                Some("[]"),
                Some(0.9),
                None,
                1000,
                7
            )
            .await
            .unwrap());
        store
            .cancel_asr_request("phone-c", "request", 8)
            .await
            .unwrap();
        let cancelled = store
            .asr_job_for_device("completed", "phone-c")
            .await
            .unwrap()
            .unwrap()
            .transcription;
        assert_eq!(cancelled.state, "cancelled");
        assert!(cancelled.transcript_text.is_none());
        assert!(cancelled.word_timestamps_json.is_none());
        assert!(cancelled.confidence.is_none());
    }

    #[tokio::test]
    async fn asr_identity_cancel_restart_and_expiry() {
        let store = Store::connect("sqlite::memory:").await.unwrap();
        let create = |id, device| NewAsrJob {
            id,
            device_id: device,
            request_id: "request",
            request_sha256: "hash",
            model_id: "model",
            language: "auto",
            duration_ms: 300000,
            audio_mime: "audio/wav",
            audio: b"audio",
            now_ms: 1,
        };
        assert!(store.create_asr_job(create("one", "a")).await.unwrap());
        assert!(!store
            .create_asr_job(create("duplicate", "a"))
            .await
            .unwrap());
        assert!(store.create_asr_job(create("two", "b")).await.unwrap());
        assert!(store
            .asr_job_for_device("one", "b")
            .await
            .unwrap()
            .is_none());
        assert!(!store.cancel_asr_job("one", "b", 2).await.unwrap());
        assert!(store.claim_asr_job("one", 2).await.unwrap());
        assert!(store.cancel_asr_job("one", "a", 3).await.unwrap());
        assert!(!store
            .finish_asr_job("one", Some("late"), None, None, None, 300000, 4)
            .await
            .unwrap());
        assert!(store.asr_job_audio("one").await.unwrap().is_none());
        assert_eq!(store.recover_asr_jobs(10).await.unwrap(), 1);
        assert_eq!(
            store
                .asr_job_for_device("two", "b")
                .await
                .unwrap()
                .unwrap()
                .transcription
                .error_category
                .as_deref(),
            Some("interrupted")
        );
        assert_eq!(store.recover_asr_jobs(20).await.unwrap(), 0);
        assert!(!store.retry_asr_job("two", "a", 30).await.unwrap());
        assert!(store.retry_asr_job("two", "b", 30).await.unwrap());
        assert!(store.claim_asr_job("two", 31).await.unwrap());
        assert!(store
            .finish_asr_job("two", None, None, None, Some("timeout"), 300000, 40)
            .await
            .unwrap());
        store.expire_asr_audio(120040).await.unwrap();
        assert!(!store.retry_asr_job("two", "b", 120041).await.unwrap());
    }
}
