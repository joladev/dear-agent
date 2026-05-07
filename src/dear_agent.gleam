import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import lustre/attribute
import lustre/element
import lustre/element/html.{html}
import mist
import simplifile
import wisp
import wisp/wisp_mist

type Entry {
  Entry(
    kind: Kind,
    ts: String,
    ip: String,
    user_agent: String,
    headers: List(#(String, String)),
    query: String,
    body: String,
  )
}

type Kind {
  Post
  Probe
}

pub fn main() -> Nil {
  wisp.configure_logger()

  let assert Ok(_) = simplifile.create_directory_all("/tmp/dear_agent")
  let name = process.new_name("entries")
  let assert Ok(entries) = case read_entries() {
    Error(simplifile.Enoent) -> Ok([])
    other -> other
  }

  let assert Ok(_) =
    actor.new(entries)
    |> actor.named(name)
    |> actor.on_message(handle_message)
    |> actor.start()

  let handler = fn(req) { handle_request(req, name) }

  let assert Ok(_) =
    handler
    |> wisp_mist.handler(wisp.random_string(32))
    |> mist.new()
    |> mist.port(3999)
    |> mist.start()

  process.sleep_forever()
}

fn middleware(
  req: wisp.Request,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  use req <- wisp.csrf_known_header_protection(req)

  handle_request(req)
}

fn handle_request(
  req: wisp.Request,
  name: process.Name(Message),
) -> wisp.Response {
  use req <- middleware(req)

  case wisp.path_segments(req) {
    [] -> handle_index(req, name)
    ["post"] -> handle_post(req, name)
    ["probe"] -> handle_probe(req, name)
    _ -> wisp.not_found()
  }
}

fn handle_index(
  req: wisp.Request,
  name: process.Name(Message),
) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)

  let subject = process.named_subject(name)
  let entries = actor.call(subject, waiting: 1000, sending: GetRecentEntries)
  let page = render_page(entries)

  wisp.html_body(wisp.ok(), page)
}

fn handle_post(
  req: wisp.Request,
  name: process.Name(Message),
) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  use body <- wisp.require_string_body(req)

  case record(req, option.Some(body), Post) {
    Ok(entry) -> {
      let subject = process.named_subject(name)
      process.send(subject, AddEntry(entry))
      wisp.html_body(wisp.ok(), "Post received")
    }
    Error(error) -> {
      wisp.log_warning(
        "Something went wrong" <> simplifile.describe_error(error),
      )
      wisp.html_body(wisp.ok(), "Post received")
    }
  }
}

fn handle_probe(
  req: wisp.Request,
  name: process.Name(Message),
) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)

  case record(req, option.None, Probe) {
    Ok(entry) -> {
      let subject = process.named_subject(name)
      process.send(subject, AddEntry(entry))
      wisp.html_body(wisp.ok(), "Get received")
    }
    Error(error) -> {
      wisp.log_warning(
        "Something went wrong" <> simplifile.describe_error(error),
      )
      wisp.html_body(wisp.ok(), "Get received")
    }
  }
}

type Message {
  AddEntry(entry: Entry)
  GetRecentEntries(reply: process.Subject(List(Entry)))
}

fn handle_message(
  state: List(Entry),
  msg: Message,
) -> actor.Next(List(Entry), Message) {
  case msg {
    AddEntry(entry) -> actor.continue([entry, ..state])
    GetRecentEntries(reply) -> {
      process.send(reply, list.take(state, 20))
      actor.continue(state)
    }
  }
}

const log_file_path: String = "/tmp/dear_agent/log"

fn record(
  req: wisp.Request,
  body: option.Option(String),
  kind: Kind,
) -> Result(Entry, simplifile.FileError) {
  let headers =
    json.array(req.headers, of: fn(pair) {
      let #(k, v) = pair
      json.array([k, v], of: json.string)
    })
  let stamp = timestamp.to_rfc3339(timestamp.system_time(), calendar.utc_offset)
  let user_agent =
    result.unwrap(request.get_header(req, "user-agent"), "unknown")
  let x_forwarded_for =
    result.unwrap(request.get_header(req, "x-forwarded-for"), "")
  let ip = case string.split(x_forwarded_for, on: ",") {
    [first, ..] -> first
    [] -> ""
  }
  let query_string = option.unwrap(req.query, "")
  let actual_body = option.unwrap(body, "")

  let payload =
    json.object([
      #("headers", headers),
      #("timestamp", json.string(stamp)),
      #("user_agent", json.string(user_agent)),
      #("ip", json.string(ip)),
      #("query", json.string(query_string)),
      #("body", json.string(actual_body)),
      #("type", json.string(kind_to_string(kind))),
    ])

  let contents = json.to_string(payload) <> "\n"
  use _ <- result.try(simplifile.append(to: log_file_path, contents: contents))
  Ok(Entry(
    headers: req.headers,
    ts: stamp,
    user_agent: user_agent,
    ip: ip,
    query: query_string,
    body: actual_body,
    kind: kind,
  ))
}

