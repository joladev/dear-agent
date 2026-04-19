import gleam/erlang/process
import mist
import wisp
import wisp/wisp_mist

pub fn main() -> Nil {
  wisp.configure_logger()

  let assert Ok(_) =
    default_handler
    |> wisp_mist.handler(wisp.random_string(32))
    |> mist.new()
    |> mist.port(3999)
    |> mist.start()

  process.sleep_forever()
}

pub fn default_handler(_: wisp.Request) -> wisp.Response {
  wisp.ok()
  |> wisp.string_body("Ok")
}
