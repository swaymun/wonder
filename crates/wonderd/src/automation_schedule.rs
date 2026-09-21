//! Deliberately bounded recurrence support, shared by preview and execution.
use chrono::{DateTime, Datelike, Duration, SecondsFormat, TimeZone, Timelike, Utc, Weekday};
use chrono_tz::Tz;
use std::collections::HashSet;

pub(crate) fn next_automation_run(
    rule: &str,
    zone: &str,
    after: DateTime<Utc>,
) -> Result<Option<String>, String> {
    let timezone = zone
        .parse::<Tz>()
        .map_err(|_| "Choose a valid timezone.".to_owned())?;
    let mut frequency = "";
    let mut interval = 1u32;
    let mut hour = 9u32;
    let mut minute = 0u32;
    let mut month_day = 1u32;
    let mut weekdays = Vec::new();
    let mut seen = HashSet::new();
    for field in rule.split(';') {
        let (key, value) = field
            .split_once('=')
            .ok_or("The schedule rule is malformed.")?;
        if !seen.insert(key) {
            return Err("The schedule repeats a field.".into());
        }
        match key {
            "FREQ"
                if matches!(
                    value,
                    "MINUTELY" | "HOURLY" | "DAILY" | "WEEKLY" | "MONTHLY"
                ) =>
            {
                frequency = value
            }
            "INTERVAL" => interval = value.parse().map_err(|_| "The interval is invalid.")?,
            "BYHOUR" => hour = value.parse().map_err(|_| "The hour is invalid.")?,
            "BYMINUTE" => minute = value.parse().map_err(|_| "The minute is invalid.")?,
            "BYMONTHDAY" => {
                month_day = value.parse().map_err(|_| "The day of month is invalid.")?
            }
            "BYDAY" => {
                for day in value.split(',') {
                    weekdays.push(match day {
                        "MO" => Weekday::Mon,
                        "TU" => Weekday::Tue,
                        "WE" => Weekday::Wed,
                        "TH" => Weekday::Thu,
                        "FR" => Weekday::Fri,
                        "SA" => Weekday::Sat,
                        "SU" => Weekday::Sun,
                        _ => return Err("The weekday is invalid.".into()),
                    });
                }
            }
            _ => return Err("The schedule contains an unsupported field.".into()),
        }
    }
    if frequency.is_empty()
        || hour > 23
        || minute > 59
        || !(1..=31).contains(&month_day)
        || !(1..=1440).contains(&interval)
    {
        return Err("The schedule contains an invalid value.".into());
    }
    if (!matches!(frequency, "MINUTELY" | "HOURLY") && interval != 1)
        || (frequency == "HOURLY" && (interval > 24 || 24 % interval != 0))
    {
        return Err("This interval is not supported for the chosen frequency.".into());
    }
    if (frequency == "MINUTELY" && seen.iter().any(|key| key.starts_with("BY")))
        || (frequency == "HOURLY"
            && (seen.contains("BYHOUR") || seen.contains("BYMONTHDAY") || seen.contains("BYDAY")))
        || (frequency != "MONTHLY" && seen.contains("BYMONTHDAY"))
        || (frequency == "MONTHLY" && seen.contains("BYDAY"))
        || (frequency == "WEEKLY" && weekdays.is_empty())
    {
        return Err("This schedule combination is not supported.".into());
    }
    let format = |value: DateTime<Utc>| Some(value.to_rfc3339_opts(SecondsFormat::Millis, true));
    if frequency == "MINUTELY" {
        // Absolute minute boundaries remain continuous across DST changes and
        // correctly support intervals greater than one hour.
        let minutes = after.timestamp().div_euclid(60);
        let next = (minutes.div_euclid(i64::from(interval)) + 1) * i64::from(interval) * 60;
        return Ok(format(
            DateTime::from_timestamp(next, 0).ok_or("Schedule is out of range.")?,
        ));
    }
    if frequency == "HOURLY" {
        let mut candidate = after
            .with_second(0)
            .and_then(|v| v.with_nanosecond(0))
            .ok_or("Schedule is out of range.")?
            + Duration::minutes(1);
        for _ in 0..=60 * 49 {
            let local = candidate.with_timezone(&timezone);
            if local.minute() == minute && local.hour().is_multiple_of(interval) {
                return Ok(format(candidate));
            }
            candidate += Duration::minutes(1);
        }
        return Err("No upcoming occurrence was found.".into());
    }
    let date = after.with_timezone(&timezone).date_naive();
    for offset in 0..=370 {
        let date = date + Duration::days(offset);
        if (!weekdays.is_empty() && !weekdays.contains(&date.weekday()))
            || (frequency == "MONTHLY" && date.day() != month_day)
        {
            continue;
        }
        let local = date
            .and_hms_opt(hour, minute, 0)
            .ok_or("Schedule is out of range.")?;
        // Skip nonexistent spring times. A repeated fall time runs once, at
        // its first occurrence, matching the preview shown to the user.
        if let Some(candidate) = timezone.from_local_datetime(&local).earliest() {
            let candidate = candidate.with_timezone(&Utc);
            if candidate > after {
                return Ok(format(candidate));
            }
        }
    }
    Err("No upcoming occurrence was found.".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn next(rule: &str, zone: &str, now: &str) -> String {
        next_automation_run(rule, zone, now.parse().unwrap())
            .unwrap()
            .unwrap()
    }
    #[test]
    fn monthly_skips_missing_dates() {
        assert_eq!(
            next(
                "FREQ=MONTHLY;BYMONTHDAY=31;BYHOUR=9",
                "UTC",
                "2026-04-01T00:00:00Z"
            ),
            "2026-05-31T09:00:00.000Z"
        );
    }
    #[test]
    fn weekdays_and_dst_are_explicit() {
        assert_eq!(
            next(
                "FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9",
                "America/New_York",
                "2026-03-06T15:00:00Z"
            ),
            "2026-03-09T13:00:00.000Z"
        );
        assert_eq!(
            next(
                "FREQ=DAILY;BYHOUR=2;BYMINUTE=30",
                "America/New_York",
                "2026-03-08T06:00:00Z"
            ),
            "2026-03-09T06:30:00.000Z"
        );
        assert_eq!(
            next(
                "FREQ=DAILY;BYHOUR=1;BYMINUTE=30",
                "America/New_York",
                "2026-11-01T05:31:00Z"
            ),
            "2026-11-02T06:30:00.000Z"
        );
    }
    #[test]
    fn elapsed_intervals_survive_dst() {
        assert_eq!(
            next("FREQ=MINUTELY;INTERVAL=90", "UTC", "2026-01-01T01:31:00Z"),
            "2026-01-01T03:00:00.000Z"
        );
        assert_eq!(
            next(
                "FREQ=HOURLY;BYMINUTE=30",
                "America/New_York",
                "2026-03-08T06:31:00Z"
            ),
            "2026-03-08T07:30:00.000Z"
        );
    }
    #[test]
    fn unsupported_fields_never_silently_disappear() {
        for rule in [
            "FREQ=DAILY;FREQ=WEEKLY",
            "FREQ=MONTHLY;BYDAY=MO",
            "FREQ=MINUTELY;BYHOUR=9",
            "FREQ=HOURLY;INTERVAL=5",
        ] {
            assert!(
                next_automation_run(rule, "UTC", Utc::now()).is_err(),
                "{rule}"
            );
        }
    }
}
