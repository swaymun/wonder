use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use serde_json::{json, Value};
use wonder_app_server::{initialize_request, RequiredMethod, RpcResponse};

const RECORDED_FIXTURES: &[&str] = &[
    include_str!("../../../tests/contracts/fixtures/initialization.jsonl"),
    include_str!("../../../tests/contracts/fixtures/account.jsonl"),
    include_str!("../../../tests/contracts/fixtures/models.jsonl"),
    include_str!("../../../tests/contracts/fixtures/rate-limits.jsonl"),
    include_str!("../../../tests/contracts/fixtures/permissions.jsonl"),
    include_str!("../../../tests/contracts/fixtures/threads-turns.jsonl"),
    include_str!("../../../tests/contracts/fixtures/approvals.jsonl"),
    include_str!("../../../tests/contracts/fixtures/restart-ambiguous.jsonl"),
    include_str!("../../../tests/contracts/fixtures/unknown-fields.jsonl"),
];

fn main() {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("recorded") => {
            let restart = args.any(|arg| arg == "--restart");
            if let Err(error) = run_recorded(restart) {
                eprintln!("recorded smoke failed: {error}");
                std::process::exit(1);
            }
            println!("recorded smoke passed (model usage: none)");
        }
        Some("__fake-app-server") => fake_app_server(),
        _ => {
            eprintln!("usage: wonder-smoke recorded [--restart]");
            std::process::exit(2);
        }
    }
}

fn run_recorded(restart: bool) -> Result<(), String> {
    for fixture in RECORDED_FIXTURES {
        for line in fixture.lines().filter(|line| !line.trim().is_empty()) {
            serde_json::from_str::<Value>(line)
                .map_err(|error| format!("invalid fixture: {error}"))?;
        }
    }
    run_cycle()?;
    if restart {
        run_cycle()?;
    }
    Ok(())
}

fn run_cycle() -> Result<(), String> {
    let executable = std::env::current_exe().map_err(|error| error.to_string())?;
    let mut child = Command::new(executable)
        .arg("__fake-app-server")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("spawn fake App Server: {error}"))?;
    let mut input = child.stdin.take().ok_or("fake stdin unavailable")?;
    let output = child.stdout.take().ok_or("fake stdout unavailable")?;
    let mut reader = BufReader::new(output);

    let init = initialize_request("0.1.0").request;
    send(
        &mut input,
        &serde_json::to_value(init).map_err(|error| error.to_string())?,
    )?;
    let init_response = read_response(&mut reader, 1)?;
    let result = init_response
        .result
        .ok_or("initialize returned no result")?;
    wonder_app_server::require_experimental_api(&result).map_err(str::to_owned)?;
    send(
        &mut input,
        &json!({ "method": "initialized", "params": {} }),
    )?;

    let discovery = [
        (2, RequiredMethod::ConfigRequirementsRead),
        (3, RequiredMethod::PermissionProfileList),
        (4, RequiredMethod::AccountRead),
        (5, RequiredMethod::ModelList),
        (6, RequiredMethod::RateLimitsRead),
        (7, RequiredMethod::AppList),
        (8, RequiredMethod::SkillsList),
        (9, RequiredMethod::McpServerStatusList),
        (10, RequiredMethod::ThreadStart),
    ];
    for (id, method) in discovery {
        let params = if method == RequiredMethod::PermissionProfileList {
            json!({ "cwd": "/tmp/wonder-recorded" })
        } else if method == RequiredMethod::SkillsList {
            json!({ "cwds": ["/tmp/wonder-recorded"], "forceReload": false })
        } else if method == RequiredMethod::AppList || method == RequiredMethod::McpServerStatusList
        {
            json!({ "limit": 1, "detail": "toolsAndAuthOnly" })
        } else {
            json!({})
        };
        send(
            &mut input,
            &json!({ "method": method.as_str(), "id": id, "params": params }),
        )?;
        let response = read_response(&mut reader, id)?;
        if response.error.is_some() {
            return Err(format!("{} failed: {:?}", method.as_str(), response.error));
        }
        if method == RequiredMethod::PermissionProfileList {
            let result = response
                .result
                .as_ref()
                .ok_or("permissionProfile/list returned no result")?;
            wonder_app_server::require_named_profile(result, "wonder_bot_recorded")
                .map_err(str::to_owned)?;
        }
    }

    send(
        &mut input,
        &json!({
            "method": "turn/start",
            "id": 8,
            "params": {
                "threadId": "thread-recorded",
                "clientUserMessageId": "00000000-0000-4000-8000-000000000001",
                "input": [{ "type": "text", "text": "recorded message" }],
                "permissions": "wonder_bot_recorded",
                "runtimeWorkspaceRoots": ["/tmp/wonder-recorded"]
            }
        }),
    )?;
    let turn = read_response(&mut reader, 8)?;
    if turn.error.is_some() {
        return Err(format!("turn/start failed: {:?}", turn.error));
    }

    drop(input);
    let status = child
        .wait()
        .map_err(|error| format!("wait for fake App Server: {error}"))?;
    if !status.success() {
        return Err(format!("fake App Server exited with {status}"));
    }
    Ok(())
}

