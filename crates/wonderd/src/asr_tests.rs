use super::*;
use axum::body::to_bytes;
use std::os::unix::fs::PermissionsExt;

async fn json_response(response: Response) -> (StatusCode, serde_json::Value) {
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 1024 * 1024).await.unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null),
    )
}
fn executable(path: &FsPath, text: &str) {
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

#[tokio::test]
async fn asr_bounded_io_exact_limit_and_process_tree_cancel() {
    let (_sender, receiver) = watch::channel(false);
    let mut cmd = Command::new("python3");
    cmd.args(["-c","import sys; sys.stdout.buffer.write(b'x'*9600000); sys.stdout.buffer.flush(); sys.stdin.buffer.read()"]);
    assert_eq!(
        bounded_process(
            cmd,
            vec![1; 9600000],
            MAX_PCM_BYTES,
            Duration::from_secs(10),
            receiver.clone()
        )
        .await
        .unwrap()
        .len(),
        MAX_PCM_BYTES
    );
    let mut cmd = Command::new("python3");
    cmd.args(["-c", "import sys; sys.stdout.buffer.write(b'x'*9600001)"]);
    assert_eq!(
        bounded_process(
            cmd,
            vec![],
            MAX_PCM_BYTES,
            Duration::from_secs(10),
            receiver
        )
        .await
        .unwrap_err(),
        AsrErrorCategory::Decoder
    );
    let dir = tempfile::tempdir().unwrap();
    let pid_path = dir.path().join("child-pid");
    let (sender, receiver) = watch::channel(false);
    let mut cmd = Command::new("python3");
    cmd.arg("-c").arg("import subprocess,sys,time; p=subprocess.Popen(['sleep','60']); open(sys.argv[1],'w').write(str(p.pid)); time.sleep(60)").arg(&pid_path);
    let task = tokio::spawn(bounded_process(
        cmd,
        vec![],
        100,
        Duration::from_secs(10),
        receiver,
    ));
    for _ in 0..100 {
        if pid_path.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let pid: i32 = std::fs::read_to_string(&pid_path).unwrap().parse().unwrap();
    sender.send(true).unwrap();
    assert_eq!(
        task.await.unwrap().unwrap_err(),
        AsrErrorCategory::Cancelled
    );
    for _ in 0..100 {
        if unsafe { libc::kill(pid, 0) } != 0 {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("cancelled runtime child {pid} remained alive");
}

#[tokio::test]
#[allow(clippy::field_reassign_with_default)]
async fn asr_jobs_are_async_idempotent_scoped_and_cancel_wins() {
    let (dir, mut state) = crate::ingestion::tests::fixture().await;
    let root = dir.path().join("asr");
    std::fs::create_dir_all(&root).unwrap();
    let worker = root.join("worker");
    executable(
        &worker,
        "#!/usr/bin/env python3\nimport sys,time\nsys.stdin.read()\ntime.sleep(30)\n",
    );
    let decoder = root.join("decoder");
    executable(&decoder,"#!/usr/bin/env python3\nimport sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(bytes(32000))\n");
    let mut service = AsrService::default();
    service.root = root;
    service.worker = Some(worker.clone().into_os_string());
    service.runtime = worker;
    service.decoder = decoder.into_os_string();
    service.initialized.set(()).unwrap();
    *service.model.get_mut() = ModelState {
        verified: true,
        selected: true,
        download_state: "idle",
        ..Default::default()
    };
    state.asr_service = Arc::new(service);
    let mut headers = HeaderMap::new();
    headers.insert("content-type", "audio/wav".parse().unwrap());
    headers.insert("x-wonder-duration-ms", "1000".parse().unwrap());
    headers.insert(
        "x-wonder-request-id",
        "a4f4ee9c-196f-4cb4-8e69-6177e706c06b".parse().unwrap(),
    );
    let body = axum::body::Bytes::from_static(b"RIFF0000WAVEtest");
    let device = || {
        Some(Extension(AuthenticatedDevice {
            device_id: "phone-a".into(),
            session_binding: "test".into(),
        }))
    };
    let (status, first) = json_response(
        create_transcription(
            State(state.clone()),
            device(),
            None,
            headers.clone(),
            body.clone(),
        )
        .await,
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    let id = first["id"].as_str().unwrap().to_owned();
    let (status, duplicate) = json_response(
        create_transcription(State(state.clone()), device(), None, headers.clone(), body).await,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(first["id"], duplicate["id"]);
    assert_eq!(
        create_transcription(
            State(state.clone()),
            device(),
            None,
            headers,
            axum::body::Bytes::from_static(b"RIFF0000WAVEchanged")
        )
        .await
        .status(),
        StatusCode::CONFLICT
    );
    let wrong = Some(Extension(AuthenticatedDevice {
        device_id: "phone-b".into(),
        session_binding: "test".into(),
    }));
    assert_eq!(
        cancel_transcription(State(state.clone()), wrong, None, Path(id.clone()))
            .await
            .status(),
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        cancel_transcription_request(
            State(state.clone()),
            device(),
            None,
            Path("a4f4ee9c-196f-4cb4-8e69-6177e706c06b".into())
        )
        .await
        .status(),
        StatusCode::NO_CONTENT
    );
    let (_, cancelled) = json_response(
        get_transcription(State(state.clone()), device(), None, Path(id.clone())).await,
    )
    .await;
    assert_eq!(cancelled["state"], "cancelled");
    for _ in 0..100 {
        if state.asr_slots.available_permits() == 1 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(state.asr_slots.available_permits(), 1);
    let (_, again) = json_response(
        cancel_transcription(State(state.clone()), device(), None, Path(id.clone())).await,
    )
    .await;
    assert_eq!(again["state"], "cancelled");
    assert!(state.store.asr_job_audio(&id).await.unwrap().is_none());
    assert!(!state.asr_service.root.join("jobs").join(&id).exists());
    assert_eq!(
        select_model(State(state.clone()), None, Path(MODEL_ID.into()))
            .await
            .status(),
        StatusCode::FORBIDDEN
    );
    state.app_server.lock().await.shutdown().await.unwrap();
}

#[tokio::test]
#[ignore = "Requires an explicitly supplied public audio fixture and the installed verified local model"]
#[allow(clippy::field_reassign_with_default)]
async fn asr_real_installed_runtime_http_fixture() {
    use tower::ServiceExt;
    let audio_path = std::env::var("WONDER_ASR_TEST_AUDIO")
        .or_else(|_| std::env::var("WONDER_ASR_TEST_WAV"))
        .expect("explicit audio fixture");
    let duration: u64 = std::env::var("WONDER_ASR_TEST_DURATION_MS")
        .unwrap_or("300000".into())
        .parse()
        .unwrap();
    let (dir, mut state) = crate::ingestion::tests::fixture().await;
    let mut service = AsrService::default();
    service.root = dir.path().join("asr-jobs");
    service.worker = Some(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../scripts/nemo-speech-worker.py")
            .into_os_string(),
    );
    state.asr_service = Arc::new(service);
    state.asr_service.initialize(&state.store).await.unwrap();
    assert!(state.asr_service.model.lock().await.verified);
    let audio = std::fs::read(audio_path).unwrap();
    let mime = sniff_audio_mime(&audio).unwrap();
    let start = std::time::Instant::now();
    let response = router(state.clone())
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/asr/transcriptions")
                .header("x-wonder-loopback-capability", "test")
                .header("content-type", mime)
                .header("x-wonder-duration-ms", duration.to_string())
                .header("x-wonder-request-id", uuid::Uuid::new_v4().to_string())
                .body(Body::from(audio))
                .unwrap(),
        )
        .await
        .unwrap();
    let (status, mut job) = json_response(response).await;
    assert_eq!(status, StatusCode::ACCEPTED, "{job}");
    let id = job["id"].as_str().unwrap().to_owned();
    for _ in 0..1200 {
        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .uri(format!("/api/v1/asr/transcriptions/{id}"))
                    .header("x-wonder-loopback-capability", "test")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let (status, latest) = json_response(response).await;
        assert_eq!(status, StatusCode::OK);
        job = latest;
        if job["state"] == "completed" || job["state"] == "failed" {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(job["state"], "completed", "{job}");
    assert!(
        job["durationMs"].as_u64().unwrap().abs_diff(duration) < 100,
        "{job}"
    );
    assert!(job["transcriptText"]
        .as_str()
        .is_some_and(|t| !t.is_empty()));
    assert!(state.store.asr_job_audio(&id).await.unwrap().is_none());
    let schema: serde_json::Value = serde_json::from_str(include_str!(
        "../../../packages/protocol/schemas/wonder-http-v1.json"
    ))
    .unwrap();
    let wrapper = serde_json::json!({"$ref":"#/$defs/asrTranscription","$defs":schema["$defs"]});
    jsonschema::validator_for(&wrapper)
        .unwrap()
        .validate(&job)
        .unwrap();
    if let Ok(path) = std::env::var("WONDER_ASR_TEST_RESULT") {
        std::fs::write(
            path,
            serde_json::to_vec_pretty(
                &serde_json::json!({"wallSeconds":start.elapsed().as_secs_f64(),"job":job}),
            )
            .unwrap(),
        )
        .unwrap();
    }
    state.app_server.lock().await.shutdown().await.unwrap();
}

#[tokio::test]
#[allow(clippy::field_reassign_with_default)]
async fn asr_model_mutations_persist_and_refuse_active_use() {
    let (dir, mut state) = crate::ingestion::tests::fixture().await;
    let mut service = AsrService::default();
    service.root = dir.path().join("asr-models");
    std::fs::create_dir_all(&service.root).unwrap();
    service.model_path = service.root.join("model.gguf");
    std::fs::write(&service.model_path, b"fixture model").unwrap();
    service.initialized.set(()).unwrap();
    *service.model.get_mut() = ModelState {
        verified: true,
        selected: true,
        download_state: "idle",
        ..Default::default()
    };
    state.asr_service = Arc::new(service);
    let slot = state.asr_slots.clone().acquire_owned().await.unwrap();
    assert_eq!(
        delete_model(
            State(state.clone()),
            Some(Extension(LocalOwnerAuthority)),
            Path(MODEL_ID.into())
        )
        .await
        .status(),
        StatusCode::CONFLICT
    );
    assert!(state.asr_service.model_path.exists());
    drop(slot);
    assert_eq!(
        select_model(
            State(state.clone()),
            Some(Extension(LocalOwnerAuthority)),
            Path(MODEL_ID.into())
        )
        .await
        .status(),
        StatusCode::OK
    );
    let (_, status) = json_response(
        select_model(
            State(state.clone()),
            Some(Extension(LocalOwnerAuthority)),
            Path(MODEL_ID.into()),
        )
        .await,
    )
    .await;
    assert_eq!(status["models"][0]["inUse"], false);
    assert_eq!(status["models"][0]["canDelete"], true);
    let selection: serde_json::Value = serde_json::from_slice(
        &std::fs::read(state.asr_service.root.join("asr-selection.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(selection["modelId"], MODEL_ID);
    assert_eq!(
        delete_model(
            State(state.clone()),
            Some(Extension(LocalOwnerAuthority)),
            Path(MODEL_ID.into())
        )
        .await
        .status(),
        StatusCode::OK
    );
    assert!(!state.asr_service.model_path.exists());
    assert!(!state.asr_service.model.lock().await.selected);
    state.app_server.lock().await.shutdown().await.unwrap();
}

#[tokio::test]
async fn asr_request_cancel_route_rejects_a_late_upload_and_requires_auth() {
    use tower::ServiceExt;
    let (_dir, mut state) = crate::ingestion::tests::fixture().await;
    let service = AsrService::default();
    service.initialized.set(()).unwrap();
    state.asr_service = Arc::new(service);
    let request_id = "419a3ffd-b81b-4a62-9cc4-f38561526889";
    let path = format!("/api/v1/asr/transcriptions/by-request/{request_id}");
    let send = |authorized: bool| {
        let mut request = Request::builder().method("DELETE").uri(&path);
        if authorized {
            request = request.header("x-wonder-loopback-capability", &state.loopback_capability);
        }
        request.body(Body::empty()).unwrap()
    };
    assert!(!router(state.clone())
        .oneshot(send(false))
        .await
        .unwrap()
        .status()
        .is_success());
    for _ in 0..2 {
        assert_eq!(
            router(state.clone())
                .oneshot(send(true))
                .await
                .unwrap()
                .status(),
            StatusCode::NO_CONTENT
        );
    }
    let response = router(state.clone())
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/asr/transcriptions")
                .header("x-wonder-loopback-capability", &state.loopback_capability)
                .header("content-type", "audio/wav")
                .header("x-wonder-duration-ms", "1000")
                .header("x-wonder-request-id", request_id)
                .body(Body::from("RIFF0000WAVEdata"))
                .unwrap(),
        )
        .await
        .unwrap();
    let (status, value) = json_response(response).await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(value["errorCategory"], "cancelled");
    assert!(state
        .store
        .asr_job_by_request("local-loopback", request_id)
        .await
        .unwrap()
        .is_none());
    assert_eq!(state.asr_slots.available_permits(), 1);
    let _ = state.app_server.lock().await.shutdown().await;
}

#[tokio::test]
#[allow(clippy::field_reassign_with_default)]
async fn asr_seekable_input_permissions_limits_and_cancel_cleanup() {
    let root = tempfile::tempdir().unwrap();
    let input = DecoderInput::create(root.path().into(), vec![0; MAX_RECORDING_BYTES]).unwrap();
    assert_eq!(
        std::fs::metadata(&input.path).unwrap().len(),
        MAX_RECORDING_BYTES as u64
    );
    assert_eq!(
        std::fs::metadata(&input.directory)
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    assert_eq!(
        std::fs::metadata(&input.path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let directory = input.directory.clone();
    drop(input);
    assert!(!directory.exists());
    let marker = root.path().join("decoder-input-path");
    let decoder = root.path().join("decoder");
    executable(&decoder, &format!("#!/usr/bin/env python3\nimport sys,time\nopen({:?},'w').write(sys.argv[sys.argv.index('-i')+1])\ntime.sleep(60)\n", marker.to_str().unwrap()));
    let mut service = AsrService::default();
    service.root = root.path().into();
    service.model_path = root.path().join("missing-test-model");
    service.decoder = decoder.into_os_string();
    let service = Arc::new(service);
    let (_sender, receiver) = watch::channel(false);
    assert_eq!(
        normalize_audio(
            &service,
            "audio/mp4",
            vec![0; MAX_RECORDING_BYTES + 1],
            receiver
        )
        .await
        .unwrap_err(),
        AsrErrorCategory::Upload
    );
    for abort in [false, true] {
        let _ = std::fs::remove_file(&marker);
        let (sender, receiver) = watch::channel(false);
        let owned = service.clone();
        let task = tokio::spawn(async move {
            normalize_audio(&owned, "audio/mp4", b"native-recording".to_vec(), receiver).await
        });
        for _ in 0..100 {
            if marker.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let path = PathBuf::from(std::fs::read_to_string(&marker).unwrap());
        assert!(path.is_file());
        if abort {
            task.abort();
            assert!(task.await.unwrap_err().is_cancelled());
        } else {
            sender.send(true).unwrap();
            assert_eq!(
                task.await.unwrap().unwrap_err(),
                AsrErrorCategory::Cancelled
            );
        }
        assert!(!path.parent().unwrap().exists());
    }
    assert_eq!(
        std::fs::read_dir(root.path().join("jobs")).unwrap().count(),
        0
    );
    // A process crash bypasses Drop; initialization removes those private inputs too.
    let stale = root.path().join("jobs/decoder-interrupted");
    std::fs::create_dir(&stale).unwrap();
    std::fs::write(stale.join("recording"), b"interrupted upload").unwrap();
    let store = Store::connect("sqlite::memory:").await.unwrap();
    service.initialize(&store).await.unwrap();
    assert!(!stale.exists());
}

#[tokio::test]
#[ignore = "Requires local FFmpeg; exercises real AAC/M4A with a trailing moov atom"]
#[allow(clippy::field_reassign_with_default)]
async fn asr_real_ffmpeg_decodes_native_m4a_without_faststart() {
    let root = tempfile::tempdir().unwrap();
    let native = root.path().join("native.m4a");
    // Default MP4 output places moov after media data, like AVAudioRecorder.
    let status = Command::new("ffmpeg")
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:sample_rate=44100",
            "-t",
            "180",
            "-ac",
            "1",
            "-c:a",
            "aac",
            "-b:a",
            "64000",
            "-f",
            "mp4",
        ])
        .arg(&native)
        .status()
        .await
        .unwrap();
    assert!(status.success());
    let audio = std::fs::read(&native).unwrap();
    let atom = |name: &[u8]| audio.windows(4).position(|v| v == name).unwrap();
    assert!(atom(b"moov") > atom(b"mdat"));
    let mut service = AsrService::default();
    service.root = root.path().join("normalizer");
    let (_sender, receiver) = watch::channel(false);
    let mut pipe = Command::new("ffmpeg");
    pipe.args([
        "-hide_banner",
        "-loglevel",
        "error",
        "-f",
        "mp4",
        "-i",
        "pipe:0",
        "-ac",
        "1",
        "-ar",
        "16000",
        "-f",
        "s16le",
        "pipe:1",
    ]);
    let old = bounded_process(
        pipe,
        audio.clone(),
        MAX_PCM_BYTES,
        DECODER_TIMEOUT,
        receiver.clone(),
    )
    .await;
    assert!(
        old.is_err() || old.unwrap().is_empty(),
        "fixture must reproduce the non-seekable failure"
    );
    let pcm = normalize_audio(&service, "audio/mp4", audio, receiver.clone())
        .await
        .unwrap();
    assert!((180000..180100).contains(&normalized_duration_ms(&pcm)));
    assert!(pcm.iter().any(|v| *v != 0));
    assert_eq!(
        std::fs::read_dir(service.root.join("jobs"))
            .unwrap()
            .count(),
        0
    );
    assert!(
        normalize_audio(&service, "audio/mp4", b"invalid MP4".to_vec(), receiver)
            .await
            .is_err()
    );
    assert_eq!(
        std::fs::read_dir(service.root.join("jobs"))
            .unwrap()
            .count(),
        0
    );
}
