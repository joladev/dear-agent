import dear_agent
import gleam/time/timestamp
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn relative_time_test() {
  // we have to use hardcoded now
  let assert Ok(now) = timestamp.parse_rfc3339("2026-05-07T12:00:00Z")
  let timestamp_string = "2026-05-07T11:59:59Z"
  let relative_time = dear_agent.relative_time(timestamp_string, now)
  assert relative_time == "just now"

  let timestamp_string = "2026-05-07T11:59:00Z"
  let relative_time = dear_agent.relative_time(timestamp_string, now)
  assert relative_time == "1m ago"

  let timestamp_string = "2026-05-07T10:59:00Z"
  let relative_time = dear_agent.relative_time(timestamp_string, now)
  assert relative_time == "1h ago"

  let timestamp_string = "2026-05-06T11:59:00Z"
  let relative_time = dear_agent.relative_time(timestamp_string, now)
  assert relative_time == "1d ago"

  let timestamp_string = "2026-04-30T11:59:00Z"
  let relative_time = dear_agent.relative_time(timestamp_string, now)
  assert relative_time == "1w ago"
}
