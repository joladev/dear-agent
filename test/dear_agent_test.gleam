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

pub fn encode_entry_test() {
  let entry =
    dear_agent.Entry(
      kind: dear_agent.Post,
      headers: [#("Content-Type", "application/json")],
      ts: "2026-05-07T12:00:00Z",
      user_agent: "test",
      ip: "127.0.0.1",
      query: "",
      body: "{}",
    )
  let encoded = dear_agent.encode_entry(entry)
  assert encoded
    == "{\"headers\":[[\"Content-Type\",\"application/json\"]],\"timestamp\":\"2026-05-07T12:00:00Z\",\"user_agent\":\"test\",\"ip\":\"127.0.0.1\",\"query\":\"\",\"body\":\"{}\",\"type\":\"post\"}\n"
}

pub fn round_trip_post_test() {
  let entry =
    dear_agent.Entry(
      kind: dear_agent.Post,
      headers: [#("a", "1"), #("b", "2")],
      ts: "2026-05-07T12:00:00Z",
      user_agent: "ua",
      ip: "1.2.3.4",
      query: "",
      body: "hello",
    )
  assert dear_agent.parse_entry(dear_agent.encode_entry(entry)) == Ok(entry)
}

pub fn parse_malformed_test() {
  let assert Error(_) = dear_agent.parse_entry("not json")
}
