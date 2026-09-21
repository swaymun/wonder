use crate::forms::{choices, Form};
use gpui_kit::*;
use serde_json::Value;

pub const DAYS: [(&str, &str); 7] = [
    ("MO", "Mon"),
    ("TU", "Tue"),
    ("WE", "Wed"),
    ("TH", "Thu"),
    ("FR", "Fri"),
    ("SA", "Sat"),
    ("SU", "Sun"),
];
pub fn populate(
    form: &mut Form,
    value: &Value,
    timezone: &str,
    window: &mut Window,
    cx: &mut App,
) -> Vec<String> {
    form.input("name", value["name"].as_str().unwrap_or(""), window, cx);
    form.text("prompt", value["prompt"].as_str().unwrap_or(""), window, cx);
    form.input(
        "timezone",
        value["timezone"].as_str().unwrap_or(timezone),
        window,
        cx,
    );
    form.select(
        "kind",
        value["kind"].as_str().unwrap_or("continuation"),
        choices(&[
            ("continuation", "Continue this conversation"),
            ("standalone", "Start a separate conversation"),
        ]),
        window,
        cx,
    );
    let rule = value["rrule"]
        .as_str()
        .unwrap_or("FREQ=DAILY;BYHOUR=9;BYMINUTE=0");
    let parts: std::collections::BTreeMap<_, _> = rule
        .trim_start_matches("RRULE:")
        .split(';')
        .filter_map(|v| v.split_once('='))
        .collect();
    form.select(
        "frequency",
        parts.get("FREQ").copied().unwrap_or("DAILY"),
        choices(&[
            ("MINUTELY", "Every few minutes"),
            ("HOURLY", "Every few hours"),
            ("DAILY", "Daily"),
            ("WEEKLY", "Weekly"),
            ("MONTHLY", "Monthly"),
        ]),
        window,
        cx,
    );
    form.input(
        "interval",
        parts.get("INTERVAL").copied().unwrap_or("1"),
        window,
        cx,
    );
    form.select(
        "hourInterval",
        parts.get("INTERVAL").copied().unwrap_or("1"),
        choices(&[
            ("1", "Every hour"),
            ("2", "Every 2 hours"),
            ("3", "Every 3 hours"),
            ("4", "Every 4 hours"),
            ("6", "Every 6 hours"),
            ("8", "Every 8 hours"),
            ("12", "Every 12 hours"),
            ("24", "Every 24 hours"),
        ]),
        window,
        cx,
    );
    form.input(
        "time",
        &format!(
            "{:02}:{:02}",
            parts
                .get("BYHOUR")
                .and_then(|v| v.parse::<u8>().ok())
                .unwrap_or(9),
            parts
                .get("BYMINUTE")
                .and_then(|v| v.parse::<u8>().ok())
                .unwrap_or(0)
        ),
        window,
        cx,
    );
    form.input(
        "monthday",
        parts.get("BYMONTHDAY").copied().unwrap_or("1"),
        window,
        cx,
    );
    parts
        .get("BYDAY")
        .unwrap_or(&"MO")
        .split(',')
        .map(str::to_owned)
        .collect()
}
pub fn schedule(form: &Form, days: &[String], cx: &App) -> Result<String, String> {
    let frequency = form.value("frequency", cx);
    let interval = match frequency.as_str() {
        "HOURLY" => form.value("hourInterval", cx),
        "MINUTELY" => form.value("interval", cx),
        _ => "1".into(),
    };
    schedule_values(
        &frequency,
        &interval,
        &form.value("time", cx),
        &form.value("monthday", cx),
        days,
    )
}
fn schedule_values(
    frequency: &str,
    interval: &str,
    time: &str,
    day: &str,
    days: &[String],
) -> Result<String, String> {
    let interval = interval
        .trim()
        .parse::<u32>()
        .map_err(|_| "Enter a whole-number interval.")?;
    match frequency {
        "MINUTELY" if !(1..=1440).contains(&interval) => {
            return Err("Enter an interval from 1 to 1440 minutes.".into())
        }
        "HOURLY" if ![1, 2, 3, 4, 6, 8, 12, 24].contains(&interval) => {
            return Err("Choose an hourly interval of 1, 2, 3, 4, 6, 8, 12 or 24.".into())
        }
        "DAILY" | "WEEKLY" | "MONTHLY" if interval != 1 => {
            return Err("Daily, weekly and monthly schedules repeat every period.".into())
        }
        "MINUTELY" | "HOURLY" | "DAILY" | "WEEKLY" | "MONTHLY" => {}
        _ => return Err("Choose a supported frequency.".into()),
    }
    let mut rule = format!("FREQ={frequency};INTERVAL={interval}");
    if frequency != "MINUTELY" {
        let (h, m) = time
            .trim()
            .split_once(':')
            .ok_or("Enter a time as HH:MM.")?;
        let hour = h
            .parse::<u8>()
            .ok()
            .filter(|v| *v < 24)
            .ok_or("Enter an hour from 00 to 23.")?;
        let minute = m
            .parse::<u8>()
            .ok()
            .filter(|v| *v < 60)
            .ok_or("Enter minutes from 00 to 59.")?;
        if frequency != "HOURLY" {
            rule.push_str(&format!(";BYHOUR={hour}"));
        }
        rule.push_str(&format!(";BYMINUTE={minute}"));
    }
    if frequency == "WEEKLY" {
        if days.is_empty() {
            return Err("Choose at least one weekday.".into());
        }
        rule.push_str(&format!(";BYDAY={}", days.join(",")));
    }
    if frequency == "MONTHLY" {
        let day = day
            .trim()
            .parse::<u8>()
            .ok()
            .filter(|v| *v > 0 && *v <= 31)
            .ok_or("Choose a day from 1 to 31.")?;
        rule.push_str(&format!(";BYMONTHDAY={day}"));
    }
    Ok(rule)
}
#[cfg(test)]
mod tests {
    use super::schedule_values;
    #[test]
    fn schedule_preserves_weekday_time_and_rejects_invalid_input() {
        assert_eq!(
            schedule_values("WEEKLY", "1", "09:30", "1", &["MO".into(), "FR".into()]).unwrap(),
            "FREQ=WEEKLY;INTERVAL=1;BYHOUR=9;BYMINUTE=30;BYDAY=MO,FR"
        );
        assert!(schedule_values("WEEKLY", "1", "09:30", "1", &[]).is_err());
        assert!(schedule_values("DAILY", "0", "09:30", "1", &[]).is_err());
        assert!(schedule_values("DAILY", "1", "25:30", "1", &[]).is_err());
        for (frequency, interval) in [
            ("MINUTELY", "1441"),
            ("HOURLY", "5"),
            ("DAILY", "2"),
            ("WEEKLY", "2"),
            ("MONTHLY", "2"),
        ] {
            assert!(schedule_values(frequency, interval, "09:30", "1", &["MO".into()]).is_err());
        }
        assert!(schedule_values("MINUTELY", "1440", "", "", &[]).is_ok());
        for interval in ["1", "2", "3", "4", "6", "8", "12", "24"] {
            assert!(schedule_values("HOURLY", interval, "09:30", "", &[]).is_ok());
        }
        assert_eq!(
            schedule_values("MINUTELY", "30", "", "", &[]).unwrap(),
            "FREQ=MINUTELY;INTERVAL=30"
        );
    }
}