fn send(input: &mut ChildStdin, message: &Value) -> Result<(), String> {
    serde_json::to_writer(&mut *input, message).map_err(|error| error.to_string())?;
    input.write_all(b"\n").map_err(|error| error.to_string())?;
    input.flush().map_err(|error| error.to_string())
}

fn read_response(
    reader: &mut BufReader<ChildStdout>,
    expected_id: u64,
) -> Result<RpcResponse, String> {
    let mut line = String::new();
    loop {
        line.clear();
        if reader
            .read_line(&mut line)
            .map_err(|error| error.to_string())?
            == 0
        {
            return Err("fake App Server ended before response".into());
        }
        let value: Value =
            serde_json::from_str(&line).map_err(|error| format!("invalid response: {error}"))?;
        if value.get("id").and_then(Value::as_u64) == Some(expected_id) {
            return serde_json::from_value(value).map_err(|error| error.to_string());
        }
    }
}

fn fake_app_server() {
    let stdin = std::io::stdin();
    let mut initialized = false;
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let Ok(request) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let method = request["method"].as_str().unwrap_or_default();
        if method == "initialized" {
            continue;
        }
        let Some(id) = request["id"].as_u64() else {
            continue;
        };
        if method == "initialize" {
            if initialized {
                respond(
                    id,
                    json!({ "code": -32600, "message": "Already initialized" }),
                    true,
                );
            } else {
                initialized = true;
                respond(
                    id,
                    json!({
                        "userAgent": "wonder-fake-codex",
                        "platformFamily": "macos",
                        "platformOs": "macos",
                        "capabilities": { "experimentalApi": true }
                    }),
                    false,
                );
            }
            continue;
        }
        if !initialized {
            respond(
                id,
                json!({ "code": -32000, "message": "Not initialized" }),
                true,
            );
            continue;
        }
        let result = match method {
            "permissionProfile/list" => {
                json!({ "data": [{ "name": "wonder_bot_recorded", "allowed": true, "filesystem": { ":minimal": "read" }, "network": { "enabled": false } }] })
            }
            "account/read" => {
                json!({ "account": { "type": "chatgpt", "email": "recorded@example.invalid" } })
            }
            "model/list" => {
                json!({ "data": [{ "id": "gpt-5.6-luna", "supportedReasoningEfforts": ["low", "medium"] }], "nextCursor": null })
            }
            "account/rateLimits/read" => {
                json!({ "rateLimits": [{ "limitName": "recorded", "usedPercent": 0, "windowDurationMins": 60 }] })
            }
            "thread/start" => {
                json!({ "thread": { "id": "thread-recorded", "sessionId": "session-recorded" } })
            }
            "turn/start" => {
                if request["params"]["clientUserMessageId"].as_str().is_none() {
                    respond(
                        id,
                        json!({ "code": -32602, "message": "clientUserMessageId required" }),
                        true,
                    );
                    continue;
                }
                println!(
                    "{}",
                    json!({ "method": "item/agentMessage/delta", "params": { "item": { "id": "item-recorded" }, "delta": "recorded response" } })
                );
                println!(
                    "{}",
                    json!({ "method": "item/completed", "params": { "item": { "id": "item-recorded", "text": "recorded response" } } })
                );
                json!({ "turn": { "id": "turn-recorded" } })
            }
            _ => json!({}),
        };
        respond(id, result, false);
    }
}

fn respond(id: u64, payload: Value, error: bool) {
    let response = if error {
        json!({ "id": id, "error": payload, "futureField": "preserved-as-unknown" })
    } else {
        json!({ "id": id, "result": payload, "futureField": "preserved-as-unknown" })
    };
    println!("{response}");
    std::io::stdout().flush().expect("fake stdout flush");
}

#[allow(dead_code)]
fn _keep_child_type(_: Child) {}