fn read_entries() -> Result(List(Entry), simplifile.FileError) {
  let header_decoder = {
    use key <- decode.field(0, decode.string)
    use value <- decode.field(1, decode.string)
    decode.success(#(key, value))
  }

  let kind_decoder =
    decode.then(decode.string, fn(s) {
      case s {
        "post" -> decode.success(Post)
        "probe" -> decode.success(Probe)
        _ -> decode.failure(Post, "Kind")
      }
    })

  let decoder = {
    use kind <- decode.field("type", kind_decoder)
    use headers <- decode.field("headers", decode.list(header_decoder))
    use ts <- decode.field("timestamp", decode.string)
    use user_agent <- decode.field("user_agent", decode.string)
    use ip <- decode.field("ip", decode.string)
    use query <- decode.field("query", decode.string)
    use body <- decode.field("body", decode.string)
    decode.success(Entry(
      kind: kind,
      headers: headers,
      ts: ts,
      user_agent: user_agent,
      ip: ip,
      query: query,
      body: body,
    ))
  }

  use contents <- result.try(simplifile.read(log_file_path))
  use entries <- result.try(
    contents
    |> string.split(on: "\n")
    |> list.reverse()
    |> list.drop(1)
    |> list.take(20)
    |> list.try_map(fn(raw) { json.parse(raw, decoder) })
    |> result.replace_error(simplifile.Unknown("Failed to parse")),
  )

  Ok(entries)
}

fn kind_to_string(kind: Kind) -> String {
  case kind {
    Post -> "post"
    Probe -> "probe"
  }
}

fn render_page(entries: List(Entry)) -> String {
  let html =
    html([], [
      html.head([], [
        html.title([], "Dear Agent"),
        font(),
        style(),
      ]),
      html.body([], [
        html.header([], [prompt_line(), stats_line(entries)]),
        entry_list(entries),
      ]),
    ])

  element.to_document_string(html)
}

fn font() -> element.Element(msg) {
  html.link([
    attribute.rel("stylesheet"),
    attribute.href(
      "https://fonts.googleapis.com/css2?family=JetBrains+Mono&display=swap",
    ),
  ])
}

fn prompt_line() -> element.Element(msg) {
  html.div([attribute.class("prompt")], [element.text("tail -f log.jsonl")])
}

fn stats_line(entries: List(Entry)) -> element.Element(msg) {
  let count = entries |> list.length() |> int.to_string()
  html.div([attribute.class("stats")], [
    html.b([], [element.text(count)]),
    element.text(" entries recorded"),
  ])
}

fn entry_list(entries: List(Entry)) -> element.Element(msg) {
  html.div([attribute.class("entry-list")], list.map(entries, entry_view))
}

fn entry_view(entry: Entry) -> element.Element(msg) {
  let #(method_text, method_mod, path_text) = case entry.kind {
    Post -> #("POST", "post", "/post")
    Probe -> #("GET", "get", "/probe")
  }

  let #(preview_text, preview_class) = case entry.body {
    "" -> #("(no body)", "col-preview empty")
    body -> #(body, "col-preview")
  }

  let conditional_rows = case entry.kind {
    Post -> [
      html.span([attribute.class("label")], [element.text("Body")]),
      html.pre([attribute.class("v body")], [element.text(entry.body)]),
    ]
    Probe -> [
      html.span([attribute.class("label")], [element.text("Query")]),
      html.span([attribute.class("v")], [element.text(entry.query)]),
    ]
  }

  let detail_children =
    list.flatten([
      [
        html.span([attribute.class("label")], [element.text("Time")]),
        html.span([attribute.class("v ts")], [element.text(entry.ts)]),
        html.span([attribute.class("label")], [element.text("IP")]),
        html.span([attribute.class("v ip")], [element.text(entry.ip)]),
        html.span([attribute.class("label")], [element.text("User-Agent")]),
        html.span([attribute.class("v ua")], [element.text(entry.user_agent)]),
      ],
      conditional_rows,
      [
        html.span([attribute.class("label")], [element.text("Headers")]),
        headers_view(entry.headers),
      ],
    ])

  html.details([attribute.class("entry")], [
    html.summary([], [
      html.span([attribute.class("col-ts")], [
        element.text(relative_time(entry.ts)),
      ]),
      html.span([attribute.class("col-method " <> method_mod)], [
        element.text(method_text),
      ]),
      html.span([attribute.class("col-path")], [element.text(path_text)]),
      html.span([attribute.class("col-ip")], [element.text(entry.ip)]),
      html.span([attribute.class("col-ua")], [element.text(entry.user_agent)]),
      html.span([attribute.class(preview_class)], [element.text(preview_text)]),
    ]),
    html.div([attribute.class("detail")], detail_children),
  ])
}

fn headers_view(headers: List(#(String, String))) -> element.Element(msg) {
  html.div(
    [attribute.class("headers")],
    list.flat_map(headers, fn(pair) {
      let #(k, v) = pair
      [
        html.span([attribute.class("hkey")], [element.text(k)]),
        html.span([attribute.class("hval")], [element.text(v)]),
      ]
    }),
  )
}

fn relative_time(timestamp_string: String) -> String {
  case timestamp.parse_rfc3339(timestamp_string) {
    Ok(ts) -> {
      let now = timestamp.system_time()
      let diff = timestamp.difference(now, ts)
      case duration.to_seconds(diff) {
        seconds if seconds <. 60.0 -> "just now"
        seconds if seconds <. 3600.0 ->
          int.to_string(float.truncate(seconds /. 60.0)) <> " minutes ago"
        seconds if seconds <. 86_400.0 ->
          int.to_string(float.truncate(seconds /. 3600.0)) <> " hours ago"
        seconds if seconds <. 604_800.0 ->
          int.to_string(float.truncate(seconds /. 86_400.0)) <> " days ago"
        seconds ->
          int.to_string(float.truncate(seconds /. 604_800.0)) <> " weeks ago"
      }
    }
    Error(_) -> {
      "???"
    }
  }
}

fn style() -> element.Element(msg) {
  let style =
    "
:root {
    --bg: #282A36;
    --bg-2: #2E3140;
    --fg: #F8F8F2;
    --comment: #6272A4;
    --selection: #44475A;
    --green: #50FA7B;
    --pink: #FF79C6;
    --purple: #BD93F9;
    --cyan: #8BE9FD;
    --orange: #FFB86C;
    --yellow: #F1FA8C;
    --red: #FF5555;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; height: 100%; }
  body {
    background: var(--bg);
    color: var(--fg);
    font: 13px/1.5 'JetBrains Mono', ui-monospace, monospace;
    padding: 1.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
  }
  @media (max-width: 600px) {
    body { padding: 1rem; gap: 0.5rem; font-size: 12px; }
  }

  header { display: flex; flex-direction: column; gap: 0.15rem; }
  .prompt { color: var(--green); }
  .prompt::before { content: '$ '; color: var(--comment); }
  .stats { color: var(--comment); }
  .stats b { color: var(--fg); font-weight: 600; }

  .entry-list {
    border-top: 1px solid var(--selection);
    flex: 1 1 auto;
    min-height: 0;
    min-width: 0;
    width: 100%;
  }
  .entry { max-width: 100%; min-width: 0; border-bottom: 1px solid var(--selection); }
  .entry > summary {
    display: flex;
    gap: 1rem;
    white-space: nowrap;
    padding: 0.35rem 0.5rem 0.35rem 0;
    cursor: pointer;
    list-style: none;
    align-items: baseline;
    overflow: hidden;
    max-width: 100%;
  }
  .entry > summary::-webkit-details-marker { display: none; }
  .entry > summary::before {
    content: '▸';
    color: var(--selection);
    width: 1ch;
    flex: none;
    transition: color 0.1s;
  }
  .entry[open] > summary::before { content: '▾'; color: var(--purple); }
  .entry > summary:hover { background: var(--bg-2); }
  .entry > summary:hover::before { color: var(--purple); }
  .entry > summary > * { flex: none; }

  .col-ts     { color: var(--comment); min-width: 7ch; text-align: right; }
  .col-method { min-width: 5ch; font-weight: 600; }
  .col-method.post { color: var(--pink); }
  .col-method.get  { color: var(--green); }
  .col-path   { color: var(--fg); min-width: 7ch; }
  .col-ip     { color: var(--orange); min-width: 16ch; }
  .col-ua     { color: var(--cyan); width: 24ch; flex: 0 0 24ch; overflow: hidden;
  text-overflow: ellipsis; }
  .col-preview {
    color: var(--yellow);
    overflow: hidden;
    text-overflow: ellipsis;
    flex: 1 1 auto;
    min-width: 0;
  }
  .col-preview.empty { color: var(--selection); }

  @media (max-width: 600px) {
    .col-ip, .col-ua { display: none; }
    .entry > summary { gap: 0.6rem; }
  }

  .detail {
    padding: 0.4rem 0 0.8rem 3ch;
    display: grid;
    grid-template-columns: max-content minmax(0, 1fr);
    gap: 0.3rem 1rem;
    white-space: normal;
    max-width: 100%;
    overflow: hidden;
  }
  .detail > * { min-width: 0; }
  .detail .label { color: var(--comment); }
  .detail .v { color: var(--fg); overflow-wrap: anywhere; min-width: 0; }
  .detail .v.ua { color: var(--cyan); }
  .detail .v.ip { color: var(--orange); }
  .detail .v.ts { color: var(--comment); }
  .detail .v.body {
    color: var(--yellow);
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    font-family: inherit;
    margin: 0;
    min-width: 0;
  }
  .detail .headers {
    display: grid;
    grid-template-columns: max-content minmax(0, 1fr);
    gap: 0.1rem 0.75rem;
    font-size: 0.95em;
    min-width: 0;
  }
  .detail .headers > * { min-width: 0; }
  .detail .headers .hkey { color: var(--purple); }
  .detail .headers .hval { color: var(--fg); overflow-wrap: anywhere; }
  "

  html.style([], style)
}
